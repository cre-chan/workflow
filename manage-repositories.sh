#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
config=${REPOSITORIES_CONFIG:-$root/repositories.json}
action=${1:-help}
repo=${2:-}

require_repo() {
  [[ "$repo" =~ ^cre-chan/[A-Za-z0-9_.-]+$ ]] || {
    echo "Repository must use cre-chan/REPOSITORY form" >&2; exit 2;
  }
}

github_admin_checks() {
  gh auth status >/dev/null 2>&1 || { echo "GitHub CLI authentication is unavailable" >&2; exit 1; }
  gh api "repos/$repo" --jq '.permissions.admin' | grep -qx true || {
    echo "$repo: admin permission is required" >&2; exit 1;
  }
}

github_app_checks() {
  local app_id=${CODEX_APP_ID:-} key=${CODEX_APP_PRIVATE_KEY_FILE:-}
  local now issued_at expires_at header payload unsigned signature jwt
  github_admin_checks
  [[ "$app_id" =~ ^[0-9]+$ ]] || { echo "CODEX_APP_ID must be set" >&2; exit 2; }
  [[ -f "$key" && ! -L "$key" && -r "$key" ]] || { echo "Private key file is missing or unsafe" >&2; exit 2; }
  now=$(date +%s)
  issued_at=$((now - 60))
  expires_at=$((now + 540))
  header=$(printf '%s' '{"alg":"RS256","typ":"JWT"}' | openssl base64 -A | tr '+/' '-_' | tr -d '=')
  payload=$(printf '{"iat":%s,"exp":%s,"iss":"%s"}' "$issued_at" "$expires_at" "$app_id" | \
    openssl base64 -A | tr '+/' '-_' | tr -d '=')
  unsigned="$header.$payload"
  signature=$(printf '%s' "$unsigned" | openssl dgst -sha256 -sign "$key" | \
    openssl base64 -A | tr '+/' '-_' | tr -d '=')
  jwt="$unsigned.$signature"
  printf '%s\n' \
    'silent' \
    'show-error' \
    'fail' \
    'header = "Accept: application/vnd.github+json"' \
    'header = "X-GitHub-Api-Version: 2022-11-28"' \
    "header = \"Authorization: Bearer $jwt\"" \
    "url = \"https://api.github.com/repos/$repo/installation\"" | \
    curl --config - | jq -e '.app_slug == "workflow-codex"' >/dev/null || {
    echo "$repo: install workflow-codex in the browser before retrying" >&2; exit 1;
  }
}

configure_repository() {
  local app_id=${CODEX_APP_ID:-} key=${CODEX_APP_PRIVATE_KEY_FILE:-}
  [[ "$app_id" =~ ^[0-9]+$ ]] || { echo "CODEX_APP_ID must be set" >&2; exit 2; }
  [[ -f "$key" && ! -L "$key" && -r "$key" ]] || { echo "Private key file is missing or unsafe" >&2; exit 2; }
  github_app_checks
  gh variable set CODEX_APP_ID --repo "$repo" --body "$app_id" >/dev/null
  gh secret set CODEX_APP_PRIVATE_KEY --repo "$repo" <"$key" >/dev/null
  gh label create agent-ready --repo "$repo" --color 0e8a16 --force >/dev/null
  echo "$repo: GitHub settings configured"
}

deploy_repository() {
  local checkout default_branch changed=0 source_file
  github_admin_checks
  checkout=$(mktemp -d)
  trap 'rm -rf -- "$checkout"' RETURN
  default_branch=$(gh api "repos/$repo" --jq '.default_branch')
  gh repo clone "$repo" "$checkout" -- --depth=1 --branch "$default_branch" >/dev/null
  for source_file in \
    .github/workflows/codex-agent-ready.yml \
    .github/scripts/validate-and-apply-patch.sh \
    .github/ISSUE_TEMPLATE/agentic-story.yml \
    tests/validate-patch-test.sh; do
    mkdir -p "$checkout/$(dirname "$source_file")"
    if [[ ! -f "$checkout/$source_file" ]] || ! cmp -s "$root/$source_file" "$checkout/$source_file"; then
      cp "$root/$source_file" "$checkout/$source_file"
      changed=1
    fi
  done
  if [[ $changed -eq 0 ]]; then
    echo "$repo: deployment already current"
    return
  fi
  while IFS= read -r -d '' source_file; do
    bash -n "$source_file"
  done < <(find "$checkout" -maxdepth 1 -type f -name '*.sh' -print0)
  bash -n "$checkout/.github/scripts"/*.sh
  bash -n "$checkout/tests/validate-patch-test.sh"
  bash "$checkout/tests/validate-patch-test.sh" >/dev/null 2>&1 || {
    echo "$repo: validation failed; no commit was made" >&2
    exit 1
  }
  (cd "$checkout" && git add -- \
    .github/workflows/codex-agent-ready.yml \
    .github/scripts/validate-and-apply-patch.sh \
    .github/ISSUE_TEMPLATE/agentic-story.yml \
    tests/validate-patch-test.sh && \
    git config user.name 'workflow-codex setup' && \
    git config user.email 'workflow-codex-setup@users.noreply.github.com' && \
    git commit -m 'Set up Codex issue workflow' >/dev/null && git push origin "HEAD:$default_branch" >/dev/null)
  echo "$repo: deployment committed to $default_branch"
}

case "$action" in
  add)
    require_repo
    configure_repository
    if jq -e --arg repo "$repo" '.repositories | index($repo)' "$config" >/dev/null; then
      echo "$repo: already configured"
    else
      tmp=$(mktemp "${config}.tmp.XXXXXX"); trap 'rm -f -- "$tmp"' EXIT
      jq --arg repo "$repo" '.repositories += [$repo] | .repositories |= sort' "$config" >"$tmp"
      mv "$tmp" "$config"; trap - EXIT
      echo "$repo: added; run sync to register its runner"
    fi
    ;;
  update) require_repo; configure_repository ;;
  deploy) require_repo; deploy_repository ;;
  remove)
    require_repo
    tmp=$(mktemp "${config}.tmp.XXXXXX"); trap 'rm -f -- "$tmp"' EXIT
    jq --arg repo "$repo" '.repositories -= [$repo]' "$config" >"$tmp"
    mv "$tmp" "$config"; trap - EXIT
    echo "$repo: removed from configuration; run sync to unregister stale runners"
    ;;
  concurrency)
    value=${2:-}
    [[ "$value" =~ ^[1-9][0-9]*$ ]] || { echo "Concurrency must be a positive integer" >&2; exit 2; }
    tmp=$(mktemp "${config}.tmp.XXXXXX"); trap 'rm -f -- "$tmp"' EXIT
    jq --argjson value "$value" '.concurrency = $value' "$config" >"$tmp"
    mv "$tmp" "$config"; trap - EXIT
    echo "Shared Codex concurrency set to $value"
    ;;
  status)
    if docker compose ps --status running --services | grep -qx runner-manager; then
      docker compose exec -T runner-manager runner-manager status
    else
      docker compose run --rm --no-deps runner-manager status
    fi
    ;;
  sync)
    while IFS=$'\t' read -r sync_repo sync_state; do
      repo=$sync_repo
      case "$sync_state" in
        unregistered)
          github_admin_checks
          gh api --method POST "repos/$repo/actions/runners/registration-token" --jq .token | \
            docker compose run --rm --no-deps -T runner-manager register "$repo"
          ;;
        stale)
          github_admin_checks
          gh api --method POST "repos/$repo/actions/runners/remove-token" --jq .token | \
            docker compose run --rm --no-deps -T runner-manager remove "$repo"
          ;;
      esac
    done < <(docker compose run --rm --no-deps runner-manager status-all)
    docker compose up -d --force-recreate runner-manager
    docker compose exec -T runner-manager runner-manager status
    ;;
  *) echo "Usage: $0 {add|update|deploy|remove|status|sync|concurrency} [cre-chan/repository|limit]" ;;
esac
