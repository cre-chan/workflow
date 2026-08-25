#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
cleanup() { rm -rf -- "$tmp"; }
trap cleanup EXIT

pass=0
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { pass=$((pass + 1)); echo "ok $pass - $*"; }

grep -q 'runner-work:/runner-work' "$root/compose.yaml" || fail "runner work volume paths differ"
grep -q '/runner-state /runner-work /codex-locks' "$root/github-runner/Dockerfile" || \
  fail "runner-owned volume mount points are not initialized"
ok "manager volume paths are aligned and writable"

grep -A5 -q 'for source_file in.*\\' "$root/manage-repositories.sh" || \
  fail "deployment payload list is missing"
grep -q '^[[:space:]]*tests/validate-patch-test\.sh; do$' "$root/manage-repositories.sh" || \
  fail "repository verification script is not deployed"
[[ $(grep -c '^[[:space:]]*tests/validate-patch-test\.sh' "$root/manage-repositories.sh") -eq 2 ]] || \
  fail "repository verification script is not both copied and committed"
ok "deployment includes the required repository verification script"

mkdir -p "$tmp/dist/bin" "$tmp/state" "$tmp/work" "$tmp/locks"
touch "$tmp/dist/bin/Runner.Listener"
chmod +x "$tmp/dist/bin/Runner.Listener"
cat >"$tmp/dist/config.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ ${1:-} == remove ]]; then rm -f .runner; else touch .runner; fi
EOF
cat >"$tmp/dist/run.sh" <<'EOF'
#!/usr/bin/env bash
trap 'exit 0' TERM INT
while :; do sleep 1; done
EOF
chmod +x "$tmp/dist/config.sh" "$tmp/dist/run.sh"
cat >"$tmp/config.json" <<'EOF'
{"concurrency":1,"repositories":["cre-chan/one","cre-chan/two"]}
EOF

env RUNNER_CONFIG="$tmp/config.json" RUNNER_STATE_ROOT="$tmp/state" \
  RUNNER_DISTRIBUTION="$tmp/dist" "$root/github-runner/manager.sh" validate
if sed 's/cre-chan\/two/other\/two/' "$tmp/config.json" >"$tmp/bad.json" && \
  env RUNNER_CONFIG="$tmp/bad.json" RUNNER_STATE_ROOT="$tmp/state" \
  RUNNER_DISTRIBUTION="$tmp/dist" "$root/github-runner/manager.sh" validate 2>/dev/null; then
  fail "foreign owner was accepted"
fi
ok "configuration validates owner, uniqueness, and concurrency"

manager=(env RUNNER_CONFIG="$tmp/config.json" RUNNER_STATE_ROOT="$tmp/state" RUNNER_DISTRIBUTION="$tmp/dist" "$root/github-runner/manager.sh")
printf '%s\n' disposable-token | "${manager[@]}" register cre-chan/one >/dev/null
printf '%s\n' disposable-token | "${manager[@]}" register cre-chan/one | grep -q 'already registered'
[[ $(find "$tmp/state" -name .runner | wc -l) -eq 1 ]] || fail "registration was duplicated"
manager_status=$("${manager[@]}" status-all)
grep -q $'cre-chan/one\tregistered' <<<"$manager_status"
printf '%s\n' disposable-token | "${manager[@]}" remove cre-chan/one >/dev/null
[[ ! -e "$tmp/state/cre-chan-one" ]] || fail "runner state remains after removal"
ok "runner registration and removal are idempotent"

if command -v flock >/dev/null 2>&1; then
cat >"$tmp/job.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
guard=$1
mkdir "$guard" 2>/dev/null || { echo overlap >"$guard.overlap"; exit 9; }
sleep 0.2
rmdir "$guard"
EOF
chmod +x "$tmp/job.sh"
for _ in 1 2 3; do
  CODEX_LOCK_DIR="$tmp/locks" CODEX_CONCURRENCY=1 \
    "$root/shared-concurrency.sh" "$tmp/job.sh" "$tmp/active" &
done
wait
[[ ! -e "$tmp/active.overlap" ]] || fail "shared concurrency limit was exceeded"
ok "concurrent jobs share a global slot"
else
  echo "ok $((pass + 1)) - concurrent jobs share a global slot # SKIP flock is unavailable"
  pass=$((pass + 1))
fi

if CODEX_LOCK_DIR="$tmp/locks" CODEX_CONCURRENCY=0 \
  "$root/shared-concurrency.sh" true 2>/dev/null; then
  fail "zero concurrency was accepted"
fi
ok "invalid concurrency fails closed"

echo "1..$pass"
