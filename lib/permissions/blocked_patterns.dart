/// Hardcoded blocked commands and path patterns.
/// These are hard-rejected BEFORE any prompt — no override possible.
library;

/// Shell command patterns that are always blocked.
/// Matched against the full command string.
const List<String> blockedCommandPatterns = [
  // Recursive deletes
  r'rm\s+-[a-zA-Z]*r[a-zA-Z]*\s+/',
  r'rm\s+-[a-zA-Z]*f[a-zA-Z]*\s+/',
  r'rm\s+--recursive',
  r'rm\s+--force',
  // Pipes to shell (curl|wget piped to sh/bash)
  r'curl\s+.*\|\s*(ba)?sh',
  r'wget\s+.*\|\s*(ba)?sh',
  r'curl\s+.*\|\s*sudo',
  // Sudo
  r'\bsudo\b',
  // Fork bombs
  r':\(\)\s*\{',
  // Overwrite system files
  r'>\s*/etc/',
  r'>\s*/usr/',
  r'>\s*/bin/',
  r'>\s*/sbin/',
  r'>\s*/boot/',
  // dd to block devices
  r'dd\s+.*of=/dev/',
  // chmod/chown on system dirs
  r'chmod\s+.*\s+/',
  r'chown\s+.*\s+/',
  // Git force-push (too destructive for automated use)
  r'git\s+push\s+.*--force',
  r'git\s+push\s+.*-f\b',
  // Git reset to filesystem root (path traversal variant)
  r'git\s+reset\s+--hard\s+/',
];

/// Path patterns that are always blocked (absolute paths outside working dir).
const List<String> blockedPathPatterns = [
  r'\.\./', // Path traversal
  r'^/', // Absolute paths (handled separately via isSafePath)
  r'~/', // Home directory shortcuts
  r'\$HOME',
  r'\$\{HOME\}',
];

/// Returns true if [command] matches any blocked command pattern.
bool isBlockedCommand(String command) {
  for (final pattern in blockedCommandPatterns) {
    if (RegExp(pattern, caseSensitive: false).hasMatch(command)) {
      return true;
    }
  }
  return false;
}

/// Returns true if [pathStr] matches a blocked path pattern.
bool isBlockedPath(String pathStr) {
  for (final pattern in blockedPathPatterns) {
    if (RegExp(pattern).hasMatch(pathStr)) {
      return true;
    }
  }
  return false;
}

/// Well-known safe read-only commands that can be auto-executed.
const List<String> safeCommandPrefixes = [
  'ls',
  'cat',
  'head',
  'tail',
  'grep',
  'find',
  'echo',
  'pwd',
  'git status',
  'git log',
  'git diff',
  'git show',
  'git branch',
  'git remote',
  'dart analyze',
  'dart format --output=none',
];
