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

## Safety criteria for generated changes

Treat generated changes as safe to review only when all of the following checks
pass. Passing these checks does not prove that a change is correct or secure;
the generated Draft PR must still be reviewed by a human before use.

### Automated acceptance checks

- The result contains non-empty `codex.patch`, `base-sha.txt`, `summary.md`, and
  `test-results.md` files, with no symbolic links in the result artifact.
- The recorded base commit matches both the authorized commit and the current
  default branch, so the patch is not stale.
- The patch applies cleanly, changes between 1 and 30 files, and is no larger
  than 1 MiB (1,048,576 bytes).
- Every changed path is repository-relative and uses only the permitted path
  characters. Traversal paths and changes to `.github/**`, `.codex/**`,
  `AGENTS.md`, runner-related paths, or `auth.json` are rejected.
- The patch contains no binary changes, symbolic links, or text matching the
  validator's private-key and common token patterns.
- The repository-provided validation command completes successfully and its
  result is recorded in `test-results.md`.

### Human review checks

Before marking the Draft PR ready, a reviewer must confirm that:

- the change implements only the authorized Issue and every changed line is
  understood;
- the reported tests cover the changed behavior and their results are credible;
- no credential, personal data, confidential data, or unsafe logging is present,
  including secrets not recognized by the automated patterns;
- security boundaries and least-privilege assumptions remain intact, with no
  unexpected network access, dependency, destructive operation, or unrelated
  side effect; and
- the change has an acceptable failure mode and can be reverted if necessary.

If any check fails or cannot be verified, do not use or merge the generated
change. Revise it or request additional review instead.

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
bash -n .github/scripts/validate-and-apply-patch.sh tests/validate-patch-test.sh \
  tests/readme-safety-criteria-test.sh
bash tests/validate-patch-test.sh
bash tests/readme-safety-criteria-test.sh
```
