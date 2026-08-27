#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
test_root=$(mktemp -d)
cleanup() {
  chmod 0755 "$test_root/read-only-config" 2>/dev/null || true
  rm -rf -- "$test_root"
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass=0
ok() { pass=$((pass + 1)); echo "ok $pass - $*"; }

cp "$root/manage-repositories.sh" "$test_root/manage-repositories.sh"
chmod +x "$test_root/manage-repositories.sh"
mkdir -p "$test_root/bin" "$test_root/codex-home"

cat >"$test_root/bin/gh" <<'EOF'
#!/usr/bin/env bash
[[ ${1:-} == auth && ${2:-} == setup-git ]] && exit 0
echo "unexpected gh invocation: $*" >&2
exit 9
EOF
cat >"$test_root/bin/docker" <<'EOF'
#!/usr/bin/env bash
[[ ${1:-} == compose && ${2:-} == run ]] && exit 0
echo "unexpected docker invocation: $*" >&2
exit 9
EOF
chmod +x "$test_root/bin/gh" "$test_root/bin/docker"

printf '%s\n' test-token >"$test_root/admin-token"
chmod 0600 "$test_root/admin-token"
cat >"$test_root/.env" <<EOF
CODEX_AUTH_DIR=$test_root/codex-home
ADMIN_GITHUB_TOKEN_FILE=$test_root/admin-token
UNRELATED=\$(touch "$test_root/dotenv-was-executed")
EOF
cat >"$test_root/repositories.json" <<'EOF'
{"concurrency":1,"workflow_ref":"","repositories":[]}
EOF

PATH="$test_root/bin:$PATH" "$test_root/manage-repositories.sh" status |
  grep -q $'repository\tenabled\tcaller\tactions\tlocal-runner\tgithub-runner'
[[ ! -e "$test_root/dotenv-was-executed" ]] || fail ".env was evaluated as shell code"
ok "host CLI reads only approved literal paths from .env"

cat >"$test_root/.env" <<EOF
ADMIN_GITHUB_TOKEN_FILE=\$(touch "$test_root/approved-value-was-executed")
EOF
if PATH="$test_root/bin:$PATH" "$test_root/manage-repositories.sh" status >/dev/null 2>&1; then
  fail "non-absolute admin token path was accepted"
fi
[[ ! -e "$test_root/approved-value-was-executed" ]] || fail "dotenv value was evaluated"
ok "dotenv values are not evaluated and must be absolute paths"

mkdir "$test_root/read-only-config"
cat >"$test_root/read-only-config/repositories.json" <<'EOF'
{"concurrency":1,"workflow_ref":"","repositories":[{"name":"cre-chan/moth-watcher","enabled":true,"issue_implementation":true,"pr_feedback":true,"installed_ref":""}]}
EOF
chmod 0555 "$test_root/read-only-config"
REPOSITORIES_CONFIG="$test_root/read-only-config/repositories.json" \
  MOTH_ADMIN_CONTEXT=1 "$test_root/manage-repositories.sh" disable moth-watcher >/dev/null
jq -e '.repositories[0].name == "cre-chan/moth-watcher" and .repositories[0].enabled == false' \
  "$test_root/read-only-config/repositories.json" >/dev/null || fail "short repository name was not normalized"
ok "config updates work with a read-only parent and normalize short repository names"

before=$(shasum "$test_root/read-only-config/repositories.json")
if REPOSITORIES_CONFIG="$test_root/read-only-config/repositories.json" \
  MOTH_ADMIN_CONTEXT=1 "$test_root/manage-repositories.sh" disable other/repository >/dev/null 2>&1; then
  fail "foreign repository owner was accepted"
fi
after=$(shasum "$test_root/read-only-config/repositories.json")
[[ "$before" == "$after" ]] || fail "invalid repository changed configuration"
ok "foreign owners are rejected before configuration changes"

echo "1..$pass"
