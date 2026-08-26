#!/usr/bin/env bash
set -euo pipefail

config=${RUNNER_CONFIG:-/config/repositories.json}
state_root=${RUNNER_STATE_ROOT:-/runner-state}
distribution=${RUNNER_DISTRIBUTION:-/opt/actions-runner-dist}
labels=${RUNNER_LABELS:-moth-watcher-codex}
command=${1:-run}

repo_key() { printf '%s' "$1" | tr '/.' '--_'; }
runner_dir() { printf '%s/%s' "$state_root" "$(repo_key "$1")"; }

repositories() {
  jq -er '.repositories[] | if type == "string" then . elif (.enabled // true) then .name else empty end' "$config"
}

all_configured_repositories() {
  jq -er '.repositories[] | if type == "string" then . else .name end' "$config"
}

validate_config() {
  jq -e '
    type == "object" and
    (.concurrency | type == "number" and . >= 1 and floor == .) and
    ((.workflow_ref // "") | type == "string") and
    (.repositories | type == "array") and
    ([.repositories[] |
      if type == "string" then test("^cre-chan/[A-Za-z0-9_.-]+$")
      else type == "object" and
        (.name | type == "string" and test("^cre-chan/[A-Za-z0-9_.-]+$")) and
        ((.enabled // true) | type == "boolean") and
        ((.issue_implementation // true) | type == "boolean") and
        ((.pr_feedback // true) | type == "boolean") and
        ((.installed_ref // "") | type == "string") end] | all) and
    (([.repositories[] | if type == "string" then . else .name end] | unique | length) == (.repositories | length))
  ' "$config" >/dev/null || { echo "Invalid runner configuration (owner must be cre-chan)" >&2; exit 2; }
}

prepare_runner() {
  local repo=$1 dir
  dir=$(runner_dir "$repo")
  mkdir -p "$dir"
  [[ -x "$dir/bin/Runner.Listener" ]] || cp -a "$distribution/." "$dir/"
}

register_runner() {
  local repo=$1 token dir
  IFS= read -r token
  [[ -n "$token" ]] || { echo "registration token is required on standard input" >&2; exit 2; }
  prepare_runner "$repo"
  dir=$(runner_dir "$repo")
  if [[ -f "$dir/.runner" ]]; then echo "$repo: already registered"; return; fi
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
  if [[ ! -f "$dir/.runner" ]]; then echo "$repo: not registered"; return; fi
  [[ ! -f "$dir/.runner.pid" ]] || kill "$(<"$dir/.runner.pid")" 2>/dev/null || true
  (cd "$dir" && ./config.sh remove --unattended --token "$token") >/dev/null
  find "$dir" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
  rmdir "$dir"
  echo "$repo: removed"
}

repository_state() {
  local repo=$1 dir state=unregistered
  dir=$(runner_dir "$repo")
  [[ -f "$dir/.runner" ]] && state=registered
  [[ ! -f "$dir/.runner.pid" ]] || ! kill -0 "$(<"$dir/.runner.pid")" 2>/dev/null || state=running
  printf '%s' "$state"
}

status() {
  local repo
  while IFS= read -r repo; do printf '%s\t%s\n' "$repo" "$(repository_state "$repo")"; done < <(all_configured_repositories)
}

status_all() {
  local marker repo
  status
  for marker in "$state_root"/*/.repository; do
    [[ -f "$marker" ]] || continue
    repo=$(<"$marker")
    all_configured_repositories | grep -Fqx "$repo" || printf '%s\tstale\n' "$repo"
  done
}

stop_repo() {
  local repo=$1 pid= dir
  dir=$(runner_dir "$repo")
  [[ ! -f "$dir/.runner.pid" ]] || pid=$(<"$dir/.runner.pid")
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  fi
  find "$dir/.runner.pid" -delete 2>/dev/null || true
}

stop_all() {
  local pid_file repo
  for pid_file in "$state_root"/*/.runner.pid; do
    [[ -f "$pid_file" ]] || continue
    repo=$(<"${pid_file%/*}/.repository")
    stop_repo "$repo"
  done
}

run_all() {
  local repo dir pid concurrency
  trap 'stop_all' TERM INT EXIT
  while :; do
    validate_config
    concurrency=$(jq -er '.concurrency' "$config")
    export CODEX_CONCURRENCY=$concurrency
    for dir in "$state_root"/*; do
      [[ -f "$dir/.repository" ]] || continue
      repo=$(<"$dir/.repository")
      if ! repositories | grep -Fqx "$repo"; then stop_repo "$repo"; fi
    done
    while IFS= read -r repo; do
      [[ -n "$repo" ]] || continue
      dir=$(runner_dir "$repo")
      if [[ ! -f "$dir/.runner" ]]; then echo "$repo: registration missing" >&2; continue; fi
      if [[ -f "$dir/.runner.pid" ]] && kill -0 "$(<"$dir/.runner.pid")" 2>/dev/null; then continue; fi
      mkdir -p "/runner-work/$(repo_key "$repo")"
      (cd "$dir" && ./run.sh) &
      pid=$!
      printf '%s\n' "$pid" >"$dir/.runner.pid"
      echo "$repo: runner started"
    done < <(repositories)
    sleep 5
  done
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
