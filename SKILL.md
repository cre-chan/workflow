---
name: moth-watcher-runner
description: Set up and verify the Dockerized self-hosted Codex runner and repository-scoped GitHub App used by cre-chan/workflow Issue-to-Draft-PR automation. Use for installing, registering, starting, updating, or troubleshooting this runner; do not use for ordinary application development.
---

# Moth Watcher Runner

Configure the local execution side of the `cre-chan/workflow`
Issue-to-Draft-PR automation. Keep this skill directory outside the application
repository. GitHub App credentials must remain on GitHub-hosted runners and must
never be copied here.

## Preserve these boundaries

- Trigger only for a newly opened Issue that already has `agent-ready`.
- Require both the Issue author and event sender to have repository write access.
- Give the self-hosted job GitHub read permissions only.
- Let the local runner emit a patch; let a GitHub-hosted job validate, publish,
  label, and comment with a short-lived GitHub App installation token.
- Never give Codex a GitHub App key, installation token, SSH agent, Git credential
  store, host Docker socket, or host home-directory mount.
- Do not enable automatic merge or automatically promote a Draft PR.

## Configure the GitHub App

Create a GitHub App named `moth-watcher-codex` with only these repository
permissions:

- Metadata: read
- Contents: read and write
- Issues: read and write
- Pull requests: read and write

Install it only on the explicitly approved repositories, initially
`cre-chan/workflow`. Store its App ID in the repository
Actions variable `CODEX_APP_ID` and its private key in the repository Actions
secret `CODEX_APP_PRIVATE_KEY`. Do not display or download an existing private key
unless the user explicitly authorizes credential handling.

Ensure the `agent-ready`, `codex-processing`, and `codex-pr-created` labels exist.
Protect `main`, require review for `.github/workflows/**` and
`.github/scripts/**`, and keep automatic merging disabled.

## Configure Codex authentication

Use a Codex home separate from the interactive user's normal Codex home:

```bash
mkdir -p "$HOME/.codex-moth-watcher-runner"
chmod 700 "$HOME/.codex-moth-watcher-runner"
CODEX_HOME="$HOME/.codex-moth-watcher-runner" codex login --device-auth
chmod 600 "$HOME/.codex-moth-watcher-runner/auth.json"
```

The device login requires the user to complete authentication. Pause and ask them
to do so; never attempt to automate or expose the one-time code. Treat `auth.json`
like a password. Never commit it, upload it as an artifact, add it to GitHub
Secrets, or copy it into the image.

ChatGPT-managed authentication in unattended CI for a public repository is an
advanced, limited-use configuration. For production unattended operation,
recommend a managed service account with workload identity.

## Register and run the Dockerized self-hosted runner

Use `compose.yaml`. It starts an Actions runner container and a separate rootless
Docker daemon used only for disposable Codex workers. It never mounts the host
Docker socket. The daemon sidecar is privileged inside Docker Desktop's Linux VM;
do not assume the same boundary is sufficient on a native Linux host.

The worker installs Bubblewrap as required by the Codex Linux sandbox. Its Docker
default seccomp profile is disabled because it blocks Bubblewrap's namespace
creation, but the worker still drops every capability, enables
`no-new-privileges`, uses a read-only root filesystem, and runs inside the
separate rootless daemon. Do not remove `--sandbox workspace-write` from the Codex
command as a workaround for namespace errors.

The runner copies each checkout into an Issue-specific Docker volume owned by the
non-root worker UID 1000. Codex edits only that copy. After successful validation,
only `.codex-result` is copied back to the Actions workspace, and the disposable
volume is removed even on failure. This avoids the UID remapping and write-access
problems caused by mounting the shared `runner-work` volume directly into a
container managed by the nested rootless daemon.

Before enabling hidden-file upload for the following artifact step, the runner
requires exactly `base-sha.txt`, `codex.patch`, `summary.md`, and
`test-results.md` as regular, non-symlink files in `.codex-result`. Reject any
other entry; never broaden the artifact path beyond that directory. The workflow
must set `include-hidden-files: true` on the upload step because
`actions/upload-artifact` otherwise excludes the explicitly selected hidden
directory.

Copy `.env.example` to `.env` and set `CODEX_AUTH_DIR` to the absolute dedicated
Codex home. Never place a token or private key in `.env`.

In `cre-chan/workflow`, open **Settings > Actions > Runners > New self-hosted
runner** and obtain the short-lived registration token. Register once with a
throwaway container so the token is not retained in the long-running container:

```bash
RUNNER_TOKEN='<short-lived token>' \
  docker compose run --rm --no-deps \
  -e RUNNER_TOKEN="$RUNNER_TOKEN" actions-runner register
```

Then start and inspect the services:

```bash
docker compose run --rm workspace-init
docker compose up -d actions-runner
docker compose ps
docker compose logs --tail=100 actions-runner
```

`workspace-init` initializes the named `runner-work` volume as UID/GID
`1000:1000` with mode `0755`. Compose also runs it automatically before
`actions-runner` starts. It changes only that named volume and preserves the
runner registration in `runner-state`.

Wait until the runner log contains `Listening for Jobs` before rerunning or
opening an eligible Issue. A forced recreation can leave the previous GitHub
session active temporarily; do not dispatch a job while the replacement runner
reports `A session for this runner already exists`.

The expected runner is `workflow-codex-docker-1` with `self-hosted`, `Linux`,
`ARM64`, and `moth-watcher-codex` labels. One instance accepts one job at a time.
Do not scale the service by cloning its registration volume; each parallel runner
needs a unique GitHub registration, name, and state volume.

## Validate before enabling

Run static and image checks from this directory:

```bash
bash -n ./*.sh
docker build -t moth-watcher-codex-runner:test .
docker run --rm --entrypoint /bin/bash moth-watcher-codex-runner:test \
  -lc 'codex --version && bwrap --version && python3 --version && jq --version'
```

Also validate the Dockerized runner path:

```bash
docker compose config --quiet
docker compose run --rm workspace-init
docker compose run --rm --no-deps --entrypoint /bin/bash actions-runner -lc \
  'test -w /runner/_work && mkdir -p /runner/_work/_tool'
docker compose exec actions-runner docker info
```

Do not invoke `run-codex-container.sh` until authentication is configured and the
repository checkout is a disposable runner workspace. The script mounts only the
checkout and dedicated Codex home into the worker.

Verify these event cases after the workflow is merged:

- A write-authorized user creates an Issue with `agent-ready`: one Draft PR is
  created through the GitHub App.
- The Issue lacks `agent-ready`: the self-hosted runner is not reached.
- The label is added after creation: the self-hosted runner is not reached.
- The author or event sender lacks write access: the self-hosted runner is not
  reached.
- `main` changes while Codex works: the stale patch is rejected without a PR.

The current test repository runs `tests/validate-patch-test.sh`. A failed or
missing supported verification command stops the worker without producing a PR.
Every generated Draft PR still requires human review before it is marked ready.

## Stop conditions

Stop without enabling the workflow if any of these are unresolved:

- The GitHub App is installed beyond the intended repository.
- The App has organization, Actions administration, or repository administration
  permissions.
- The local job receives a GitHub write credential.
- The runner is available to untrusted repositories.
- Docker would expose the host socket, home directory, SSH agent, or Git
  credentials to the worker.
- `CODEX_AUTOMATION_HOME/auth.json` is absent or has permissions broader than
  `0600`.

## Stop and update

```bash
docker compose stop
docker compose build --pull actions-runner
docker compose up -d actions-runner
docker compose logs --tail=100 actions-runner
```

Confirm `Listening for Jobs` before rerunning a queued or failed workflow. The
runner enables the upstream manual signal trap, and the one-minute Compose stop
grace period lets it close its GitHub session cleanly during normal maintenance.

Do not run `docker compose down --volumes` during ordinary maintenance: it deletes
the runner registration, work volume, and dedicated daemon state.

## Troubleshoot runner work-volume permissions

If a job fails before checkout with `Access to the path '/runner/_work/_tool' is
denied`, inspect the work volume from the runner container:

```bash
docker compose exec actions-runner \
  stat -c '%u:%g %a %n' /runner/_work /runner/_work/_tool
docker compose exec actions-runner test -w /runner/_work
```

Repair the existing named volume without deleting it, then recreate the runner:

```bash
docker compose run --rm workspace-init
docker compose up -d --force-recreate actions-runner
docker compose exec actions-runner \
  sh -lc 'test -w /runner/_work && mkdir -p /runner/_work/_tool'
```

Expected ownership is `1000:1000`. Do not replace this procedure with broad host
filesystem permission changes or `docker compose down --volumes`.
