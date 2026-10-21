#!/usr/bin/env bash
# One idempotent entry point that gets signal-cli and signal-mcp onto a Mac or
# Linux box at audited versions and wires them into Claude Code and Claude
# Desktop. Safe to rerun: every step checks whether it's already done.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=versions.env
. "$here/versions.env"
# shellcheck source=lib.sh
. "$here/lib.sh"

do_link=1 do_history=1 do_service=0 do_claude=1 do_desktop=1 readonly_mode=0
device_name="$(hostname -s)" bot_number="" voice=()

usage() {
  cat <<EOF
usage: $0 [--name DEVICE] [--bot-number +E164 [--voice]] [--readonly]
          [--service] [--no-link] [--no-history] [--no-claude] [--no-desktop]

  --name DEVICE   linked-device name on your phone, or the bot's profile name (default: $device_name)
  --bot-number N  register N as the agent's own Signal account instead of linking yours
  --voice         with --bot-number, get the verification code by voice call (landlines)
  --readonly      register the MCP server with SIGNAL_MCP_READONLY=1 (no send/edit/delete)
  --service       install signal-mcp's background capture service (see README first)
  --no-link       skip linking or registering a Signal account
  --no-history    skip importing older messages from Signal Desktop
  --no-claude     skip registering the server with Claude Code
  --no-desktop    skip adding the server to Claude Desktop (macOS)
EOF
}

while (($#)); do
  case "$1" in
    --name) device_name="$2"; shift ;;
    --bot-number) bot_number="$2"; shift ;;
    --voice) voice=(--voice) ;;
    --readonly) readonly_mode=1 ;;
    --no-link) do_link=0 ;;
    --no-history) do_history=0 ;;
    --service) do_service=1 ;;
    --no-claude) do_claude=0 ;;
    --no-desktop) do_desktop=0 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done

install_signal_cli_macos() {
  if ! command -v brew >/dev/null; then
    log "Installing Homebrew (it asks for your password and may install the Xcode Command Line Tools)"
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    # A fresh install isn't on PATH until the user's shell profile is updated.
    local brew_bin
    for brew_bin in /opt/homebrew/bin/brew /usr/local/bin/brew; do
      [[ -x "$brew_bin" ]] && eval "$("$brew_bin" shellenv)" && break
    done
    command -v brew >/dev/null || die "Homebrew install didn't finish; see https://brew.sh"
  fi
  brew list signal-cli >/dev/null 2>&1 || brew install signal-cli
  brew list qrencode >/dev/null 2>&1 || brew install qrencode
  # For the Signal Desktop history import. Homebrew's comes first in
  # signal-mcp's lookup, so it also shadows an older /usr/local copy.
  brew list sqlcipher >/dev/null 2>&1 || brew install sqlcipher
  command -v uv >/dev/null || brew install uv
  # NOTE: Homebrew only ships the latest signal-cli, so the pin is advisory here.
  # A mismatch means you're running a version nobody audited for this repo.
  local have
  have="$(signal-cli --version | awk '{print $2}')"
  [[ "$have" == "$SIGNAL_CLI_VERSION" ]] ||
    warn "Homebrew signal-cli is $have, this repo pins $SIGNAL_CLI_VERSION"
}

install_signal_cli_linux() {
  # The native build is x86_64 only, and the JVM build bundles libsignal for
  # x86_64 only, so other architectures need a hand-built libsignal.
  [[ "$(uname -m)" == x86_64 ]] ||
    die "signal-cli ships prebuilt binaries for x86_64 Linux only, see https://github.com/AsamK/signal-cli/wiki/Provide-native-lib-for-libsignal"

  local dest="$data_dir/signal-cli-$SIGNAL_CLI_VERSION"
  if [[ ! -x "$dest/signal-cli" ]]; then
    local tarball="signal-cli-$SIGNAL_CLI_VERSION-Linux-native.tar.gz"
    local tmp
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' RETURN
    log "Downloading $tarball"
    curl -fsSL -o "$tmp/$tarball" \
      "https://github.com/AsamK/signal-cli/releases/download/v$SIGNAL_CLI_VERSION/$tarball"
    echo "$SIGNAL_CLI_LINUX_NATIVE_SHA256  $tmp/$tarball" | sha256sum -c --quiet ||
      die "checksum mismatch for $tarball"
    mkdir -p "$dest"
    tar -xzf "$tmp/$tarball" -C "$dest"
  fi
  mkdir -p "$bin_dir"
  ln -sf "$dest/signal-cli" "$bin_dir/signal-cli"
  # The native build refuses older CPUs with "CPU ISA level is lower than required".
  "$dest/signal-cli" --version >/dev/null ||
    die "the native signal-cli build won't run on this CPU; use the Docker setup, which runs the JVM build"

  command -v qrencode >/dev/null ||
    warn "qrencode not found; install it (e.g. sudo apt install qrencode) before linking"
}

install_signal_mcp() {
  command -v uv >/dev/null || die "uv is required: https://docs.astral.sh/uv/getting-started/installation/"
  if [[ -x "$venv/bin/signal-mcp" ]] &&
     "$venv/bin/signal-mcp" --version | grep -q "$SIGNAL_MCP_VERSION"; then
    log "signal-mcp $SIGNAL_MCP_VERSION already installed"
  else
    log "Installing signal-mcp $SIGNAL_MCP_VERSION with hash-verified dependencies"
    # NOTE: `uv tool install -c` silently ignores hashes in a constraints file,
    # so a plain venv plus `uv pip install --require-hashes` is what actually
    # enforces the lock. Don't "simplify" this back to uv tool install.
    rm -rf "$venv"
    uv venv -q --python "$PYTHON_VERSION" "$venv"
    VIRTUAL_ENV="$venv" uv pip install -q --require-hashes -r "$here/constraints.txt"
  fi
  mkdir -p "$bin_dir"
  ln -sf "$venv/bin/signal-mcp" "$bin_dir/signal-mcp"
}

# A newly linked device only receives messages from now on, so Signal Desktop's
# local database is the only source of older history on this machine.
import_history() {
  local desktop_db
  case "$(uname -s)" in
    Darwin) desktop_db="$HOME/Library/Application Support/Signal/sql/db.sqlite" ;;
    *) desktop_db="${XDG_CONFIG_HOME:-$HOME/.config}/Signal/sql/db.sqlite" ;;
  esac
  if [[ ! -f "$desktop_db" ]]; then
    log "Signal Desktop not found; history starts from when this device was linked"
    return
  fi
  # Same lookup order as signal-mcp's _find_sqlcipher.
  local sqlcipher
  for sqlcipher in /opt/homebrew/bin/sqlcipher /usr/local/bin/sqlcipher "$(command -v sqlcipher || true)"; do
    [[ -x "$sqlcipher" ]] && break
  done
  if [[ ! -x "$sqlcipher" ]]; then
    warn "sqlcipher not found, skipping history import (Linux: sudo apt install sqlcipher libsecret-tools)"
    return
  fi
  # NOTE: Signal Desktop's schema uses the ->> JSON operator (SQLite 3.38+).
  # An older sqlcipher fails the import with 'malformed database schema'.
  if ! echo "select json('{\"a\":1}') ->> '\$.a';" | "$sqlcipher" :memory: >/dev/null 2>&1; then
    warn "$sqlcipher is built on SQLite older than 3.38 and can't read Signal Desktop's database; upgrade it, then run: signal-mcp import-desktop"
    return
  fi
  log "Importing message history from Signal Desktop (macOS asks for Keychain access; click Allow)"
  signal-mcp import-desktop
}

case "$(uname -s)" in
  Darwin) install_signal_cli_macos ;;
  Linux) install_signal_cli_linux ;;
  *) die "unsupported OS $(uname -s); try the Docker setup" ;;
esac
install_signal_mcp

case ":$PATH:" in
  *":$bin_dir:"*) ;;
  *) export PATH="$bin_dir:$PATH"; warn "$bin_dir is not on your PATH; add it to your shell profile" ;;
esac

if ((do_link)); then
  if [[ -n "$bot_number" ]]; then
    "$here/register.sh" "$bot_number" ${voice[@]+"${voice[@]}"} --name "$device_name"
  else
    "$here/link.sh" "$device_name"
  fi
fi
# NOTE: off by default. In signal-mcp 1.43.3, once the service is installed the
# MCP server refuses to start a daemon (client.py ensure_daemon) while the
# watcher stops any daemon on every poll, so every daemon-backed tool fails with
# "signal-cli daemon not running". Flip the default once upstream fixes that.
((do_history)) && import_history
((do_service)) && signal-mcp install-service
((do_claude)) && register_claude "$readonly_mode"
((do_desktop)) && register_desktop "$readonly_mode"

log "Done. Run ./doctor.sh to check every piece."
