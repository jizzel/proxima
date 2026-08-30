# word_count — example Proxima plugin

Counts words, lines, and bytes in a file.

```
 ❯ how many words are in README.md?
```

The agent calls `word_count` with `{"path": "README.md"}` and gets back:

```
README.md
  lines : 444
  words : 1985
  bytes : 18362
```

---

## How Proxima plugins work

A plugin is a directory under `.proxima/plugins/<name>/` containing two files:

```
.proxima/plugins/word-count/
  plugin.json   ← descriptor (name, description, schema, risk level)
  run.sh        ← the executable (shell script, Python, Go binary, anything)
```

### Protocol

1. Proxima serialises the tool arguments as a JSON object and writes it to the plugin's **stdin**.
2. The plugin writes its result to **stdout** (any text — Proxima returns it verbatim as the tool result).
3. Exit **0** on success. Any non-zero exit code is treated as an error; stderr is shown to the user.

### `plugin.json` fields

| Field | Required | Description |
|---|---|---|
| `name` | ✅ | Snake-case tool name (must be unique, must not clash with built-ins) |
| `description` | ✅ | Shown to the LLM — be specific about what the tool does |
| `executable` | ✅ | Filename of the script/binary inside this directory |
| `input_schema` | ✅ | JSON Schema object describing the tool's arguments |
| `risk_level` | — | `safe` / `confirm` / `high_risk` (default: `confirm`) |
| `timeout_seconds` | — | Kill timeout in seconds (default: `30`) |

### Tips for writing plugins

- **Parse stdin defensively.** Use `jq` for reliable JSON parsing; the `sed` approach in `run.sh` is intentionally dependency-free for portability.
- **Stay inside the working directory.** Proxima calls `isSafePath()` before executing your plugin, but double-checking in the script is cheap.
- **Use `risk_level: "safe"`** only if your plugin never modifies files or external state. The agent will call safe tools automatically without prompting.
- **stderr is your error channel.** Anything written to stderr on a non-zero exit is shown to the user as the error message.
- **The working directory** of your process is Proxima's `workingDir` (the project root), so relative paths work as expected.

### Testing your plugin standalone

```sh
# From the project root:
echo '{"path":"README.md"}' | sh .proxima/plugins/word-count/run.sh
```

### Registering additional plugin directories

Add to `.proxima/config.yaml`:

```yaml
plugin_dirs:
  - .proxima/plugins          # default
  - /path/to/shared-plugins   # extra dir
```
