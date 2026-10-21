#!/usr/bin/env bash
# The backout plan for install.sh. Removes what it installed but never deletes
# your Signal data or message history; that's printed for you to remove by hand.
set -euo pipefail

bin_dir="$HOME/.local/bin"
case "$(uname -s)" in
  Darwin) data_dir="$HOME/Library/Application Support/claude-signal" ;;
  *) data_dir="${XDG_DATA_HOME:-$HOME/.local/share}/claude-signal" ;;
esac

if command -v signal-mcp >/dev/null; then
  signal-mcp uninstall-service
fi
# Only a registration install.sh made; a hand-added 'signal' server is left alone.
if command -v claude >/dev/null &&
   claude mcp get signal 2>/dev/null | grep -qF "$bin_dir/signal-mcp"; then
  claude mcp remove -s user signal
fi

rm -f "$bin_dir/signal-mcp"
# Only our own symlink; a Homebrew or hand-installed signal-cli is left alone.
[[ -L "$bin_dir/signal-cli" && "$(readlink "$bin_dir/signal-cli")" == "$data_dir/"* ]] &&
  rm -f "$bin_dir/signal-cli"
rm -rf "$data_dir"

cat <<EOF
==> Removed signal-mcp, its service, and the Claude Code registration.

Left in place, remove by hand if you want them gone:
  ~/.local/share/signal-cli   signal-cli keys and account (linked device or bot number)
  ~/.local/share/signal-mcp   message history database and logs
  ~/Downloads/signal-attachments

Unlink this device from your phone: Signal > Settings > Linked devices.
On macOS, 'brew uninstall signal-cli qrencode' if nothing else needs them.
EOF
