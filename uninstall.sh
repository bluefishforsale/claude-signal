#!/usr/bin/env bash
# The backout plan for install.sh. Removes what it installed but never deletes
# your Signal data or message history; that's printed for you to remove by hand.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"

if command -v signal-mcp >/dev/null; then
  signal-mcp uninstall-service
fi
unregister_claude
# Before the venv goes, since this uses its Python.
unregister_desktop

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
