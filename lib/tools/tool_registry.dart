import 'ignore_matcher.dart';
import 'tool_interface.dart';

/// Registry for all Proxima tools.
class ToolRegistry {
  final Map<String, ProximaTool> _tools = {};

  /// Shared ignore rules for the file-walking tools.
  ///
  /// Lives here rather than being passed to `execute()` because
  /// `ProximaTool.execute(args, workingDir)` is a Layer-6 contract that
  /// plugins implement too — widening it would break every third-party tool.
  /// The agent loop refreshes this per turn so `.gitignore` edits and
  /// `/ignore` patterns take effect without a restart.
  IgnoreMatcher ignoreMatcher = IgnoreMatcher.defaults();

  void register(ProximaTool tool) {
    _tools[tool.name] = tool;
  }

  ProximaTool? lookup(String name) => _tools[name];

  List<ProximaTool> all() => _tools.values.toList();

  bool contains(String name) => _tools.containsKey(name);
}
