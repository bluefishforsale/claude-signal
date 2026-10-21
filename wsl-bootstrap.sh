#!/usr/bin/env bash
# Runs inside WSL for install-windows.ps1: installs what the Linux installer
# expects on a stock Ubuntu, gets this repo into ~/claude-signal, and hands off
# to install.sh with whatever arguments the PowerShell script was given.
set -euo pipefail

repo="${CLAUDE_SIGNAL_REPO:-https://github.com/bluefishforsale/claude-signal}"
dest="$HOME/claude-signal"

echo "==> Installing packages (sudo asks for your Linux password)"
sudo apt-get update -qq
sudo apt-get install -y -qq git curl ca-certificates qrencode sqlcipher libsecret-tools

if ! command -v uv >/dev/null && [[ ! -x "$HOME/.local/bin/uv" ]]; then
  echo "==> Installing uv"
  curl -LsSf https://astral.sh/uv/0.11.6/install.sh | sh
fi
export PATH="$HOME/.local/bin:$PATH"

if [[ -d "$dest/.git" ]]; then
  git -C "$dest" pull --ff-only -q
else
  git clone -q "$repo" "$dest"
fi

exec "$dest/install.sh" "$@"
