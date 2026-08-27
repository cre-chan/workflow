# Codex Issue Workflow

`cre-chan/workflow` centrally compiles reusable [gh-aw](https://github.com/github/gh-aw)
workflows for Issue implementation and pull-request feedback. Monitored repositories
receive only `.github/workflows/codex-automation.yml`, pinned to an immutable commit
of this repository; they do not install or compile gh-aw.

Codex keeps using a dedicated `auth.json` inside an isolated Docker worker. The
worker never receives GitHub credentials and returns only a validated patch. gh-aw
Safe Outputs performs repository writes with that repository's short-lived
`GITHUB_TOKEN`. No custom GitHub App is required.

## Quick start

Prerequisites: Docker with Compose, `gh`, Codex CLI, `jq`, and a dedicated
fine-grained PAT. The complete procedure and security notes are in
[`docs/SETUP.md`](docs/SETUP.md).

```bash
# 1. Authenticate a dedicated Codex home and protect both credential files.
mkdir -p "$HOME/.codex-moth-watcher-runner"
CODEX_HOME="$HOME/.codex-moth-watcher-runner" codex login --device-auth
chmod 600 "$HOME/.codex-moth-watcher-runner/auth.json" /absolute/path/to/admin-token

# 2. Configure local-only absolute paths.
cp .env.example .env
# Edit CODEX_AUTH_DIR and ADMIN_GITHUB_TOKEN_FILE in .env.
# The management CLI reads these two path variables without evaluating .env as shell code.

# 3. Initialize volumes and register the dedicated administration runner.
docker compose run --rm workspace-init
./manage-repositories.sh bootstrap-admin

# 4. Start the administration runner, repository runners, and isolated daemon.
docker compose up -d repository-admin runner-manager

# 5. Install the one-file caller Workflow in the repository to be monitored,
#    then verify the complete state.
./manage-repositories.sh install cre-chan/REPOSITORY true true
./manage-repositories.sh status
```

After the administration runner is online, **Actions → Manage monitored
repository → Run workflow** in `cre-chan/workflow` can perform the same `install`
operation: configure the target repository's Actions permissions and labels,
commit `.github/workflows/codex-automation.yml` to its default branch, add it to
the monitored-repository configuration, and register its self-hosted runner. The
repository input accepts either `REPOSITORY` or `cre-chan/REPOSITORY`.

## Project structure

- `.github/workflows/reusable-codex-*.md` are the gh-aw source workflows;
  matching `.lock.yml` files are the compiled reusable workflows.
- `.github/workflows/manage-monitored-repository.yml` is the one-click management
  UI; `templates/codex-automation.yml` is the only file installed in targets.
- `manage-repositories.sh` manages target configuration, direct commits, Actions
  settings, labels, and runner registration.
- `github-runner/manager.sh` runs one Actions runner process per enabled target;
  `shared-concurrency.sh` enforces one configurable Codex limit across all targets.
- `gh-aw-codex-adapter.sh` bridges gh-aw to `run-codex-container.sh` and admits
  only validated patch output.
- `compose.yaml` separates the administration runner, repository runners, nested
  Docker daemon, credentials, state, and shared lock volume.

## Local validation

```bash
bash tests/validate-patch-test.sh
bash tests/multi-repository-test.sh
bash tests/documentation-test.sh
GH_AW_BIN=/absolute/path/to/gh-aw-v0.86.2 ./manage-repositories.sh compile --check
docker compose config --quiet
```

The workflow creates Draft PRs only. It never merges or marks a PR ready for
review. A PR created with `GITHUB_TOKEN` does not automatically trigger ordinary
`pull_request` workflows, so the Codex worker must run the repository's supported
tests and records their result in the PR body.
