# Setup and operations

This is the source of truth for installing and operating the centrally managed
Codex automation. Run commands from a clone of `cre-chan/workflow` on the machine
that hosts the self-hosted runners.

## 1. Verify prerequisites

The host needs Docker with Compose, GitHub CLI (`gh`), Codex CLI, Git, and `jq`.
gh-aw v0.86.2 is required only when compiling the two central workflows; monitored
repositories never install it.

```bash
docker version
docker compose version
gh --version
codex --version
jq --version
/absolute/path/to/gh-aw --version # central workflow maintenance only
```

Central workflow compilation is pinned to v0.86.2. Set `GH_AW_BIN` to the release
executable. The compile command verifies it against the checked-in official
platform checksum before running, and `compile --check` proves recompilation
produces no diff.

The central compile step also normalizes gh-aw's fixed `/tmp/gh-aw` to a
job-specific sibling under `${RUNNER_TEMP}`, and makes the gateway container name
and port job-specific. This is required because several repository runner
processes share one container; do not compile in a target or bypass
`manage-repositories.sh compile`.

## 2. Prepare dedicated Codex authentication

Do not reuse the normal interactive Codex home.

```bash
mkdir -p "$HOME/.codex-moth-watcher-runner"
chmod 700 "$HOME/.codex-moth-watcher-runner"
CODEX_HOME="$HOME/.codex-moth-watcher-runner" codex login --device-auth
chmod 600 "$HOME/.codex-moth-watcher-runner/auth.json"
```

Complete device authorization in the browser. `auth.json` is mounted read-only by
the nested Docker daemon and then by each disposable worker. Never commit, copy,
print, upload, or add it to GitHub Secrets.

## 3. Prepare the administration PAT

Create a fine-grained PAT owned by `cre-chan` and limit repository access to
`cre-chan/workflow` plus intended targets. Grant only Metadata read, Contents
write, Workflows write, Issues write, Actions write, and Administration write.

The token is used for direct default-branch commits, labels, Actions settings,
and self-hosted runner registration. It is not a Codex credential and is not
stored in GitHub Secrets.

```bash
install -m 600 /dev/null "$HOME/.config/moth-watcher-admin-token"
# Paste the token into that file without echoing it in shell history.
chmod 600 "$HOME/.config/moth-watcher-admin-token"
```

## 4. Configure local paths

```bash
cp .env.example .env
```

Set both entries to absolute host paths:

```dotenv
CODEX_AUTH_DIR=/absolute/path/to/.codex-moth-watcher-runner
ADMIN_GITHUB_TOKEN_FILE=/absolute/path/to/moth-watcher-admin-token
```

`.env` contains paths, not secret values. Do not put tokens in it.
The host management CLI reads only `CODEX_AUTH_DIR` and
`ADMIN_GITHUB_TOKEN_FILE` as literal absolute paths; it does not evaluate `.env`
as shell code. Existing environment variables take precedence.

## 5. Initialize persistent workspace volumes

```bash
docker compose run --rm workspace-init
```

This prepares the repository work, target-runner state, shared lock, and
admin-runner state volumes as UID/GID 1000, including the administration
runner's `_work` directory. It is safe to repeat and does not remove
registrations.

## 6. Register the administration runner

```bash
./manage-repositories.sh bootstrap-admin
```

This requests a short-lived registration token and pipes it directly into a
throwaway `repository-admin` container. It registers only against
`cre-chan/workflow` with label `moth-watcher-admin`. Repeating it does not create
a second local registration.

## 7. Start the stack

```bash
docker compose up -d repository-admin runner-manager
```

`repository-admin` has the PAT mount but no Codex authentication or Docker daemon.
`runner-manager` has Codex and nested-Docker access but no PAT. It starts one
runner process per enabled repository. All processes share `codex-locks` and the
configured concurrency limit, which defaults to 1.

gh-aw's MCP gateway needs a Docker socket on self-hosted runners. Compose exposes
only the isolated nested daemon's `dind-sock` volume and supplies the documented
split-daemon path/GID overrides. This is not the host Docker socket, and it is
never mounted into the Codex worker.

## 8. Verify startup

```bash
docker compose ps
docker compose logs --tail=100 repository-admin runner-manager docker-daemon
./manage-repositories.sh status
```

On GitHub, verify `moth-watcher-repository-admin` is online for
`cre-chan/workflow`. Each target runner is named
`workflow-codex-cre-chan-REPOSITORY` and has label `moth-watcher-codex`.

## 9. One-click installation from GitHub

Open `cre-chan/workflow`, select **Actions**, select **Manage monitored
repository**, choose **Run workflow**, enter a repository such as
`cre-chan/example`, choose `install`, set the two feature switches, and press
**Run workflow**.

The job runs only for actor `cre-chan` on the default branch and only on
`[self-hosted, moth-watcher-admin]`. If the admin runner is offline, the job stays
queued and performs no partial change.

## 10. Manage repositories from the host

```bash
./manage-repositories.sh install cre-chan/example true true
./manage-repositories.sh update cre-chan/example
./manage-repositories.sh upgrade cre-chan/example
./manage-repositories.sh upgrade-all
./manage-repositories.sh disable cre-chan/example
./manage-repositories.sh remove cre-chan/example
./manage-repositories.sh concurrency 1
./manage-repositories.sh status
```

Target commands accept either `example` or `cre-chan/example`; an omitted owner
is normalized to `cre-chan`. Other owners and malformed names are rejected before
the configuration or GitHub state is changed.

- `install` keeps the default Actions token permission read-only, creates labels, commits the caller, records the
  target, registers its runner, and is safe to repeat.
- `update` repairs the same state and optionally accepts the two feature booleans.
- `upgrade` updates only the central commit SHA in the caller; `upgrade-all` does
  so for every configured target.
- `disable` leaves the caller and registration recoverable but stops the local
  runner process after the manager's next reconciliation.
- `remove` unregisters the runner, removes local configuration, and directly
  commits caller deletion. Git history remains the recovery path.
- `status` compares enabled state, installed caller SHA, Actions permissions, and
  local runner state.

`repositories.json` records `concurrency`, the central `workflow_ref`, and object
entries with `name`, `enabled`, feature switches, and `installed_ref`. A legacy
string array is accepted and rewritten to the object form on the next management
operation.

## 11. What is installed in a target

Only `.github/workflows/codex-automation.yml` is committed. It listens for Issue,
Issue-comment, PR-review, and PR-review-comment events and conditionally calls:

```yaml
uses: cre-chan/workflow/.github/workflows/reusable-codex-issue.lock.yml@FULL_40_CHARACTER_SHA
```

or the corresponding PR-feedback workflow. The full SHA is immutable. gh-aw CLI,
Markdown source, lock generation, Codex authentication, and Docker configuration
remain central. For manual disaster recovery, restore this single path using the
same full-SHA form; use `install` in normal operation.

## 12. Use the automation

Create an Issue with `agent-ready` already attached to implement it immediately.
For an existing Issue, an authorized writer may start a comment with
`/codex implement` or `/codex retry`. On a same-repository Codex-generated Draft
PR, start a PR conversation comment, review, or review comment with `/codex fix`.
Put any additional implementation or correction instructions on following lines.

The adapter rechecks write permission, event shape, labels, Draft state, branch,
fork status, and exact command. Codex runs in the disposable worker using the
read-only dedicated `auth.json`. Only a patch passing protected-path, secret,
binary, symlink, size, and stale-SHA checks reaches gh-aw Safe Outputs. Safe
Outputs alone writes with the target's `GITHUB_TOKEN`.

## 13. Stop, restart, and recover

```bash
docker compose stop
docker compose up -d repository-admin runner-manager
docker compose logs --tail=100 repository-admin runner-manager
./manage-repositories.sh status
```

If Codex authentication expires, stop new work, repeat `codex login` with the
dedicated `CODEX_HOME`, restore mode `0600`, and restart the stack. If a runner
registration is missing, rerun `install` or `update`; for the admin runner rerun
`bootstrap-admin`. If an operation stopped partway through, correct credential or
network availability and rerun the same command. Its stages inspect existing
state before changing it, avoiding duplicate commits, labels, and registrations.

For work-volume ownership failures, rerun `docker compose run --rm workspace-init`
and recreate `runner-manager`. Do not broaden host filesystem permissions.

## 14. CI trigger limitation

A PR created with a repository `GITHUB_TOKEN` does not automatically start normal
workflows triggered by `pull_request`. No PAT is added to bypass that protection.
The disposable Codex worker must run the repository's supported test command and
Safe Outputs records its result in the Draft PR body. Human review remains
required.

## 15. Data that must survive maintenance

Never delete the PAT file or dedicated `auth.json` while runners are operating.
Never run `docker compose down --volumes` during normal maintenance. Preserve
`runner-state`, `runner-work`, `codex-locks`, `admin-runner-state`, and
`docker-data`, and `dind-sock`.

The host Docker socket and normal Codex home must never be mounted. The PAT must
never be added to the target runner, worker environment, workspace, artifact, or
logs.

## Validate a release

```bash
bash -n ./*.sh github-runner/*.sh .github/scripts/*.sh tests/*.sh
bash tests/validate-patch-test.sh
bash tests/multi-repository-test.sh
bash tests/documentation-test.sh
GH_AW_BIN=/absolute/path/to/gh-aw-v0.86.2 ./manage-repositories.sh compile --check
docker compose config --quiet
```

Also test install/update repetition, two simultaneous target jobs with concurrency
1, `disable`, `remove`, stale and unsafe patches, unauthorized actors, fork PRs,
and missing credentials in a disposable test repository before production use.
