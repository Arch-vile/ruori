FROM ubuntu:24.04
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash git tmux fzf jq shellcheck curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*
# Native Claude Code binary install (no Node/npm needed) — auth is handled
# separately; this just gets `claude` onto PATH. set -o pipefail so a failed
# curl (e.g. missing ca-certificates) fails the build instead of silently
# piping nothing into bash.
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
RUN curl -fsSL https://claude.ai/install.sh | bash
ENV PATH="/root/.local/bin:${PATH}"
COPY .devcontainer/ruori-claude-status-hook /usr/local/bin/ruori-claude-status-hook
RUN chmod +x /usr/local/bin/ruori-claude-status-hook
COPY .devcontainer/claude-settings.json /root/.claude/settings.json
COPY .devcontainer/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
WORKDIR /workspace
