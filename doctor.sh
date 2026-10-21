#!/usr/bin/env bash
# signal-mcp's own doctor checks signal-cli, the account and the daemon but not
# whether any Claude client can reach the server, so this adds that half and
# repairs a missing registration.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"

readonly_mode=0
case "${1:-}" in
  "") ;;
  --readonly) readonly_mode=1 ;;
  *) echo "usage: $0 [--readonly]   (--readonly applies only to registrations it adds)" >&2; exit 2 ;;
esac

[[ -x "$venv/bin/signal-mcp" ]] || die "signal-mcp not installed; run ./install.sh"
export PATH="$bin_dir:$PATH"

status=0
signal-mcp doctor || status=$?
register_claude "$readonly_mode"
register_desktop "$readonly_mode"
exit "$status"
