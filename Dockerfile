FROM node:22-bookworm-slim@sha256:d649c27dae7ba0137b3cef5dd75baa422c08dc3d9e3fc0c23dfb172dc3cc6436 AS codex-cli

ARG CODEX_VERSION=0.149.0

RUN npm install --global "@openai/codex@${CODEX_VERSION}"

FROM python:3.13-slim-bookworm@sha256:00faa2debb87529f9f0764e9491d8ba400a3678976616c3bd7cb193745ac20d1

LABEL org.opencontainers.image.title="moth-watcher-codex-runner"

RUN apt-get update \
    && apt-get install -y --no-install-recommends bubblewrap git jq ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY --from=codex-cli /usr/local/bin/node /usr/local/bin/node
COPY --from=codex-cli /usr/local/lib/node_modules /usr/local/lib/node_modules
RUN ln -s /usr/local/lib/node_modules/@openai/codex/bin/codex.js /usr/local/bin/codex

RUN useradd --create-home --uid 1000 codex \
    && mkdir -p /workspace \
    && chown codex:codex /workspace
COPY --chmod=0555 container-entrypoint.sh /usr/local/libexec/moth-watcher/container-entrypoint.sh
USER codex
WORKDIR /workspace

ENTRYPOINT ["/bin/bash", "/usr/local/libexec/moth-watcher/container-entrypoint.sh"]
