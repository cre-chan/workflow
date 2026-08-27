#!/usr/bin/env bash
set -euo pipefail

result_dir=${1:?result directory is required}
expected_base=${EXPECTED_BASE_SHA:?EXPECTED_BASE_SHA is required}
max_bytes=${MAX_PATCH_BYTES:-1048576}
max_files=${MAX_CHANGED_FILES:-30}
patch_file="$result_dir/codex.patch"

for required in "$patch_file" "$result_dir/base-sha.txt" "$result_dir/summary.md" "$result_dir/test-results.md"; do
  [[ -s "$required" ]] || { echo "Missing or empty result file: $required" >&2; exit 1; }
done

if find "$result_dir" -type l -print -quit | grep -q .; then
  echo "Result artifact contains a symbolic link" >&2
  exit 1
fi

artifact_base=$(tr -d '\r\n' <"$result_dir/base-sha.txt")
[[ "$artifact_base" == "$expected_base" ]] || { echo "Artifact base SHA does not match authorized base SHA" >&2; exit 1; }
[[ $(wc -c <"$patch_file") -le $max_bytes ]] || { echo "Patch exceeds ${max_bytes} bytes" >&2; exit 1; }
[[ $(git rev-parse HEAD) == "$expected_base" ]] || { echo "Checkout does not match authorized base SHA" >&2; exit 1; }

default_branch=$(gh api "repos/${GITHUB_REPOSITORY}" --jq '.default_branch')
remote_ref=${EXPECTED_REMOTE_REF:-heads/${default_branch}}
current_base=$(gh api "repos/${GITHUB_REPOSITORY}/git/ref/${remote_ref}" --jq '.object.sha')
[[ "$current_base" == "$expected_base" ]] || {
  echo "Remote ref moved from ${expected_base} to ${current_base}; refusing stale patch" >&2
  exit 1
}

changed_files=()
while IFS= read -r path; do
  changed_files+=("$path")
done < <(git apply --numstat "$patch_file" | cut -f3-)
[[ ${#changed_files[@]} -gt 0 ]] || { echo "Patch has no files" >&2; exit 1; }
[[ ${#changed_files[@]} -le $max_files ]] || { echo "Patch changes too many files" >&2; exit 1; }

for path in "${changed_files[@]}"; do
  if [[ ! "$path" =~ ^[A-Za-z0-9._/@+-]+$ || "$path" == /* || "$path" == ../* || "$path" == */../* ]]; then
    echo "Unsafe path in patch: $path" >&2
    exit 1
  fi
  case "$path" in
    .github/*|.codex/*|AGENTS.md|*runner*|*/auth.json|auth.json)
      echo "Protected path changed: $path" >&2
      exit 1
      ;;
  esac
done

if git apply --numstat "$patch_file" | grep -q $'^-	-	'; then
  echo "Binary changes are not allowed" >&2
  exit 1
fi

if grep '^+' "$patch_file" | grep -Eiq '(BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY|gh[pousr]_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9_-]{20,})'; then
  echo "Possible secret detected in patch" >&2
  exit 1
fi

git apply --check "$patch_file"
git apply --index "$patch_file"

if git diff --cached --summary | grep -q 'mode 120000'; then
  echo "Symbolic links are not allowed" >&2
  exit 1
fi
