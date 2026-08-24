# Codex Issue Workflow

This repository contains the GitHub-side workflow for turning an authorized,
newly opened `agent-ready` Issue into a reviewed Draft Pull Request. Codex runs
on a repository-scoped self-hosted runner; all GitHub writes happen later on a
GitHub-hosted runner through a short-lived, repository-scoped GitHub App token.

## Required repository configuration

- Install the GitHub App on this repository with Metadata read, Contents
  read/write, Issues read/write, and Pull requests read/write.
- Set Actions variable `CODEX_APP_ID` and secret `CODEX_APP_PRIVATE_KEY`.
- Register the local runner with labels `self-hosted` and
  `moth-watcher-codex`, and set `MOTH_WATCHER_RUNNER_HOME` in its service
  environment.
- Create the `agent-ready` label. Status labels are created by the workflow.
- Protect `main`, especially `.github/workflows/**` and `.github/scripts/**`.

The local runner must emit `.codex-result/codex.patch`, `base-sha.txt`,
`summary.md`, and `test-results.md`. Empty or missing files, a stale base,
dangerous paths, binary data, symlinks, oversized changes, or likely secrets are
rejected before any branch is created.

The workflow never merges a PR or marks it ready for review.

## Local validation

```bash
bash -n .github/scripts/validate-and-apply-patch.sh tests/validate-patch-test.sh
bash tests/validate-patch-test.sh
```
