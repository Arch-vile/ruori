FROM ubuntu:24.04
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash git tmux fzf jq shellcheck curl \
    && rm -rf /var/lib/apt/lists/*
COPY ruori-claude-status-hook /usr/local/bin/ruori-claude-status-hook
RUN chmod +x /usr/local/bin/ruori-claude-status-hook
COPY claude-settings.json /root/.claude/settings.json
WORKDIR /workspace
