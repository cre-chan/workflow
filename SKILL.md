---
name: moth-watcher-runner
description: Install, update, remove, verify, and recover the cre-chan multi-repository Dockerized Codex automation and its centrally compiled gh-aw workflows.
---

# Moth Watcher Runner

Use `docs/SETUP.md` as the operational source of truth. Use only commands exposed
by `./manage-repositories.sh --help`; repeat an interrupted operation instead of
manually editing runner state.

## Security boundaries

- Keep Codex authentication in a dedicated home. Require `auth.json` mode `0600`.
- Keep the fine-grained administration PAT in a separate mode-`0600` file mounted
  only into `repository-admin`; never place it in `.env`, GitHub Secrets, worker
  input, an artifact, or a log.
- Do not create or configure a GitHub App. Repository writes are performed by
  gh-aw Safe Outputs with the target repository's `GITHUB_TOKEN`.
- The self-hosted agent job has read-only GitHub permissions. The isolated Codex
  worker gets no GitHub token, SSH agent, Git credential store, host Docker socket,
  or ordinary user home.
- Keep `run-codex-container.sh`, read-only `auth.json`, disposable volumes,
  patch-only output, and the path/secret/binary/size/stale-SHA validator enabled.
- Do not enable automatic merging or automatic ready-for-review conversion.

## Standard operations

Prepare `.env`, initialize volumes, register the dedicated admin runner, and start
the stack:

```bash
docker compose run --rm workspace-init
./manage-repositories.sh bootstrap-admin
docker compose up -d repository-admin runner-manager
docker compose ps
```

The management CLI reads only the two documented absolute path variables from
`.env` and never evaluates it as shell code. `workspace-init` must create the
admin runner `_work` directory as UID/GID 1000.

Manage targets through the common interface:

```bash
./manage-repositories.sh install cre-chan/REPOSITORY true true
./manage-repositories.sh update cre-chan/REPOSITORY
./manage-repositories.sh upgrade cre-chan/REPOSITORY
./manage-repositories.sh upgrade-all
./manage-repositories.sh disable cre-chan/REPOSITORY
./manage-repositories.sh remove cre-chan/REPOSITORY
./manage-repositories.sh concurrency 1
./manage-repositories.sh status
```

`install` and `update` accept Issue-implementation and PR-feedback booleans.
Target arguments accept `REPOSITORY` or `cre-chan/REPOSITORY`; the short form is
normalized to the `cre-chan` owner before configuration changes.
`upgrade` changes only the immutable central SHA in the target caller. Target
repositories never run gh-aw compilation. `disable` preserves the caller and
runner registration but stops scheduling its runner; `remove` unregisters it and
directly commits deletion of the caller. These operations must remain idempotent.

The GitHub UI invokes the same script on `[self-hosted, moth-watcher-admin]`.
Allow only actor `cre-chan`, the default branch, and manual dispatch. If this
runner is offline, leave the job queued; do not attempt partial remote changes.

## Verification and stop conditions

Run the shell, patch, multi-repository, documentation, Compose, and deterministic
gh-aw compile checks documented in `docs/SETUP.md`. Verify each enabled target is
`running`, its caller SHA equals the configured central SHA, and its default
Actions workflow permission remains `read` (the caller grants only its explicit
three write scopes).

Stop without enabling a target if its owner is not `cre-chan`, admin permission is
missing, the central ref is not a full commit SHA, either credential file is
missing or too permissive, a runner would be shared with an untrusted repository,
or GitHub credentials can reach the Codex worker.

Never run `docker compose down --volumes` during maintenance. Preserve
`runner-state`, `runner-work`, `codex-locks`, `admin-runner-state`, and
`docker-data`, and `dind-sock`. Recover by restoring credential availability, rerunning
`workspace-init`, repeating the failed management operation, and then checking
`status` and service logs.
