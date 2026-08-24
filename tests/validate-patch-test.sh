#!/usr/bin/env bash
set -euo pipefail

repository_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
validator=${1:-$repository_root/.github/scripts/validate-and-apply-patch.sh}
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

git -C "$scratch" init -q -b main
git -C "$scratch" config user.name test
git -C "$scratch" config user.email test@example.invalid
printf 'before\n' >"$scratch/example.txt"
git -C "$scratch" add example.txt
git -C "$scratch" commit -qm initial
base=$(git -C "$scratch" rev-parse HEAD)

mkdir "$scratch/result"
printf '%s\n' "$base" >"$scratch/result/base-sha.txt"
printf 'summary\n' >"$scratch/result/summary.md"
printf 'tests passed\n' >"$scratch/result/test-results.md"
printf 'after\n' >"$scratch/example.txt"
git -C "$scratch" diff --binary HEAD -- >"$scratch/result/codex.patch"
git -C "$scratch" restore example.txt

fake_bin="$scratch/bin"
mkdir "$fake_bin"
cat >"$fake_bin/gh" <<EOF
#!/usr/bin/env bash
printf '%s\n' '$base'
EOF
chmod +x "$fake_bin/gh"

(cd "$scratch" && PATH="$fake_bin:$PATH" GITHUB_REPOSITORY=owner/repo EXPECTED_BASE_SHA="$base" bash "$validator" result)
[[ $(<"$scratch/example.txt") == after ]]

git -C "$scratch" reset --hard -q HEAD
printf 'diff --git a/.github/workflows/evil.yml b/.github/workflows/evil.yml\nnew file mode 100644\nindex 0000000..8b13789\n--- /dev/null\n+++ b/.github/workflows/evil.yml\n@@ -0,0 +1 @@\n+bad\n' >"$scratch/result/codex.patch"
if (cd "$scratch" && PATH="$fake_bin:$PATH" GITHUB_REPOSITORY=owner/repo EXPECTED_BASE_SHA="$base" bash "$validator" result); then
  echo "Protected path was accepted" >&2
  exit 1
fi

echo "validate-and-apply-patch tests passed"
