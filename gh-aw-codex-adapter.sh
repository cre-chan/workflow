#!/usr/bin/env bash
set -euo pipefail

runner_root=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
event_file=${GITHUB_EVENT_PATH:?GITHUB_EVENT_PATH is required}
repository=${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}
safe_outputs=${GH_AW_SAFE_OUTPUTS:?GH_AW_SAFE_OUTPUTS is required}
event_name=${GITHUB_EVENT_NAME:?GITHUB_EVENT_NAME is required}
request_dir=.codex-request
request_file=$request_dir/request.json

mkdir -p "$request_dir"

permission_for() {
  gh api "repos/${repository}/collaborators/$1/permission" --jq '.permission' 2>/dev/null || true
}

require_writer() {
  local actor=$1 permission
  permission=$(permission_for "$actor")
  [[ "$permission" =~ ^(write|maintain|admin)$ ]] || {
    echo "Actor must have write, maintain, or admin permission" >&2
    exit 2
  }
}

event_text() {
  jq -r "$1 // \"\"" "$event_file" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

directive_from() {
  sed -n '1{s/^[[:space:]]*//;s/[[:space:]]*$//;p;}' <<<"$1"
}

feedback_from() {
  sed '1d' <<<"$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

operation= issue_number= pr_number= title= body= feedback= base_sha= remote_ref=
actor=$(jq -r '.sender.login' "$event_file")
require_writer "$actor"

case "$event_name" in
  issues)
    [[ $(jq -r '.action' "$event_file") == opened ]] || exit 78
    jq -e '.issue.labels | any(.name == "agent-ready")' "$event_file" >/dev/null || {
      echo "Issue must have agent-ready when opened" >&2; exit 78;
    }
    issue_number=$(jq -r '.issue.number' "$event_file")
    title=$(jq -r '.issue.title' "$event_file")
    body=$(jq -r '.issue.body // ""' "$event_file")
    require_writer "$(jq -r '.issue.user.login' "$event_file")"
    operation=implement_issue
    ;;
  issue_comment)
    text=$(event_text '.comment.body')
    command=$(directive_from "$text")
    if jq -e '.issue.pull_request != null' "$event_file" >/dev/null; then
      [[ "$command" == '/codex fix' ]] || exit 78
      pr_number=$(jq -r '.issue.number' "$event_file")
      feedback=$(feedback_from "$text")
      operation=apply_pr_feedback
    else
      [[ "$command" == '/codex implement' || "$command" == '/codex retry' ]] || exit 78
      issue_number=$(jq -r '.issue.number' "$event_file")
      title=$(jq -r '.issue.title' "$event_file")
      body=$(jq -r '.issue.body // ""' "$event_file")
      feedback=$(feedback_from "$text")
      operation=implement_issue
    fi
    ;;
  pull_request_review)
    text=$(event_text '.review.body')
    [[ $(directive_from "$text") == '/codex fix' ]] || exit 78
    pr_number=$(jq -r '.pull_request.number' "$event_file")
    feedback=$(feedback_from "$text")
    operation=apply_pr_feedback
    ;;
  pull_request_review_comment)
    text=$(event_text '.comment.body')
    [[ $(directive_from "$text") == '/codex fix' ]] || exit 78
    pr_number=$(jq -r '.pull_request.number' "$event_file")
    feedback=$(feedback_from "$text")
    operation=apply_pr_feedback
    ;;
  *) echo "Unsupported event: $event_name" >&2; exit 78 ;;
esac

default_branch=$(gh api "repos/${repository}" --jq '.default_branch')
if [[ "$operation" == implement_issue ]]; then
  base_sha=$(gh api "repos/${repository}/git/ref/heads/${default_branch}" --jq '.object.sha')
  [[ $(git rev-parse HEAD) == "$base_sha" ]] || {
    echo "Checkout does not match the authorized default branch" >&2; exit 1;
  }
  remote_ref="heads/${default_branch}"
else
  pr_json=$(gh api "repos/${repository}/pulls/${pr_number}")
  [[ $(jq -r '.head.repo.full_name' <<<"$pr_json") == "$repository" ]] || {
    echo "Fork pull requests are not supported" >&2; exit 2;
  }
  [[ $(jq -r '.draft' <<<"$pr_json") == true ]] || {
    echo "Only draft pull requests may be changed" >&2; exit 2;
  }
  jq -e '.labels | any(.name == "codex-pr-created")' <<<"$pr_json" >/dev/null || {
    echo "Pull request is not managed by Codex automation" >&2; exit 2;
  }
  head_ref=$(jq -r '.head.ref' <<<"$pr_json")
  [[ "$head_ref" == codex/issue-* ]] || { echo "Unexpected PR branch" >&2; exit 2; }
  base_sha=$(jq -r '.head.sha' <<<"$pr_json")
  [[ $(git rev-parse HEAD) == "$base_sha" ]] || {
    echo "gh-aw checkout does not match the authorized PR head" >&2; exit 1;
  }
  remote_ref="heads/${head_ref}"
  title=$(jq -r '.title' <<<"$pr_json")
  body=$(jq -r '.body // ""' <<<"$pr_json")
  issue_number=$(sed -n 's#^codex/issue-\([0-9][0-9]*\).*#\1#p' <<<"$head_ref")
fi

jq -n \
  --arg operation "$operation" \
  --argjson issue_number "${issue_number:-0}" \
  --argjson pull_request_number "${pr_number:-0}" \
  --arg title "$title" --arg body "$body" --arg feedback "$feedback" \
  --arg base_sha "$base_sha" \
  '{schema_version: 2, operation: $operation, issue_number: $issue_number,
    pull_request_number: $pull_request_number, title: $title, body: $body,
    feedback: $feedback, base_sha: $base_sha}' >"$request_file"

"$runner_root/run-codex-container.sh" "$request_file"

EXPECTED_BASE_SHA=$base_sha EXPECTED_REMOTE_REF=$remote_ref \
  "$runner_root/validate-and-apply-patch.sh" .codex-result

git config user.name github-actions[bot]
git config user.email 41898282+github-actions[bot]@users.noreply.github.com
git commit -m "Apply Codex automation"

if [[ "$operation" == implement_issue ]]; then
  summary=$(cat .codex-result/summary.md)
  tests=$(cat .codex-result/test-results.md)
  jq -cn --arg title "$title" --arg branch "codex/issue-${issue_number}" \
    --arg body "Codex generated this change for #${issue_number}.\n\n${summary}\n\n## Verification\n\n${tests}\n\nCloses #${issue_number}" \
    '{type:"create_pull_request", title:$title, body:$body, branch:$branch}' >>"$safe_outputs"
else
  printf '%s\n' '{"type":"push_to_pull_request_branch"}' >>"$safe_outputs"
fi
