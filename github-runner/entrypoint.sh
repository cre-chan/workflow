#!/usr/bin/env bash
set -euo pipefail

runner_dir=/runner
distribution=/opt/actions-runner-dist
command=${1:-run}

initialize_files() {
  if [[ ! -x "$runner_dir/bin/Runner.Listener" ]]; then
    cp -a "$distribution/." "$runner_dir/"
  fi
}

initialize_files
cd "$runner_dir"

verify_work_directory() {
  local work_dir="$runner_dir/_work"

  if [[ ! -d "$work_dir" || ! -w "$work_dir" ]]; then
    echo "Runner work directory is not writable: $work_dir" >&2
    echo "Expected ownership: 1000:1000 with mode 0755." >&2
    echo "Repair it with: docker compose run --rm workspace-init" >&2
    exit 1
  fi

  if ! mkdir -p "$work_dir/_tool"; then
    echo "Runner tool cache cannot be created: $work_dir/_tool" >&2
    echo "Repair it with: docker compose run --rm workspace-init" >&2
    exit 1
  fi
}

case "$command" in
  register)
    : "${RUNNER_URL:?RUNNER_URL is required}"
    : "${RUNNER_TOKEN:?RUNNER_TOKEN is required for one-time registration}"
    : "${RUNNER_NAME:?RUNNER_NAME is required}"
    if [[ -f .runner ]]; then
      echo "Runner is already registered" >&2
      exit 1
    fi
    ./config.sh --unattended --replace \
      --url "$RUNNER_URL" \
      --token "$RUNNER_TOKEN" \
      --name "$RUNNER_NAME" \
      --labels "${RUNNER_LABELS:-moth-watcher-codex}" \
      --work _work
    ;;
  run)
    [[ -f .runner ]] || {
      echo "Runner is not registered. Run the one-time register command first." >&2
      exit 1
    }
    verify_work_directory
    exec ./run.sh
    ;;
  *)
    echo "Unknown command: $command" >&2
    exit 2
    ;;
esac
