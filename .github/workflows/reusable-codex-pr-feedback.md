---
on:
  workflow_call:

strict: false
check-for-updates: false

permissions:
  contents: read
  issues: read
  pull-requests: read

runs-on: [self-hosted, moth-watcher-codex]
runs-on-slim: ubuntu-latest
timeout-minutes: 45

env:
  GH_TOKEN: ${{ github.token }}

features:
  dangerously-disable-sandbox-agent: "Codex runs in the repository-owned disposable Docker sandbox instead"
sandbox:
  agent: false

engine:
  id: codex
  command: /opt/moth-watcher-runner/gh-aw-codex-adapter.sh

tools:
  bash: false

safe-outputs:
  threat-detection: false
  push-to-pull-request-branch:
    max: 1
    required-labels: [codex-pr-created]
    required-title-prefix: "[Codex] "
    protected-files: allowed
  add-comment:
    max: 1
---

# Apply authorized pull request feedback

Apply the exact `/codex fix` request selected by the event. Only a same-repository
Codex-generated draft pull request may be updated. The external adapter performs
authorization and stale-head checks before invoking the isolated worker.
