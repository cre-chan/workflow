#!/usr/bin/env bash
set -euo pipefail

config=${RUNNER_CONFIG:-/config/repositories.json}
state_root=${RUNNER_STATE_ROOT:-/runner-state}
distribution=${RUNNER_DISTRIBUTION:-/opt/actions-runner-dist}
labels=${RUNNER_LABELS:-moth-watcher-codex}
command=${1:-run}

repo_key() { printf '%s' "$1" | tr '/.' '--_'; }

repositories() {
  jq -er '.repositories[] | select(type == "string")' "$config"
}

validate_config() {
  jq -e '
    type == "object" and
    (.concurrency | type == "number" and . >= 1 and floor == .) and
    (.repositories | type == "array") and
    ([.repositories[] | test("^cre-chan/[A-Za-z0-9_.-]+$")] | all) and
    ((.repositories | unique | length) == (.repositories | length))
  ' "$config" >/dev/null || {
    echo "Invalid runner configuration (owner must be cre-chan)" >&2
    exit 2
  }
}

runner_dir() { printf '%s/%s' "$state_root" "$(repo_key "$1")"; }

prepare_runner() {
  local repo=$1 dir
  dir=$(runner_dir "$repo")
  mkdir -p "$dir"
  if [[ ! -x "$dir/bin/Runner.Listener" ]]; then
    cp -a "$distribution/." "$dir/"
  fi
}

register_runner() {
  local repo=$1 token dir
  IFS= read -r token
  [[ -n "$token" ]] || { echo "registration token is required on standard input" >&2; exit 2; }
  prepare_runner "$repo"
  dir=$(runner_dir "$repo")
  if [[ -f "$dir/.runner" ]]; then
    echo "$repo: already registered"
    return
  fi
  (cd "$dir" && ./config.sh --unattended --replace \
    --url "https://github.com/$repo" --token "$token" \
    --name "workflow-codex-$(repo_key "$repo")" --labels "$labels" \
    --work "/runner-work/$(repo_key "$repo")") >/dev/null
  printf '%s\n' "$repo" >"$dir/.repository"
  echo "$repo: registered"
}

remove_runner() {
  local repo=$1 token dir
  IFS= read -r token
  [[ -n "$token" ]] || { echo "removal token is required on standard input" >&2; exit 2; }
  dir=$(runner_dir "$repo")
  if [[ ! -f "$dir/.runner" ]]; then
    echo "$repo: not registered"
    return
  fi
  (cd "$dir" && ./config.sh remove --unattended --token "$token") >/dev/null
  find "$dir" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
  rmdir "$dir"
  echo "$repo: removed"
}

status() {
  local repo dir state
  while IFS= read -r repo; do
    dir=$(runner_dir "$repo")
    state=unregistered
    [[ -f "$dir/.runner" ]] && state=registered
    [[ -f "$dir/.runner.pid" ]] && kill -0 "$(<"$dir/.runner.pid")" 2>/dev/null && state=running
    printf '%s\t%s\n' "$repo" "$state"
  done < <(repositories)
}

status_all() {
  local marker repo configured state
  status
  for marker in "$state_root"/*/.repository; do
    [[ -f "$marker" ]] || continue
    repo=$(<"$marker")
    configured=$(jq -r --arg repo "$repo" '.repositories | index($repo) != null' "$config")
    if [[ "$configured" == false ]]; then
      state=stale
      [[ -f "${marker%/*}/.runner" ]] || state=unregistered
      printf '%s\t%s\n' "$repo" "$state"
    fi
  done
}

run_all() {
  local repo dir pid concurrency count=0
  concurrency=$(jq -er '.concurrency' "$config")
  export CODEX_CONCURRENCY=$concurrency
  trap 'kill $(jobs -pr) 2>/dev/null || true; wait || true' TERM INT EXIT
  while IFS= read -r repo; do
    dir=$(runner_dir "$repo")
    [[ -f "$dir/.runner" ]] || { echo "$repo: registration missing" >&2; exit 1; }
    mkdir -p "/runner-work/$(repo_key "$repo")"
    (cd "$dir" && ./run.sh) &
    pid=$!
    printf '%s\n' "$pid" >"$dir/.runner.pid"
    echo "$repo: runner started"
    count=$((count + 1))
  done < <(repositories)
  if [[ $count -eq 0 ]]; then
    echo "No repositories configured; manager is idle"
    while :; do sleep 3600; done
  fi
  wait -n
  echo "A runner process stopped unexpectedly" >&2
  exit 1
}

validate_config
case "$command" in
  validate) ;;
  status) status ;;
  status-all) status_all ;;
  register) register_runner "${2:?repository is required}" ;;
  remove) remove_runner "${2:?repository is required}" ;;
  run) run_all ;;
  *) echo "Usage: $0 {validate|status|status-all|register OWNER/REPO|remove OWNER/REPO|run}" >&2; exit 2 ;;
esac
