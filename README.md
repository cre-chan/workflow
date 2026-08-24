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

## Workflow and runner files

The project is split between GitHub-hosted orchestration and a local self-hosted
runner. GitHub Actions validates requests and publishes results, while the local
runner executes Codex in an isolated worker container.

### GitHub Actions

- `.github/workflows/codex-agent-ready.yml` defines the complete Issue-to-Draft-PR
  workflow. Its `implement` job targets the self-hosted local runner; the other
  jobs run on GitHub-hosted runners.
- `.github/scripts/validate-and-apply-patch.sh` is called by the workflow's
  `publish` job to validate the local runner's result artifact before applying
  it and creating a Draft PR.

### Local runner

- `compose.yaml` defines the local Actions runner, its Docker daemon, persistent
  volumes, and workspace initialization service.
- `.env.example` documents the local `CODEX_AUTH_DIR` setting used by Compose.
- `github-runner/Dockerfile` builds the self-hosted GitHub Actions runner image.
- `github-runner/entrypoint.sh` registers or starts that runner.
- `run-codex-container.sh` builds and launches an isolated Codex worker for the
  workflow's `implement` job and collects its result artifact.
- `Dockerfile` and `Dockerfile.dockerignore` define the isolated Codex worker
  image and its build context.
- `container-entrypoint.sh` runs Codex inside the worker, runs the repository
  validation, and writes the files under `.codex-result/`.

## Local validation

```bash
bash -n .github/scripts/validate-and-apply-patch.sh tests/validate-patch-test.sh
bash tests/validate-patch-test.sh
```
