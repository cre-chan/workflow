#!/usr/bin/env bash
set -euo pipefail

lock_root=${CODEX_LOCK_DIR:-/codex-locks}
limit=${CODEX_CONCURRENCY:-1}
command=${1:-}
shift || true

[[ "$limit" =~ ^[1-9][0-9]*$ ]] || { echo "CODEX_CONCURRENCY must be a positive integer" >&2; exit 2; }
[[ -n "$command" ]] || { echo "A command is required" >&2; exit 2; }
command -v flock >/dev/null 2>&1 || { echo "flock is required" >&2; exit 2; }
mkdir -p "$lock_root"

try_slot() {
  local lock_file=$1
  shift
  (
    flock --nonblock 9 || exit 75
    "$@"
  ) 9>"$lock_file"
}

while :; do
  for ((slot=1; slot<=limit; slot++)); do
    # Each background runner shares this directory. flock releases the slot on
    # exit, including signals and worker failures.
    try_slot "$lock_root/slot-$slot.lock" "$command" "$@" && exit 0
    status=$?
    [[ $status -eq 75 ]] || exit "$status"
  done
  sleep 1
done
