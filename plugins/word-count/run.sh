#!/usr/bin/env sh
#
# word_count — example Proxima plugin
#
# Protocol:
#   - Proxima passes the tool arguments as a JSON object on stdin.
#   - Write your result to stdout (any text).
#   - Exit 0 on success, non-zero on error (stderr is shown to the user).
#
# This plugin reads the "path" argument, resolves it relative to the
# working directory Proxima was started in, and counts words/lines/chars.
#
# Test manually:
#   echo '{"path":"README.md"}' | sh run.sh

set -e

# ── 1. Read stdin (the JSON args Proxima sends) ───────────────────────────────
input=$(cat)

# ── 2. Extract the "path" field with basic POSIX tools (no jq required) ───────
#    For production plugins, prefer: path=$(echo "$input" | jq -r '.path')
file_path=$(echo "$input" | sed 's/.*"path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')

if [ -z "$file_path" ]; then
  echo "Error: missing required argument 'path'" >&2
  exit 1
fi

# ── 3. Safety check — stay inside the working directory ───────────────────────
#    Proxima already validates isSafePath() before calling the plugin,
#    but defence-in-depth is cheap here.
case "$file_path" in
  /*|*..*)
    echo "Error: path must be relative and must not contain '..'" >&2
    exit 1
    ;;
esac

# ── 4. Verify the file exists ─────────────────────────────────────────────────
if [ ! -f "$file_path" ]; then
  echo "Error: file not found: $file_path" >&2
  exit 1
fi

# ── 5. Compute the stats ──────────────────────────────────────────────────────
lines=$(wc -l < "$file_path" | tr -d ' ')
words=$(wc -w < "$file_path" | tr -d ' ')
chars=$(wc -c < "$file_path" | tr -d ' ')

# ── 6. Write the result to stdout ─────────────────────────────────────────────
#    Proxima returns whatever you print here as the tool result.
printf '%s\n' "$file_path"
printf '  lines : %s\n' "$lines"
printf '  words : %s\n' "$words"
printf '  bytes : %s\n' "$chars"
