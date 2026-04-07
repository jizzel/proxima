import 'dart:async';
import '../core/types.dart';
import '../core/session.dart';
import '../core/config.dart';
import '../core/cost_calculator.dart';
import '../providers/provider_interface.dart';
import '../tools/tool_interface.dart';
import '../tools/tool_registry.dart';
import '../permissions/permission_gate.dart';
import '../context/context_builder.dart';
import '../context/project_index.dart';
import 'stuck_detector.dart';
import 'subagent_runner.dart';

/// Callbacks for the agent loop to communicate with the renderer.
abstract class AgentCallbacks {
  void onThinking(String reasoning);
  void onToolCall(ToolCall toolCall);
  void onToolResult(String toolName, String result, bool isError);
  void onFinalResponse(String text);
  void onClarify(String question);
  void onError(String message);

  /// Called when the agent is stuck (repeated tool calls) or spinning
  /// (only read-only calls with no progress). [reason] is either
  /// `'stuck'` or `'spinning'`. Returns true to continue, false to abort.
  Future<bool> onStuck(List<ToolCall> recentCalls, {String reason = 'stuck'});
  void onChunk(String text);

  /// Called with token usage and cost after every completed turn.
  void onUsageReport(
    TokenUsage turnUsage,
    TokenUsage cumulative,
    double turnCost,
    double sessionCost,
  );

  /// Called immediately before tool.execute() (or dryRun()), after permission
  /// is granted. Fires once per tool call, just before execution begins.
  void onToolExecuting(ToolCall toolCall);

  /// Called at the start of each loop iteration, after iterationCount is
  /// incremented. Use to show iteration context in the spinner.
  void onIterationStart(int iteration, int maxIterations);

  /// Called when a clarify response includes a fixed option list.
  /// Must return the index of the selected option. Blocks until user selects.
  Future<int> onClarifyWithOptions(String question, List<String> options);
}

/// Stateless agent loop. All state lives in [ProximaSession].
class AgentLoop {
  final LLMProvider _provider;
  final ToolRegistry _toolRegistry;
  final PermissionGate _permissionGate;
  final ContextBuilder _contextBuilder;
  final ProximaConfig _config;

  AgentLoop({
    required LLMProvider provider,
    required ToolRegistry toolRegistry,
    required PermissionGate permissionGate,
    required ContextBuilder contextBuilder,
    required ProximaConfig config,
  }) : _provider = provider,
       _toolRegistry = toolRegistry,
       _permissionGate = permissionGate,
       _contextBuilder = contextBuilder,
       _config = config;

  /// Run one full turn: think → act → observe loop.
  /// [userInput] is the new user message.
  /// Returns updated session (state is mutated in place and returned).
  Future<ProximaSession> runTurn(
    ProximaSession session,
    String userInput,
    AgentCallbacks callbacks,
  ) async {
    // Add user message to history.
    session.addMessage(Message(role: MessageRole.user, content: userInput));

    final toolLog = <ToolCall>[];
    var delegationCount = 0;
    var schemaRetries = 0;
    var llmRetries = 0;

    // Build project index once per turn (not per LLM retry).
    final projectIndex = await ProjectIndex.build(session.workingDir);

    while (session.iterationCount < _config.maxIterations) {
      session.iterationCount++;
      callbacks.onIterationStart(session.iterationCount, _config.maxIterations);

      // Build context-aware request.
      final request = await _contextBuilder.build(session, projectIndex);

      // Call the LLM (streaming when supported, with complete() fallback).
      LLMResponse response;
      bool didStream = false;
      try {
        if (_provider.capabilities.streaming) {
          (response, didStream) = await _streamResponse(request, callbacks);
        } else {
          response = await _provider.complete(request);
        }
        llmRetries = 0;
      } catch (e) {
        if (llmRetries < _config.maxRetriesLlm) {
          llmRetries++;
          callbacks.onError('LLM error (retry $llmRetries): $e');
          continue;
        }
        callbacks.onError('LLM error (giving up): $e');
        session.status = TaskStatus.failed;
        return session;
      }

      // Record token usage and cost.
      session.recordUsage(response.usage);
      final turnCost = CostCalculator.compute(_config.model, response.usage);
      session.recordCost(turnCost);

      // Handle response body.
      final body = response.body;

      if (body is FinalResponse) {
        session.addMessage(
          Message(role: MessageRole.assistant, content: body.text),
        );
        // When streaming, tokens are already on screen — pass empty string so
        // the renderer only emits the closing separator, not the full text again.
        callbacks.onFinalResponse(didStream ? '' : body.text);
        // Usage printed after separator so it appears below the response.
        callbacks.onUsageReport(
          response.usage,
          session.cumulativeUsage,
          turnCost,
          session.cumulativeCost,
        );
        session.status = TaskStatus.completed;
        return session;
      }

      if (body is ClarifyResponse) {
        session.addMessage(
          Message(role: MessageRole.assistant, content: body.question),
        );
        // Same: tokens already on screen when streamed.
        callbacks.onClarify(didStream ? '' : body.question);

        callbacks.onUsageReport(
          response.usage,
          session.cumulativeUsage,
          turnCost,
          session.cumulativeCost,
        );

        if (body.options.isNotEmpty) {
          final idx = await callbacks.onClarifyWithOptions(
            body.question,
            body.options,
          );
          final answer = body.options[idx.clamp(0, body.options.length - 1)];
          session.addMessage(Message(role: MessageRole.user, content: answer));
          continue; // stay in loop — answer injected, keep going
        }

        // Wait for next turn with user's answer.
        return session;
      }

      if (body is ErrorResponse) {
        if (schemaRetries < _config.maxRetriesSchema) {
          schemaRetries++;
          callbacks.onError(
            'LLM returned error response (retry $schemaRetries): ${body.message}',
          );
          // Add a reprompt message.
          session.addMessage(
            Message(
              role: MessageRole.user,
              content: 'Please provide a valid response.',
            ),
          );
          continue;
        }
        callbacks.onError('LLM error response (giving up): ${body.message}');
        session.status = TaskStatus.failed;
        return session;
      }

      if (body is ToolCallResponse) {
        final toolCall = body.toolCall;

        if (toolCall.reasoning.isNotEmpty) {
          callbacks.onThinking(toolCall.reasoning);
        }

        callbacks.onToolCall(toolCall);
        toolLog.add(toolCall);

        // Stuck detection — identical calls.
        if (StuckDetector.isStuck(toolLog)) {
          final shouldContinue = await callbacks.onStuck(
            toolLog.sublist(toolLog.length - 3),
          );
          if (!shouldContinue) {
            session.status = TaskStatus.failed;
            return session;
          }
          // User chose to continue — reset the tool log to allow progress.
          toolLog.clear();
        }

        // Spinning detection — only read-only calls, no mutations.
        if (StuckDetector.isSpinning(toolLog)) {
          final shouldContinue = await callbacks.onStuck(
            toolLog.sublist(toolLog.length - StuckDetector.spinWindow),
            reason: 'spinning',
          );
          if (!shouldContinue) {
            session.status = TaskStatus.failed;
            return session;
          }
          toolLog.clear();
        }

        // ── Subagent interception ────────────────────────────────────────────
        if (toolCall.tool == 'delegate_to_subagent') {
          // In dry-run mode, preview the delegation without calling the LLM.
          if (_config.dryRun) {
            final tool = _toolRegistry.lookup(toolCall.tool);
            final preview = tool != null
                ? '[DRY RUN] ${(await tool.dryRun(toolCall.args, session.workingDir)).preview}'
                : '[DRY RUN] Would delegate to ${toolCall.args['agent']}';
            session.addMessage(
              Message(
                role: MessageRole.assistant,
                content: toolCall.reasoning,
                toolName: toolCall.tool,
                toolCallId: toolCall.callId ?? 'call_${session.iterationCount}',
                toolInput: toolCall.args,
              ),
            );
            session.addMessage(
              Message(
                role: MessageRole.tool,
                content: preview,
                toolName: toolCall.tool,
                toolCallId: toolCall.callId ?? 'call_${session.iterationCount}',
              ),
            );
            callbacks.onToolResult(toolCall.tool, preview, false);
            session.addTaskRecord(
              TaskRecord(
                toolName: toolCall.tool,
                args: toolCall.args,
                timestamp: DateTime.now(),
                success: true,
              ),
            );
            continue;
          }

          String subagentResult;
          bool delegationFailed;

          if (delegationCount >= _config.maxSubagentDelegations) {
            subagentResult =
                'Error: max subagent delegations '
                '(${_config.maxSubagentDelegations}) reached this turn.';
            delegationFailed = true;
          } else {
            delegationCount++;
            callbacks.onToolExecuting(toolCall);
            final runner = SubagentRunner(provider: _provider);
            final result = await runner.run(
              agentTypeStr: toolCall.args['agent'] as String? ?? '',
              task: toolCall.args['task'] as String? ?? '',
              context: toolCall.args['context'] as String? ?? '',
              model: session.model,
            );
            session.recordUsage(result.usage);
            session.recordCost(
              CostCalculator.compute(_config.model, result.usage),
            );
            delegationFailed = result.isError;
            subagentResult = result.isError
                ? 'Subagent error: ${result.errorMessage}'
                : result.output;
          }

          session.addMessage(
            Message(
              role: MessageRole.assistant,
              content: toolCall.reasoning,
              toolName: toolCall.tool,
              toolCallId: toolCall.callId ?? 'call_${session.iterationCount}',
              toolInput: toolCall.args,
            ),
          );
          session.addMessage(
            Message(
              role: MessageRole.tool,
              content: subagentResult,
              toolName: toolCall.tool,
              toolCallId: toolCall.callId ?? 'call_${session.iterationCount}',
            ),
          );
          callbacks.onToolResult(
            toolCall.tool,
            subagentResult,
            delegationFailed,
          );
          session.addTaskRecord(
            TaskRecord(
              toolName: toolCall.tool,
              args: toolCall.args,
              timestamp: DateTime.now(),
              success: !delegationFailed,
            ),
          );
          continue;
        }
        // ── end subagent interception ────────────────────────────────────────

        // Permission gate.
        final permission = await _permissionGate.evaluate(
          toolCall,
          session.id,
          deniedTools: session.permissions.deniedTools,
          allowedTools: session.permissions.allowedTools,
        );

        if (permission.decision == GateDecision.deny) {
          final denyMessage = 'Tool call denied: ${permission.reason}';
          session.addMessage(
            Message(
              role: MessageRole.assistant,
              content: '${toolCall.reasoning}\n[Tool: ${toolCall.tool}]',
              toolName: toolCall.tool,
              toolCallId: toolCall.callId,
              toolInput: toolCall.args,
            ),
          );
          session.addMessage(
            Message(
              role: MessageRole.tool,
              content: denyMessage,
              toolName: toolCall.tool,
              toolCallId: toolCall.callId,
            ),
          );
          callbacks.onToolResult(toolCall.tool, denyMessage, true);
          continue;
        }

        if (permission.decision == GateDecision.skip) {
          return session;
        }

        // Execute the tool.
        final tool = _toolRegistry.lookup(toolCall.tool);
        if (tool == null) {
          const errorMsg = 'Unknown tool';
          session.addMessage(
            Message(
              role: MessageRole.tool,
              content: errorMsg,
              toolName: toolCall.tool,
              toolCallId: toolCall.callId,
            ),
          );
          callbacks.onToolResult(toolCall.tool, errorMsg, true);
          continue;
        }

        callbacks.onToolExecuting(toolCall);

        String toolResult;
        bool isError = false;

        var toolRetries = 0;
        while (true) {
          try {
            if (_config.dryRun) {
              final dryRun = await tool.dryRun(
                toolCall.args,
                session.workingDir,
              );
              toolResult = '[DRY RUN] ${dryRun.preview}';
            } else {
              toolResult = await tool.execute(
                toolCall.args,
                session.workingDir,
              );
            }
            break;
          } catch (e) {
            if (toolRetries < _config.maxRetriesTool &&
                e is ToolError &&
                e.retryable) {
              toolRetries++;
              continue;
            }
            toolResult = _formatToolError(toolCall.tool, e);
            isError = true;
            break;
          }
        }

        // Cache read_file results for compaction deduplication.
        if (!isError && toolCall.tool == 'read_file') {
          final path = toolCall.args['path'] as String?;
          if (path != null) {
            session.fileCache[path] = toolResult;
          }
        }

        // Record assistant tool call message.
        session.addMessage(
          Message(
            role: MessageRole.assistant,
            content: toolCall.reasoning,
            toolName: toolCall.tool,
            toolCallId: toolCall.callId ?? 'call_${session.iterationCount}',
            toolInput: toolCall.args,
          ),
        );

        // Extract backup path embedded by write_file/patch_file for /undo support.
        String? backupPath;
        String displayResult = toolResult;
        const backupMarker = '\nBACKUP_PATH:';
        final markerIndex = toolResult.indexOf(backupMarker);
        if (markerIndex != -1) {
          backupPath = toolResult
              .substring(markerIndex + backupMarker.length)
              .trim();
          displayResult = toolResult.substring(0, markerIndex);
        }

        // Record tool result message (stripped of internal markers).
        session.addMessage(
          Message(
            role: MessageRole.tool,
            content: displayResult,
            toolName: toolCall.tool,
            toolCallId: toolCall.callId ?? 'call_${session.iterationCount}',
          ),
        );

        callbacks.onToolResult(toolCall.tool, displayResult, isError);

        // Record in task history for undo.
        session.addTaskRecord(
          TaskRecord(
            toolName: toolCall.tool,
            args: toolCall.args,
            backupPath: backupPath,
            timestamp: DateTime.now(),
            success: !isError,
          ),
        );

        // In plan mode, exit the loop immediately after write_plan succeeds.
        // This prevents the LLM from taking another turn and emitting noise
        // (options lists, questions) that would appear before the picker.
        if (!isError && toolCall.tool == 'write_plan' && session.isPlanMode) {
          session.planWritten = true;
          session.status = TaskStatus.completed;
          callbacks.onUsageReport(
            response.usage,
            session.cumulativeUsage,
            turnCost,
            session.cumulativeCost,
          );
          return session;
        }

        continue;
      }
    }

    // Max iterations reached.
    callbacks.onError('Max iterations (${_config.maxIterations}) reached.');
    session.status = TaskStatus.failed;
    return session;
  }

  /// Formats a tool error with actionable context for the LLM.
  String _formatToolError(String tool, Object error) {
    if (error is! ToolError) {
      return 'Tool: $tool\nError: $error\nSuggestion: Check the tool arguments and try again.';
    }

    final suggestion = switch (error.errorCode) {
      ToolErrorCode.notFound =>
        'Verify the path exists with list_files or glob before retrying.',
      ToolErrorCode.permissionDenied =>
        'This operation is not permitted. Consider a lower-risk alternative.',
      ToolErrorCode.pathViolation =>
        'The path is outside the working directory. Use a relative path.',
      ToolErrorCode.timeout =>
        'The operation timed out. Try with a smaller scope or simpler command.',
      ToolErrorCode.parseError =>
        'Read the target file first to confirm its exact content before patching.',
      ToolErrorCode.unknown =>
        'Read the relevant file(s) to diagnose the issue before retrying.',
    };

    return 'Tool: $tool\nError: ${error.message}\nSuggestion: $suggestion';
  }

  /// Attempt a streaming LLM call, collecting chunks and forwarding text to
  /// [callbacks.onChunk]. Returns the assembled [LLMResponse] and a flag
  /// indicating whether streaming actually occurred.
  ///
  /// Falls back to [_provider.complete] if the stream throws, logging a debug
  /// warning via [callbacks.onError].
  Future<(LLMResponse, bool)> _streamResponse(
    CompletionRequest request,
    AgentCallbacks callbacks,
  ) async {
    final buffer = StringBuffer();
    TokenUsage? finalUsage;
    bool firstChunk = true;

    try {
      bool toolUseDetected = false;

      await for (final chunk in _provider.stream(request)) {
        if (chunk.isDone) {
          finalUsage = chunk.finalUsage;
          toolUseDetected = chunk.hasToolUse;
          break;
        }
        if (chunk.text.isNotEmpty) {
          if (firstChunk) {
            // Spinner must be hidden before the first token appears.
            callbacks.onChunk('\n');
            firstChunk = false;
          }
          callbacks.onChunk(chunk.text);
          buffer.write(chunk.text);
        }
      }

      // When the model made a tool call, the stream only carried metadata —
      // fall back to complete() which parses the full tool_use block.
      if (toolUseDetected) {
        final response = await _provider.complete(request);
        return (response, false);
      }

      final usage = finalUsage ?? TokenUsage.zero;
      final assembledText = buffer.toString();

      // Streaming was used for a final/clarify text response.
      final response = LLMResponse(
        body: FinalResponse(assembledText),
        usage: usage,
        rawText: assembledText,
      );

      return (response, true);
    } catch (e) {
      // Streaming failed — fall back to complete() and log a debug warning.
      callbacks.onError('[debug] Streaming failed, falling back: $e');
      final response = await _provider.complete(request);
      return (response, false);
    }
  }
}
