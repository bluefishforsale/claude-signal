#!/usr/bin/env bash
# Gives the agent its own Signal identity on a dedicated number, so nothing it
# sends ever comes from you and it can't read your personal chats.
set -euo pipefail

usage() { echo "usage: $0 +E164NUMBER [--voice] [--name \"Profile name\"]" >&2; exit 2; }

(($#)) || usage
number="$1"; shift
[[ "$number" =~ ^\+[0-9]{8,15}$ ]] || { echo "error: '$number' is not an E.164 number like +15551234567" >&2; exit 2; }

voice=() profile_name="Claude"
while (($#)); do
  case "$1" in
    --voice) voice=(--voice) ;;
    --name) profile_name="$2"; shift ;;
    *) usage ;;
  esac
  shift
done

command -v signal-cli >/dev/null || { echo "error: signal-cli not on PATH" >&2; exit 1; }

# NOTE: signal-mcp always picks the first account signal-cli knows about, so a
# second account under the same home directory would silently be ignored (or
# worse, win). One account per home; use the Docker setup to run both.
if signal-cli listAccounts 2>/dev/null | grep -q '+'; then
  echo "error: signal-cli already has an account here:" >&2
  signal-cli listAccounts >&2
  echo "signal-mcp only uses one account per home directory; run the bot in Docker instead." >&2
  exit 1
fi

cat <<EOF
Registering $number as a new primary Signal account.
Any other Signal install on this number (a phone, say) will be logged out.

Signal requires a captcha first, solved from the same public IP as this machine:
  1. Open https://signalcaptchas.org/registration/generate.html and solve it
  2. Right-click "Open Signal" and copy the link (it starts with signalcaptcha://)
The token expires within a minute or two, so paste it promptly.
EOF
read -rp "Paste the captcha link: " captcha

signal-cli -a "$number" register ${voice[@]+"${voice[@]}"} --captcha "$captcha"
read -rp "Verification code from the SMS/call: " code
signal-cli -a "$number" verify "${code//-/}"
signal-cli -a "$number" updateProfile --given-name "$profile_name"

echo "==> $number is registered as \"$profile_name\"."
echo "    Set a registration lock PIN so nobody can re-register the number:"
echo "    signal-cli -a $number setPin <PIN>"
