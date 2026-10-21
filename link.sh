#!/usr/bin/env bash
# signal-cli prints the device-link code as a bare sgnl:// URI, not a QR code,
# so this renders it in the terminal for the phone to scan.
set -euo pipefail

name="${1:-$(hostname -s)}"

command -v signal-cli >/dev/null || { echo "error: signal-cli not on PATH" >&2; exit 1; }
command -v qrencode >/dev/null || { echo "error: qrencode not on PATH (brew install qrencode / apt install qrencode)" >&2; exit 1; }

if signal-cli listAccounts 2>/dev/null | grep -q '+'; then
  echo "==> signal-cli already has an account linked, skipping"
  exit 0
fi

echo "==> Linking as device \"$name\""
echo "    On your phone: Signal > Settings > Linked devices > + , then scan:"
signal-cli link -n "$name" | while IFS= read -r line; do
  case "$line" in
    sgnl://*) qrencode -t ansiutf8 "$line" ;;
    *) echo "$line" ;;
  esac
done
