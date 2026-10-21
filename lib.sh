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

log() { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

is_wsl() { grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null; }

# Windows' %APPDATA% as a WSL path, e.g. /mnt/c/Users/me/AppData/Roaming.
win_appdata() {
  wslpath -u "$( (cd /mnt/c && cmd.exe /c 'echo %APPDATA%' 2>/dev/null) | tr -d '\r\n')"
}

# The MCP server entry, as JSON {command, args}. Under WSL, Windows-side clients
# launch it through wsl.exe; -e skips the login shell, so PATH is set explicitly
# for signal-mcp to find signal-cli in ~/.local/bin.
server_entry() {
  if is_wsl; then
    printf '{"command":"wsl.exe","args":["-d","%s","-e","/usr/bin/env","PATH=%s:/usr/local/bin:/usr/bin:/bin","%s","serve"]}' \
      "$WSL_DISTRO_NAME" "$bin_dir" "$bin_dir/signal-mcp"
  else
    printf '{"command":"%s","args":["serve"]}' "$bin_dir/signal-mcp"
  fi
}

desktop_config_path() {
  if [[ "$(uname -s)" == Darwin ]]; then
    echo "$HOME/Library/Application Support/Claude/claude_desktop_config.json"
  elif is_wsl; then
    echo "$(win_appdata)/Claude/claude_desktop_config.json"
  fi
}

# register_claude READONLY: add the server to Claude Code unless one named
# 'signal' already exists. Under WSL that covers both a Claude Code installed
# inside WSL and a native Windows one.
register_claude() {
  local env_args=()
  (($1)) && env_args=(-e SIGNAL_MCP_READONLY=1)
  local found=0

  if command -v claude >/dev/null; then
    found=1
    if claude mcp get signal >/dev/null 2>&1; then
      log "Claude Code: 'signal' server present"
    else
      claude mcp add -s user ${env_args[@]+"${env_args[@]}"} signal -- "$bin_dir/signal-mcp" serve >/dev/null
      log "Claude Code: added 'signal' server; restart Claude Code to load it"
    fi
  fi

  if is_wsl && (cd /mnt/c && cmd.exe /c where claude) >/dev/null 2>&1; then
    found=1
    if (cd /mnt/c && cmd.exe /c claude mcp get signal) >/dev/null 2>&1; then
      log "Claude Code (Windows): 'signal' server present"
    else
      (cd /mnt/c && cmd.exe /c claude mcp add -s user ${env_args[@]+"${env_args[@]}"} signal -- \
        wsl.exe -d "$WSL_DISTRO_NAME" -e /usr/bin/env "PATH=$bin_dir:/usr/local/bin:/usr/bin:/bin" \
        "$bin_dir/signal-mcp" serve) >/dev/null
      log "Claude Code (Windows): added 'signal' server; restart Claude Code to load it"
    fi
  fi

  ((found)) || warn "Claude Code not found, skipping"
}

# register_desktop READONLY: add the server to Claude Desktop (macOS, or the
# Windows side of WSL) unless one named 'signal' already exists. Backs up the
# config before writing.
register_desktop() {
  local config
  config="$(desktop_config_path)"
  if [[ -z "$config" || ! -d "$(dirname "$config")" ]]; then
    log "Claude Desktop not installed, skipping"
    return
  fi
  # Uses the venv's Python since macOS may not have one.
  "$venv/bin/python" - "$config" "$(server_entry)" "$1" <<'PY'
import json, os, shutil, sys
path, entry, readonly = sys.argv[1], json.loads(sys.argv[2]), sys.argv[3] == "1"
try:
    config = json.load(open(path)) if os.path.exists(path) else {}
except json.JSONDecodeError as e:
    sys.exit(f"error: {path} is not valid JSON ({e}); fix it, or skip Desktop with --no-desktop")
servers = config.setdefault("mcpServers", {})
if "signal" in servers:
    print("==> Claude Desktop: 'signal' server present")
    sys.exit()
servers["signal"] = entry
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
  if command -v claude >/dev/null &&
     claude mcp get signal 2>/dev/null | grep -qF "$bin_dir/signal-mcp"; then
    claude mcp remove -s user signal >/dev/null
    log "Claude Code: removed 'signal' server"
  fi
  if is_wsl && (cd /mnt/c && cmd.exe /c claude mcp get signal) 2>/dev/null | grep -qF "$bin_dir/signal-mcp"; then
    (cd /mnt/c && cmd.exe /c claude mcp remove -s user signal) >/dev/null
    log "Claude Code (Windows): removed 'signal' server"
  fi
}

unregister_desktop() {
  local config
  config="$(desktop_config_path)"
  [[ -n "$config" && -f "$config" && -x "$venv/bin/python" ]] || return 0
  "$venv/bin/python" - "$config" "$bin_dir/signal-mcp" <<'PY'
import json, os, shutil, sys
path, binary = sys.argv[1], sys.argv[2]
config = json.load(open(path))
entry = config.get("mcpServers", {}).get("signal", {})
if binary not in [entry.get("command"), *entry.get("args", [])]:
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
