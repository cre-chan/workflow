#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fail() { echo "FAIL: $*" >&2; exit 1; }

help=$("$root/manage-repositories.sh" --help)
for command in bootstrap-admin install update upgrade upgrade-all disable remove status concurrency compile; do
  grep -q "manage-repositories.sh $command" <<<"$help" || fail "help omits $command"
  rg -q "manage-repositories\.sh $command" "$root/docs/SETUP.md" || fail "setup omits $command"
done

for service in workspace-init docker-daemon runner-manager repository-admin; do
  grep -q "^  $service:" "$root/compose.yaml" || fail "Compose omits $service"
  rg -q "$service" "$root/docs/SETUP.md" || fail "setup omits $service"
done

for variable in CODEX_AUTH_DIR ADMIN_GITHUB_TOKEN_FILE; do
  rg -q "^$variable=" "$root/.env.example" || fail ".env.example omits $variable"
  rg -q "$variable" "$root/docs/SETUP.md" || fail "setup omits $variable"
done

rg -q 'templates/codex-automation\.yml' "$root/README.md" || fail "README omits caller template"
rg -q '\.github/workflows/codex-automation\.yml' "$root/docs/SETUP.md" || fail "setup omits target path"
if rg -q 'secrets:[[:space:]]*inherit' "$root/templates/codex-automation.yml"; then
  fail "target caller inherits repository secrets"
fi
rg -q 'GH_AW_DOCKER_SOCK_PATH: /dind-sock/docker.sock' "$root/compose.yaml" || fail "gh-aw split-daemon socket is not configured"
rg -q 'dind-sock' "$root/docs/SETUP.md" || fail "setup omits nested daemon socket boundary"
if rg -q '/tmp/gh-aw' "$root/.github/workflows/reusable-codex-"*.lock.yml; then
  fail "compiled workflows retain a process-global gh-aw temporary path"
fi
rg -q 'awmg-mcpg-\$\{GITHUB_RUN_ID\}-\$\{GITHUB_RUN_ATTEMPT\}' \
  "$root/.github/workflows/reusable-codex-issue.lock.yml" || fail "gateway container name is not job-specific"
rg -q '20000 \+ GITHUB_RUN_ID % 20000' \
  "$root/.github/workflows/reusable-codex-issue.lock.yml" || fail "gateway port is not job-specific"
if rg -q 'CODEX_APP_ID|CODEX_APP_PRIVATE_KEY|workflow-codex App' \
  "$root/README.md" "$root/SKILL.md" "$root/docs/SETUP.md"; then
  fail "documentation still requires the retired GitHub App"
fi

echo "documentation commands, services, variables, and paths are current"
