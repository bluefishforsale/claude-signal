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

do_link=1 do_service=1 do_claude=1 do_desktop=1 readonly_mode=0
device_name="$(hostname -s)" bot_number="" voice=()

usage() {
  cat <<EOF
usage: $0 [--name DEVICE] [--bot-number +E164 [--voice]] [--readonly]
          [--no-link] [--no-service] [--no-claude] [--no-desktop]

  --name DEVICE   linked-device name on your phone, or the bot's profile name (default: $device_name)
  --bot-number N  register N as the agent's own Signal account instead of linking yours
  --voice         with --bot-number, get the verification code by voice call (landlines)
  --readonly      register the MCP server with SIGNAL_MCP_READONLY=1 (no send/edit/delete)
  --no-link       skip linking or registering a Signal account
  --no-service    skip the background message-capture service
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
    --no-service) do_service=0 ;;
    --no-claude) do_claude=0 ;;
    --no-desktop) do_desktop=0 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done

install_signal_cli_macos() {
  command -v brew >/dev/null || die "Homebrew is required on macOS: https://brew.sh"
  brew list signal-cli >/dev/null 2>&1 || brew install signal-cli
  brew list qrencode >/dev/null 2>&1 || brew install qrencode
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
((do_service)) && signal-mcp install-service
((do_claude)) && register_claude "$readonly_mode"
((do_desktop)) && register_desktop "$readonly_mode"

log "Done. Run ./doctor.sh to check every piece."
