#!/usr/bin/env bash
# The backout plan for install.sh. Removes what it installed but never deletes
# your Signal data or message history; that's printed for you to remove by hand.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"

# Done here rather than via `signal-mcp uninstall-service` so it still works when
# signal-mcp is already gone or off PATH. Label and paths are upstream's.
case "$(uname -s)" in
  Darwin)
    launchctl bootout "gui/$(id -u)/com.signal-mcp.watch" 2>/dev/null || true
    rm -f "$HOME/Library/LaunchAgents/com.signal-mcp.watch.plist"
    ;;
  Linux)
    systemctl --user disable --now signal-mcp-watch 2>/dev/null || true
    rm -f "$HOME/.config/systemd/user/signal-mcp-watch.service"
    systemctl --user daemon-reload 2>/dev/null || true
    ;;
esac

unregister_claude
# Before the venv goes, since this uses its Python.
unregister_desktop

# MCP tools spawn a signal-cli daemon that outlives the service, and a watcher
# killed mid-poll can leave a `signal-cli receive` holding the account lock.
# NOTE: this must run after unregister_claude, whose `claude mcp get` launches
# the server to health-check it and so spawns a fresh daemon.
pkill -f 'signal-cli -u .* daemon --http localhost:7583' || true
pkill -f 'signal-cli -u .* -o json receive' || true
rm -f "$HOME/.local/share/signal-mcp/daemon.pid" "$HOME/.local/share/signal-mcp/receive.lock"
log "Background service stopped and removed"

rm -f "$bin_dir/signal-mcp"
# Only our own symlink; a Homebrew or hand-installed signal-cli is left alone.
if [[ -L "$bin_dir/signal-cli" && "$(readlink "$bin_dir/signal-cli")" == "$data_dir/"* ]]; then
  rm -f "$bin_dir/signal-cli"
fi
rm -rf "$data_dir"

cat <<EOT
==> Removed signal-mcp, its service, and the Claude Code and Desktop registrations.

Left in place, remove by hand if you want them gone:
  ~/.local/share/signal-cli   signal-cli keys and account (linked device or bot number)
  ~/.local/share/signal-mcp   message history database and logs
  ~/Downloads/signal-attachments

Unlink this device from your phone: Signal > Settings > Linked devices.
On macOS, 'brew uninstall signal-cli qrencode' if nothing else needs them.
EOT
