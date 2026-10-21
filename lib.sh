# shellcheck shell=bash
# Shared by install.sh, doctor.sh and uninstall.sh so all three agree on where
# things live and on what counts as "our" Claude registration.

# Our own files follow each OS's convention. signal-cli and signal-mcp keep
# their data in ~/.local/share on both, which upstream hardcodes.
bin_dir="$HOME/.local/bin"
case "$(uname -s)" in
  Darwin) data_dir="$HOME/Library/Application Support/claude-signal" ;;
  *) data_dir="${XDG_DATA_HOME:-$HOME/.local/share}/claude-signal" ;;
esac
venv="$data_dir/venv"
desktop_config="$HOME/Library/Application Support/Claude/claude_desktop_config.json"

log() { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# register_claude READONLY: add the server to Claude Code unless one named
# 'signal' already exists.
register_claude() {
  if ! command -v claude >/dev/null; then
    warn "claude not on PATH, skipping Claude Code"
    return
  fi
  if claude mcp get signal >/dev/null 2>&1; then
    log "Claude Code: 'signal' server present"
    return
  fi
  local env_args=()
  (($1)) && env_args=(-e SIGNAL_MCP_READONLY=1)
  claude mcp add -s user ${env_args[@]+"${env_args[@]}"} signal -- "$bin_dir/signal-mcp" serve >/dev/null
  log "Claude Code: added 'signal' server; restart Claude Code to load it"
}

# register_desktop READONLY: add the server to Claude Desktop (macOS) unless
# one named 'signal' already exists. Backs up the config before writing.
register_desktop() {
  if [[ "$(uname -s)" != Darwin || ! -d "$(dirname "$desktop_config")" ]]; then
    log "Claude Desktop not installed, skipping"
    return
  fi
  # Desktop launches servers with a minimal PATH and no ~ expansion, hence the
  # absolute command path. Uses the venv's Python since macOS may not have one.
  "$venv/bin/python" - "$desktop_config" "$bin_dir/signal-mcp" "$1" <<'PY'
import json, os, shutil, sys
path, command, readonly = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
try:
    config = json.load(open(path)) if os.path.exists(path) else {}
except json.JSONDecodeError as e:
    sys.exit(f"error: {path} is not valid JSON ({e}); fix it, or skip Desktop with --no-desktop")
servers = config.setdefault("mcpServers", {})
if "signal" in servers:
    print("==> Claude Desktop: 'signal' server present")
    sys.exit()
servers["signal"] = {"command": command, "args": ["serve"]}
if readonly:
    servers["signal"]["env"] = {"SIGNAL_MCP_READONLY": "1"}
if os.path.exists(path):
    shutil.copy2(path, path + ".bak-claude-signal")
with open(path + ".tmp", "w") as f:
    json.dump(config, f, indent=2)
    f.write("\n")
os.replace(path + ".tmp", path)
print("==> Claude Desktop: added 'signal' server; quit and reopen Desktop to load it")
PY
}

# Removal only touches entries pointing at our binary, so a 'signal' server
# someone added by hand survives an uninstall.
unregister_claude() {
  command -v claude >/dev/null || return 0
  claude mcp get signal 2>/dev/null | grep -qF "$bin_dir/signal-mcp" || return 0
  claude mcp remove -s user signal >/dev/null
  log "Claude Code: removed 'signal' server"
}

unregister_desktop() {
  [[ -f "$desktop_config" && -x "$venv/bin/python" ]] || return 0
  "$venv/bin/python" - "$desktop_config" "$bin_dir/signal-mcp" <<'PY'
import json, os, shutil, sys
path, command = sys.argv[1], sys.argv[2]
config = json.load(open(path))
if config.get("mcpServers", {}).get("signal", {}).get("command") != command:
    sys.exit()
del config["mcpServers"]["signal"]
shutil.copy2(path, path + ".bak-claude-signal")
with open(path + ".tmp", "w") as f:
    json.dump(config, f, indent=2)
    f.write("\n")
os.replace(path + ".tmp", path)
print("==> Claude Desktop: removed 'signal' server")
PY
}
