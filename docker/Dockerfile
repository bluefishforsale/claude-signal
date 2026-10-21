# One long-running container owns the signal-cli daemon and the message store.
# It runs the daemon rather than `signal-mcp receive --watch`, because the
# watcher stops the daemon on every poll and MCP tools then fail.
# MCP clients attach with `docker exec -i claude-signal signal-mcp serve`
# because upstream hardcodes the daemon at localhost:7583 and spawns signal-cli
# as a subprocess, so a split daemon/server pair can't work.
# NOTE: the JVM build, not the native one. The native binary exits with "CPU ISA
# level is lower than required" on older x86 and under amd64 emulation on
# Apple Silicon. libsignal is bundled for x86_64 only, so compose pins amd64.
# Fetched in a Debian stage because Ubuntu 26.04's tar fails under emulation.
FROM debian:trixie-slim AS fetch
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*
COPY versions.env /tmp/
RUN . /tmp/versions.env \
 && tarball="signal-cli-${SIGNAL_CLI_VERSION}.tar.gz" \
 && curl -fsSL -o "/tmp/$tarball" \
      "https://github.com/AsamK/signal-cli/releases/download/v${SIGNAL_CLI_VERSION}/$tarball" \
 && echo "${SIGNAL_CLI_JVM_SHA256}  /tmp/$tarball" | sha256sum -c --quiet \
 && mkdir /out && tar -xzf "/tmp/$tarball" -C /out --strip-components=1

FROM eclipse-temurin:25-jre

RUN apt-get update \
 && apt-get install -y --no-install-recommends qrencode \
 && rm -rf /var/lib/apt/lists/*

COPY --from=ghcr.io/astral-sh/uv:0.11.6 /uv /usr/local/bin/uv

COPY versions.env constraints.txt /opt/claude-signal/

COPY --from=fetch /out /opt/signal-cli
RUN ln -s /opt/signal-cli/bin/signal-cli /usr/local/bin/signal-cli

ENV UV_PYTHON_INSTALL_DIR=/opt/python UV_NO_CACHE=1
RUN . /opt/claude-signal/versions.env \
 && uv venv -q --python "$PYTHON_VERSION" /opt/claude-signal/venv \
 && VIRTUAL_ENV=/opt/claude-signal/venv uv pip install -q --require-hashes -r /opt/claude-signal/constraints.txt \
 && ln -s /opt/claude-signal/venv/bin/signal-mcp /usr/local/bin/signal-mcp

COPY link.sh register.sh /usr/local/bin/

RUN useradd --create-home signal \
 && mkdir -p /home/signal/.local/share /home/signal/Downloads/signal-attachments \
 && chown -R signal: /home/signal
USER signal
WORKDIR /home/signal
VOLUME ["/home/signal/.local/share"]

CMD ["signal-mcp", "daemon"]
