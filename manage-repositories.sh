#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
config=${REPOSITORIES_CONFIG:-$root/repositories.json}
template=$root/templates/codex-automation.yml
action=${1:-help}
repo=${2:-}
gh_aw_version=v0.86.2

usage() {
  cat <<'EOF'
Usage:
  ./manage-repositories.sh bootstrap-admin
  ./manage-repositories.sh install [cre-chan/]REPOSITORY [true|false] [true|false]
  ./manage-repositories.sh update [cre-chan/]REPOSITORY [true|false] [true|false]
  ./manage-repositories.sh upgrade [cre-chan/]REPOSITORY
  ./manage-repositories.sh upgrade-all
  ./manage-repositories.sh disable [cre-chan/]REPOSITORY
  ./manage-repositories.sh remove [cre-chan/]REPOSITORY
  ./manage-repositories.sh status
  ./manage-repositories.sh concurrency LIMIT
  ./manage-repositories.sh compile [--check]

Repository names without an owner are normalized to cre-chan/REPOSITORY.
install/update booleans enable Issue implementation and PR feedback respectively.
EOF
}

normalize_repo() {
  if [[ "$repo" =~ ^[A-Za-z0-9_.-]+$ ]]; then
    repo="cre-chan/$repo"
  fi
  [[ "$repo" =~ ^cre-chan/[A-Za-z0-9_.-]+$ ]] || {
    echo "Repository must use REPOSITORY or cre-chan/REPOSITORY form" >&2; exit 2;
  }
}

set_dotenv_path() {
  local key=$1 value=$2
  case "$value" in
    \"*\") [[ "$value" == *\" ]] && value=${value:1:${#value}-2} ;;
    \'*\') [[ "$value" == *\' ]] && value=${value:1:${#value}-2} ;;
  esac
  [[ "$value" == /* ]] || {
    echo "$key in .env must be an absolute path" >&2; exit 2;
  }
  case "$key" in
    CODEX_AUTH_DIR)
      [[ -n ${CODEX_AUTH_DIR+x} ]] || CODEX_AUTH_DIR=$value
      export CODEX_AUTH_DIR
      ;;
    ADMIN_GITHUB_TOKEN_FILE)
      [[ -n ${ADMIN_GITHUB_TOKEN_FILE+x} ]] || ADMIN_GITHUB_TOKEN_FILE=$value
      export ADMIN_GITHUB_TOKEN_FILE
      ;;
  esac
}

load_local_env() {
  local env_file=$root/.env line key value
  [[ ${MOTH_ADMIN_CONTEXT:-0} != 1 && -f "$env_file" && ! -L "$env_file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line=${line%$'\r'}
    case "$line" in
      CODEX_AUTH_DIR=*|ADMIN_GITHUB_TOKEN_FILE=*)
        key=${line%%=*}
        value=${line#*=}
        set_dotenv_path "$key" "$value"
        ;;
    esac
  done <"$env_file"
}

load_admin_token() {
  local token_file=${ADMIN_GITHUB_TOKEN_FILE:-/run/secrets/github_admin_token}
  [[ -f "$token_file" && ! -L "$token_file" && -r "$token_file" ]] || {
    echo "ADMIN_GITHUB_TOKEN_FILE must name a readable non-symlink token file" >&2; exit 2;
  }
  if command -v stat >/dev/null 2>&1; then
    mode=$(stat -f '%Lp' "$token_file" 2>/dev/null || stat -c '%a' "$token_file")
    [[ "$mode" == 600 || "$mode" == 400 ]] || { echo "Admin token file must have mode 0600 or 0400" >&2; exit 2; }
  fi
  GH_TOKEN=$(<"$token_file")
  export GH_TOKEN
  gh auth setup-git >/dev/null
}

github_checks() {
  load_admin_token
  gh api "repos/$repo" --jq '.permissions.admin' | grep -qx true || {
    echo "$repo: admin permission is required" >&2; exit 1;
  }
}

write_config() {
  local jq_filter=$1; shift
  local tmp temp_root=${TMPDIR:-/tmp}
  [[ -d "$temp_root" && -w "$temp_root" ]] || {
    echo "Temporary directory is not writable: $temp_root" >&2; exit 2;
  }
  tmp=$(mktemp "${temp_root%/}/moth-watcher-config.XXXXXX")
  trap 'rm -f -- "$tmp"' EXIT
  jq "$@" "$jq_filter" "$config" >"$tmp"
  cp "$tmp" "$config"
  rm -f -- "$tmp"
  trap - EXIT
}

normalize_config() {
  write_config '
    .workflow_ref = (.workflow_ref // "") |
    .repositories |= map(
      if type == "string" then
        {name: ., enabled: true, issue_implementation: true, pr_feedback: true, installed_ref: ""}
      else . end)'
}

workflow_ref() {
  local ref=${WORKFLOW_REF:-}
  if [[ -z "$ref" && "$action" == upgrade ]]; then
    load_admin_token
    central_default=$(gh api repos/cre-chan/workflow --jq .default_branch)
    ref=$(gh api "repos/cre-chan/workflow/commits/$central_default" --jq .sha)
  fi
  [[ -n "$ref" ]] || ref=$(jq -r '.workflow_ref // ""' "$config")
  if [[ -z "$ref" ]]; then
    ref=$(git -C "$root" rev-parse HEAD)
    git -C "$root" cat-file -e "$ref:.github/workflows/reusable-codex-issue.lock.yml" 2>/dev/null &&
      git -C "$root" cat-file -e "$ref:.github/workflows/reusable-codex-pr-feedback.lock.yml" 2>/dev/null || {
      echo "Compile and commit the central workflows before installing a target" >&2; exit 2;
    }
  fi
  [[ "$ref" =~ ^[0-9a-f]{40}$ ]] || { echo "Workflow ref must be a full commit SHA" >&2; exit 2; }
  printf '%s' "$ref"
}

configure_repository() {
  github_checks
  gh api --method PUT "repos/$repo/actions/permissions/workflow" \
    -f default_workflow_permissions=read -F can_approve_pull_request_reviews=false >/dev/null
  gh label create agent-ready --repo "$repo" --color 0e8a16 --force >/dev/null
  gh label create codex-processing --repo "$repo" --color fbca04 --force >/dev/null
  gh label create codex-pr-created --repo "$repo" --color 0e8a16 --force >/dev/null
}

repo_setting() {
  local field=$1 default=$2
  jq -r --arg repo "$repo" --arg field "$field" --arg default "$default" '
    first(.repositories[] | select(.name == $repo) | .[$field]) //
      (try ($default | fromjson) catch $default)
  ' "$config"
}

render_caller() {
  local destination=$1 ref issue_enabled pr_enabled
  ref=$(workflow_ref)
  issue_enabled=$(repo_setting issue_implementation true)
  pr_enabled=$(repo_setting pr_feedback true)
  sed -e "s/__WORKFLOW_REF__/$ref/g" \
      -e "s/__ISSUE_ENABLED__/$issue_enabled/g" \
      -e "s/__PR_FEEDBACK_ENABLED__/$pr_enabled/g" \
      "$template" >"$destination"
}

commit_caller() {
  local mode=$1 checkout default_branch target changed=0
  github_checks
  checkout=$(mktemp -d)
  trap 'rm -rf -- "$checkout"' RETURN
  default_branch=$(gh api "repos/$repo" --jq '.default_branch')
  gh repo clone "$repo" "$checkout" -- --depth=1 --branch "$default_branch" >/dev/null
  target=$checkout/.github/workflows/codex-automation.yml
  mkdir -p "$(dirname "$target")"
  if [[ "$mode" == remove ]]; then
    [[ -f "$target" ]] || { echo "$repo: caller already absent"; return; }
    rm -f "$target"
    changed=1
  else
    candidate=$(mktemp)
    render_caller "$candidate"
    if [[ ! -f "$target" ]] || ! cmp -s "$candidate" "$target"; then
      cp "$candidate" "$target"
      changed=1
    fi
    rm -f "$candidate"
  fi
  [[ $changed -eq 1 ]] || { echo "$repo: caller already current"; return; }
  (cd "$checkout" && git add --all -- .github/workflows/codex-automation.yml && \
    git config user.name 'workflow-codex setup' && \
    git config user.email 'workflow-codex-setup@users.noreply.github.com' && \
    git commit -m "$([[ "$mode" == remove ]] && echo 'Remove Codex automation' || echo 'Configure Codex automation')" >/dev/null && \
    git push origin "HEAD:$default_branch" >/dev/null)
  echo "$repo: caller committed to $default_branch"
}

manager_command() {
  if [[ ${MOTH_ADMIN_CONTEXT:-0} == 1 ]]; then
    RUNNER_CONFIG=$config /usr/local/bin/runner-manager "$@"
  else
    docker compose run --rm --no-deps -T runner-manager "$@"
  fi
}

register_repo() {
  local state
  state=$(manager_command status-all | awk -F '\t' -v repo="$repo" '$1 == repo {print $2; exit}')
  [[ "$state" != unregistered && -n "$state" ]] || {
    gh api --method POST "repos/$repo/actions/runners/registration-token" --jq .token | manager_command register "$repo"
  }
  wait_runner_online
}

runner_name() { printf 'workflow-codex-%s' "$(printf '%s' "$repo" | tr '/.' '--_')"; }

github_runner_state() {
  gh api "repos/$repo/actions/runners?per_page=100" \
    --jq ".runners[] | select(.name == \"$(runner_name)\") | (.status + if .busy then \":busy\" else \"\" end)" |
    head -n 1
}

wait_runner_online() {
  local attempt state
  for attempt in {1..30}; do
    state=$(github_runner_state)
    [[ "$state" == online* ]] && { echo "$repo: runner online"; return; }
    sleep 2
  done
  echo "$repo: runner did not become online within 60 seconds" >&2
  exit 1
}

unregister_repo() {
  local state
  state=$(manager_command status-all | awk -F '\t' -v repo="$repo" '$1 == repo {print $2; exit}')
  [[ "$state" == unregistered || -z "$state" ]] || {
    gh api --method POST "repos/$repo/actions/runners/remove-token" --jq .token | manager_command remove "$repo"
  }
}

set_repo_entry() {
  local enabled=$1 issue_enabled=$2 pr_enabled=$3 ref
  ref=$(workflow_ref)
  write_config '
    .workflow_ref = $ref |
    .repositories = ([.repositories[] | select(.name != $repo)] + [{
      name: $repo, enabled: $enabled,
      issue_implementation: $issue, pr_feedback: $pr,
      installed_ref: $ref
    }]) | .repositories |= sort_by(.name)
  ' --arg repo "$repo" --arg ref "$ref" --argjson enabled "$enabled" --argjson issue "$issue_enabled" --argjson pr "$pr_enabled"
}

compile_workflows() {
  local check=${1:-} bin=${GH_AW_BIN:-}
  [[ -n "$bin" ]] || bin=$(command -v gh-aw 2>/dev/null || true)
  [[ -x "$bin" ]] || { echo "Set GH_AW_BIN to the gh-aw $gh_aw_version executable" >&2; exit 2; }
  platform=$(printf '%s-%s' "$(uname -s | tr '[:upper:]' '[:lower:]')" "$(uname -m | sed -e 's/x86_64/amd64/' -e 's/aarch64/arm64/')")
  expected=$(awk -v file="$platform" '$2 == file {print $1}' "$root/scripts/gh-aw-v0.86.2-checksums.txt")
  [[ -n "$expected" ]] || { echo "Unsupported gh-aw platform: $platform" >&2; exit 2; }
  actual=$(shasum -a 256 "$bin" | awk '{print $1}')
  [[ "$actual" == "$expected" ]] || { echo "gh-aw checksum mismatch for $platform" >&2; exit 2; }
  version=$($bin --version 2>&1 || $bin version 2>&1)
  grep -q "$gh_aw_version" <<<"$version" || { echo "gh-aw $gh_aw_version is required" >&2; exit 2; }
  if [[ "$check" == --check ]]; then
    before=$(shasum .github/workflows/reusable-codex-*.lock.yml)
    $bin compile reusable-codex-issue reusable-codex-pr-feedback --no-check-update --action-tag "$gh_aw_version" --approve >/dev/null
    normalize_compiled_workflows
    after=$(shasum .github/workflows/reusable-codex-*.lock.yml)
    [[ "$before" == "$after" ]] || { echo "Compiled workflows are stale" >&2; exit 1; }
  else
    $bin compile reusable-codex-issue reusable-codex-pr-feedback --no-check-update --action-tag "$gh_aw_version" --approve
    normalize_compiled_workflows
  fi
}

normalize_compiled_workflows() {
  local lock tmp
  for lock in .github/workflows/reusable-codex-*.lock.yml; do
    tmp=$(mktemp "${lock}.tmp.XXXXXX")
    sed \
      -e 's#/tmp/gh-aw#${{ runner.temp }}/gh-aw-global#g' \
      -e 's#--name awmg-mcpg#--name awmg-mcpg-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}#g' \
      -e 's#export MCP_GATEWAY_PORT="8080"#export MCP_GATEWAY_PORT="$((20000 + GITHUB_RUN_ID % 20000))"#g' \
      "$lock" >"$tmp"
    cp "$tmp" "$lock"
    rm -f -- "$tmp"
  done
}

status_report() {
  local configured name enabled installed expected remote_sha permissions runner_state online_state
  configured=$(manager_command status-all)
  printf 'repository\tenabled\tcaller\tactions\tlocal-runner\tgithub-runner\n'
  while IFS= read -r name; do
    repo=$name
    enabled=$(repo_setting enabled true)
    installed=$(repo_setting installed_ref '')
    expected=$(workflow_ref)
    remote_sha=$(gh api "repos/$repo/contents/.github/workflows/codex-automation.yml" \
      -H 'Accept: application/vnd.github.raw+json' 2>/dev/null |
      sed -n 's/.*reusable-codex-issue\.lock\.yml@\([0-9a-f]\{40\}\).*/\1/p' | head -n 1 || true)
    if [[ -z "$remote_sha" ]]; then caller=missing
    elif [[ "$remote_sha" == "$expected" && "$installed" == "$expected" ]]; then caller=current
    else caller="stale:$remote_sha"
    fi
    permissions=$(gh api "repos/$repo/actions/permissions/workflow" --jq '.default_workflow_permissions' 2>/dev/null || echo unknown)
    runner_state=$(awk -F '\t' -v target="$repo" '$1 == target {print $2; exit}' <<<"$configured")
    online_state=$(github_runner_state)
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$repo" "$enabled" "$caller" "$permissions" \
      "${runner_state:-unregistered}" "${online_state:-missing}"
  done < <(jq -r '.repositories[].name' "$config")
}

if [[ "$action" =~ ^(help|-h|--help)$ ]]; then usage; exit 0; fi
load_local_env
case "$action" in
  install|update|upgrade|disable|remove) normalize_repo ;;
esac
normalize_config
case "$action" in
  bootstrap-admin)
    load_admin_token
    gh api --method POST repos/cre-chan/workflow/actions/runners/registration-token --jq .token |
      docker compose run --rm --no-deps -T repository-admin register
    ;;
  install)
    issue_enabled=${3:-true}; pr_enabled=${4:-true}
    [[ "$issue_enabled" =~ ^(true|false)$ && "$pr_enabled" =~ ^(true|false)$ ]] || { echo "Feature flags must be true or false" >&2; exit 2; }
    configure_repository
    set_repo_entry true "$issue_enabled" "$pr_enabled"
    commit_caller install
    register_repo
    ;;
  update)
    configure_repository
    issue_enabled=${3:-$(repo_setting issue_implementation true)}
    pr_enabled=${4:-$(repo_setting pr_feedback true)}
    [[ "$issue_enabled" =~ ^(true|false)$ && "$pr_enabled" =~ ^(true|false)$ ]] || { echo "Feature flags must be true or false" >&2; exit 2; }
    set_repo_entry true "$issue_enabled" "$pr_enabled"
    commit_caller install; register_repo
    ;;
  upgrade)
    configure_repository
    issue_enabled=$(repo_setting issue_implementation true)
    pr_enabled=$(repo_setting pr_feedback true)
    set_repo_entry true "$issue_enabled" "$pr_enabled"
    commit_caller install; register_repo
    ;;
  upgrade-all)
    while IFS= read -r repo; do "$0" upgrade "$repo"; done < <(jq -r '.repositories[].name' "$config")
    ;;
  disable)
    write_config '.repositories |= map(if .name == $repo then .enabled = false else . end)' --arg repo "$repo"
    echo "$repo: disabled; runner-manager will stop it"
    ;;
  remove)
    github_checks; unregister_repo; commit_caller remove
    write_config '.repositories |= map(select(.name != $repo))' --arg repo "$repo"
    echo "$repo: removed"
    ;;
  status)
    load_admin_token
    status_report
    ;;
  concurrency)
    value=${2:-}; [[ "$value" =~ ^[1-9][0-9]*$ ]] || { echo "Concurrency must be a positive integer" >&2; exit 2; }
    write_config '.concurrency = $value' --argjson value "$value"
    echo "Shared Codex concurrency set to $value"
    ;;
  compile) compile_workflows "${2:-}" ;;
  *) usage >&2; exit 2 ;;
esac
