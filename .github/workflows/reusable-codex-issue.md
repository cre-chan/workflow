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
  create-pull-request:
    title-prefix: "[Codex] "
    labels: [codex-pr-created]
    draft: true
    allowed-branches: ["codex/issue-*"]
    max: 1
    fallback-as-issue: false
    max-patch-files: 30
    max-patch-size: 1024
    protected-files: allowed
  add-comment:
    max: 1
  add-labels:
    max: 2
---

# Implement an authorized Issue

Implement the Issue selected by the event. The external adapter performs the
authorization check and supplies the untrusted Issue text to the isolated Codex
worker. Do not request a merge or mark the generated pull request ready.
