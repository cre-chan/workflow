FROM docker@sha256:000bb62ff495f986c9f5578eb67cc2cb98b91138eda81d7762d5371eb8a497fe AS docker-cli

FROM ubuntu@sha256:33ceb71981b602c1a7443a53469e4dba065f7503eab3078a2d7a57a2ab987517

ARG ACTIONS_RUNNER_VERSION=2.336.0
ARG ACTIONS_RUNNER_SHA256=58b758e420b87093fbd4bfddd368074960053e2f1388f01848c82624b90f27d1

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      ca-certificates curl git jq libicu74 \
    && rm -rf /var/lib/apt/lists/* \
    && usermod --login runner --home /home/runner --move-home ubuntu \
    && groupmod --new-name runner ubuntu \
    && mkdir -p /opt/actions-runner-dist /opt/moth-watcher-runner /runner \
    && curl --fail --location --silent --show-error \
      "https://github.com/actions/runner/releases/download/v${ACTIONS_RUNNER_VERSION}/actions-runner-linux-arm64-${ACTIONS_RUNNER_VERSION}.tar.gz" \
      --output /tmp/actions-runner.tar.gz \
    && echo "${ACTIONS_RUNNER_SHA256}  /tmp/actions-runner.tar.gz" | sha256sum --check --strict \
    && tar -xzf /tmp/actions-runner.tar.gz -C /opt/actions-runner-dist \
    && rm /tmp/actions-runner.tar.gz \
    && chown -R runner:runner /opt/actions-runner-dist /runner

COPY --from=docker-cli /usr/local/bin/docker /usr/local/bin/docker
COPY --from=docker-cli /usr/local/libexec/docker/cli-plugins/docker-buildx /usr/local/libexec/docker/cli-plugins/docker-buildx
COPY --chown=runner:runner Dockerfile Dockerfile.dockerignore container-entrypoint.sh run-codex-container.sh /opt/moth-watcher-runner/
COPY --chmod=0555 github-runner/entrypoint.sh /usr/local/bin/github-runner-entrypoint

USER runner
WORKDIR /runner
ENTRYPOINT ["/usr/local/bin/github-runner-entrypoint"]
CMD ["run"]
