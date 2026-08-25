#!/usr/bin/env bash
set -euo pipefail

repository_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readme="$repository_root/README.md"

grep -Fq '## Safety criteria for generated changes' "$readme"
grep -Fq '### Automated acceptance checks' "$readme"
grep -Fq '### Human review checks' "$readme"
grep -Fq 'between 1 and 30 files' "$readme"
grep -Fq '1 MiB (1,048,576 bytes)' "$readme"
grep -Fq 'do not use or merge' "$readme"

echo "README safety criteria tests passed"
