#!/usr/bin/env bash
set -euo pipefail

runner_root=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if [[ ${CODEX_CONCURRENCY_LOCKED:-0} != 1 ]]; then
  export CODEX_CONCURRENCY_LOCKED=1
  exec "$runner_root/shared-concurrency.sh" "$0" "$@"
fi

request_file=${1:?request JSON is required}
automation_home=${CODEX_AUTOMATION_HOME:?Set CODEX_AUTOMATION_HOME in the self-hosted runner service environment}
repository_root=$(git rev-parse --show-toplevel)
image=moth-watcher-codex-runner:0.149.0
worker_id="${GITHUB_RUN_ID:-manual}-${GITHUB_RUN_ATTEMPT:-1}-$$"
worker_name="moth-watcher-codex-${worker_id}"
worker_volume="moth-watcher-codex-work-${worker_id}"

find "$repository_root/.codex-result" -depth -delete 2>/dev/null || true
mkdir -p "$repository_root/.codex-result"

cleanup() {
  docker rm --force "$worker_name" >/dev/null 2>&1 || true
  docker volume rm --force "$worker_volume" >/dev/null 2>&1 || true
  docker image prune --force \
    --filter "label=org.opencontainers.image.title=moth-watcher-codex-runner" \
    >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker build --pull \
  --file "$runner_root/Dockerfile" \
  --tag "$image" "$runner_root"

docker volume create "$worker_volume" >/dev/null

tar -C "$repository_root" -cf - . | docker run --rm --interactive \
  --user 1000:1000 \
  --mount "type=volume,src=${worker_volume},dst=/workspace" \
  --entrypoint /bin/tar \
  "$image" -C /workspace -xf -

docker run --rm \
  --name "$worker_name" \
  --user 1000:1000 \
  --cap-drop ALL \
  --security-opt no-new-privileges \
  --security-opt seccomp=unconfined \
  --pids-limit 256 \
  --memory 6g \
  --cpus 3 \
  --read-only \
  --tmpfs /tmp:rw,noexec,nosuid,size=1g \
  --tmpfs /home/codex:rw,noexec,nosuid,size=64m \
  --mount "type=volume,src=${worker_volume},dst=/workspace" \
  --mount "type=bind,src=${automation_home},dst=/codex-auth" \
  --env CODEX_HOME=/codex-auth \
  --env HOME=/tmp/home \
  "$image" "/workspace/${request_file#./}"

docker run --rm \
  --user 1000:1000 \
  --mount "type=volume,src=${worker_volume},dst=/workspace,readonly" \
  --entrypoint /bin/tar \
  "$image" -C /workspace -cf - .codex-result | \
  tar -C "$repository_root" -xf -

required_results=(base-sha.txt codex.patch summary.md test-results.md)
for result_file in "${required_results[@]}"; do
  [[ -f "$repository_root/.codex-result/$result_file" && \
     ! -L "$repository_root/.codex-result/$result_file" ]] || {
    echo "Missing or unsafe result file: $result_file" >&2
    exit 1
  }
done

unexpected_result=$(find "$repository_root/.codex-result" -mindepth 1 -maxdepth 1 \
  ! -type f -o -type f \
  ! -name base-sha.txt \
  ! -name codex.patch \
  ! -name summary.md \
  ! -name test-results.md \
  -print -quit)
[[ -z "$unexpected_result" ]] || {
  echo "Unexpected result entry: $unexpected_result" >&2
  exit 1
}
