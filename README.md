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

The workflow never merges a PR or marks it ready for review. One local manager
container can run a separately registered runner for every repository listed in
`repositories.json`; all of them share one Codex concurrency limit.

## Multi-repository setup

Prerequisites are `gh`, Docker Compose, `jq`, admin and direct-push access to the
target default branches, an installed existing GitHub App named
`workflow-codex`, and a dedicated authenticated Codex home. The setup does not
create an App. In the App installation browser page, select only the intended
`cre-chan` repositories before continuing.

Edit `repositories.json` through the management commands. Its default shared
concurrency is one:

```bash
export CODEX_APP_ID='<numeric app id>'
export CODEX_APP_PRIVATE_KEY_FILE='/absolute/path/to/additional-key.pem'
./manage-repositories.sh add cre-chan/example
./manage-repositories.sh deploy cre-chan/example
./manage-repositories.sh concurrency 1
```

`add` verifies authentication, admin access, and the existing App installation,
then sets the Actions variable and streams the key file to `gh secret set` over
standard input. It never copies, prints, or deletes the key. `deploy` clones the
default branch into a temporary directory, copies only the workflow payload,
validates shell files, and creates a direct commit only when content changed.
Consequently both commands are safe to rerun after a partial failure. Running
`./manage-repositories.sh sync` obtains short-lived runner tokens through `gh`,
pipes them into throwaway containers, registers missing runners, unregisters
stale ones, and recreates the manager. Repeating it does no registration work
when state already matches.

Register each newly added runner with a short-lived token, passed only through a
pipe. The manager stores one registration under the shared named volume:

```bash
gh api --method POST repos/cre-chan/example/actions/runners/registration-token \
  --jq .token | docker compose run --rm --no-deps -T runner-manager \
  register cre-chan/example
docker compose up -d runner-manager
./manage-repositories.sh status
```

Before removing an entry, stop the manager and unregister it on GitHub, then
remove it from the local configuration:

```bash
docker compose stop runner-manager
gh api --method POST repos/cre-chan/example/actions/runners/remove-token \
  --jq .token | docker compose run --rm --no-deps -T runner-manager \
  remove cre-chan/example
./manage-repositories.sh remove cre-chan/example
docker compose up -d runner-manager
```

For updates, run `update`, `deploy`, then recreate `runner-manager`. To recover
from interruption, run the same operation again and inspect `status` and
`docker compose logs runner-manager`. A repository shown as `unregistered`
needs the registration command above. Never delete volumes during recovery.

To migrate the old single-repository installation, stop `actions-runner`, add
`cre-chan/workflow`, register it once in the new manager volume, verify it is
online, and only then remove the obsolete runner registration. The workflow and
artifact formats do not change.

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

- `compose.yaml` defines the multi-repository runner manager, its Docker daemon, persistent
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
bash tests/multi-repository-test.sh
docker compose config --quiet
```
