# AGENTS.md

This file provides guidance to agents when working with code in this repository.

## What this is

`bos-nginx-config-validator` is a GitHub Marketplace composite action that runs `nginx -t` against an
in-repo nginx config tree at PR time, so syntax errors, unknown directives, unresolved `include`
targets, and unresolvable `proxy_pass` upstreams fail the build instead of failing at container start.
It first renders every `*.conf.template` under `templates_path` through `envsubst`, passing a
positional `${KEY}` list so only keys declared in `template_vars` are substituted and nginx-native
variables such as `$remote_addr` pass through untouched.

Nothing is parsed in-repo: no nginx grammar, no rule catalogue, no finding IDs, no severity levels, no
SARIF. The single authority is the exit status of `nginx -t -e stderr -c /etc/nginx/nginx.conf` run
inside a container, and the single output is `validated`. Real `nginx` is never required on the
runner; Docker is, and the runner needs a working `docker` CLI on `PATH`.

Stack: `action.yml` is `runs.using: composite` with exactly one `shell: bash` step that execs
`bash "${GITHUB_ACTION_PATH}/src/validate.sh"`. That script (374 lines, `set -euo pipefail`) is the
entire implementation. There is no `package.json`, `pyproject.toml`, lockfile, build step, or `dist/`,
and no runtime dependency beyond bash, `docker`, and POSIX tools. Tests are Bats (`bats-core`).
Apache-2.0; default image `lscr.io/linuxserver/nginx:latest`, matching the BOS `docker-*` stack.

Published as `blackoutsecure/bos-nginx-config-validator`, with `main` listed in the hub's
`scripts/marketplace-repo/main-protection-ruleset.json`. Note that
`bos-automation-hub/.github/workflows/nginx-config-validate.yml` is not a caller — it wraps the hub's
own composite `.github/actions/nginx-config-validate@main`, a parallel implementation of the same
idea. Fixing a bug here does not fix it there.

## Commands

```bash
# Prerequisites, all optional locally (see CONTRIBUTING.md). Docker is needed
# only for a real end-to-end run against the nginx image.
brew install shellcheck actionlint bats-core   # or the apt equivalents

# Run the validator against the bundled fixture. For the no-template case use
# CONFIG_PATH=test/fixtures/plain/nginx.conf with TEMPLATES_PATH=''.
GITHUB_OUTPUT=/tmp/gh-out CONFIG_PATH=test/fixtures/basic/nginx.conf \
TEMPLATES_PATH=test/fixtures/basic/http.d TEMPLATES_TARGET_DIR=/run/nginx/http.d \
NGINX_IMAGE=docker.io/library/nginx:1.27-alpine \
TEMPLATE_VARS=$'APP_PORT=8080\nUPSTREAM_HOST=127.0.0.1' \
bash src/validate.sh

# Tests — no Docker daemon required, the suite stubs docker via DOCKER_BIN
bats test/
bats test/unit/validate.bats --filter 'rejects absolute config_path'

# Lint
shellcheck src/validate.sh
bash -n src/validate.sh
actionlint
```

There is no `npm`, `pip`, `make`, or `ruff` target here. Do not invent one.

## Validating changes

CI is dispatched entirely from the hub. The only workflow file on disk is
`.github/workflows/bos-universal-launchpad-kicker.yml`, firing on a six-hourly schedule, on `push` to
`main` for a fixed path list, and on `workflow_dispatch`. Its jobs run in order: `parse-config`
(checkout, read `bos-launchpad-config.json` through the hub's `shared/launchpad-config` action,
summarize it), `managed-files-guard` (fails when `sync_managed_files` is `false` and managed files
still exist on `main`), then `release`, which calls the hub's reusable
`bos-universal-launchpad.yml@main`. The organization security gate, marketplace validation, and
promotion all run inside those hub reusables.

Locally, narrowest-first: `bash -n src/validate.sh`, then `shellcheck src/validate.sh`, then the
single Bats case covering your branch via `--filter`, then all of `bats test/`, then `actionlint` if
`action.yml` or the kicker changed.

The 28 Bats cases in `test/unit/validate.bats` prove input-shape rejection (absolute paths, `..`
traversal, empty `config_path`, missing config file, relative `templates_target_dir`, empty
`nginx_image`, malformed `template_vars` keys), `GITHUB_OUTPUT` emission of `validated=true` /
`validated=false`, the exact `docker run` argv, and every `auto_fill_unknown_vars` branch. They prove
nothing about runtime: no test starts a container, because `DOCKER_BIN` is replaced with a stub that
records argv and exits `0` or `1`. Whether `nginx -t` accepts a config, whether `envsubst` renders
correctly, whether the in-container gettext auto-install works, whether the hardening flags are
accepted by the daemon, and whether the lockdown probe picks the right mode are all unproven. Any
change to the in-container script, the hardening arrays, or the probe needs a real `docker run`
against both the LSIO default and an official `nginx:*-alpine`.

## Architecture

```text
action.yml                                    Composite manifest: 6 inputs, 1 output, one bash step
src/validate.sh                               The entire implementation
test/unit/validate.bats                       Bats suite; stubs docker via DOCKER_BIN
test/fixtures/basic/nginx.conf                Config that includes /run/nginx/http.d/*.conf
test/fixtures/basic/http.d/default.conf.template  Template mixing ${APP_PORT} and $remote_addr
test/fixtures/plain/nginx.conf                Self-contained config, no include, no templates
bos-launchpad-config.json                     Repo-owned launchpad config read by the kicker
.github/workflows/bos-universal-launchpad-kicker.yml  Hub-managed dispatch front door
.github/dependabot.yml                        github-actions ecosystem only, target-branch dev
.editorconfig                                 4-space indent for *.sh, outside the managed block
.markdownlint.yaml                            MD013/MD028/MD033/MD034/MD041 relaxed
.shellcheckrc                                 shell=bash, disable=SC2016,SC1091, external-sources
.gitattributes / .gitignore                   Managed marker blocks only
NOTICE                                        Apache-2.0 attribution
```

Validation flow:

1. `action.yml` maps each input to an uppercase env var (`CONFIG_PATH`, `TEMPLATES_PATH`,
   `TEMPLATE_VARS`, `TEMPLATES_TARGET_DIR`, `NGINX_IMAGE`, `AUTO_FILL_UNKNOWN_VARS`). No input is ever
   interpolated into the `run:` body.
2. `src/validate.sh` shape-checks each input with `case` guards, `die`ing on the first violation:
   `config_path` non-empty, relative, `..`-free, an existing file; `templates_path` relative and
   `..`-free; `templates_target_dir` absolute; `nginx_image` single-line; `template_vars` lines
   `KEY=VALUE` with `KEY` matching `[A-Za-z_][A-Za-z0-9_]*`.
3. Config discovery is explicit, never searched. The config mounts read-only at
   `/etc/nginx/nginx.conf`; `templates_path` mounts read-only at `/templates` only when it exists and
   holds a `*.conf.template` at depth 1, else rendering is skipped and logged. Auto-fill then adds
   `${UPPERCASE_VAR}` tokens found in templates but absent from `template_vars`, valued from
   `AUTO_FILL_UNKNOWN_VARS` (default `127.0.0.1`), with a `::warning::` naming them; the
   uppercase-only heuristic stops lowercase nginx-native variables being masked, and `''` disables the
   scan (strict mode).
4. A probe runs the image under maximum lockdown (`--read-only`, `--network=none`, `--cap-drop=ALL`,
   64 MiB, 16 PIDs) with `command -v envsubst`. Present adds `--read-only` to the main run; absent
   drops it so the in-container `apk`/`apt-get`/`dnf`/`yum` gettext install can write to `/usr`. Every
   other hardening flag applies either way. The main `docker run --entrypoint sh` then creates temp
   dirs, ensures `envsubst`, renders each template into `templates_target_dir`, and runs
   `nginx -t -e stderr -c /etc/nginx/nginx.conf`.
5. There is exactly one finding. Success writes `validated=true` to `GITHUB_OUTPUT` and exits `0`;
   failure writes `validated=false` then `die`s, so the step exits non-zero and consumers never
   observe `validated` as `false`.

Action contract. Inputs, all `required: false`: `config_path` (`root/etc/nginx/nginx.conf`),
`templates_path` (`root/etc/nginx/http.d`), `template_vars` (`''`), `templates_target_dir`
(`/run/nginx/http.d`), `nginx_image` (`lscr.io/linuxserver/nginx:latest`), `auto_fill_unknown_vars`
(`127.0.0.1`). Output: `validated`, bound to `steps.validate.outputs.validated`. Branding: green
`check-circle`. `GITHUB_OUTPUT` and `DOCKER_BIN` are read from the environment but are not inputs —
`DOCKER_BIN` exists purely so the Bats suite can stub docker.

Adding a new check: there are no rule IDs to allocate. Add the input to `action.yml` with a
`required: false` default and description, wire it into the step `env:` block as an uppercase name,
add a defaulting line and a `case` guard in `src/validate.sh` whose `die` names the offending input,
add a rejection and an acceptance case to `test/unit/validate.bats`, and update the `README.md` input
table. New container-side behaviour goes in `in_container_script` and needs a real `docker run`,
because Bats cannot reach it.

### `bos-launchpad-config.json` and the launchpad kicker

This repository uses the launchpad kicker, not the gatekeeper kicker most `blackoutsecure` action
repos carry. `.github/workflows/bos-universal-launchpad-kicker.yml` is hub-managed and must not be
hand-edited; behaviour comes from the repo-root `bos-launchpad-config.json`, whose schema is owned by
`bos-automation-hub`. The kicker's `parse-config` job runs the hub's `shared/launchpad-config@main`
action to read that JSON into a single `cfg` output, and every downstream input is a
`fromJson(needs.parse-config.outputs.cfg)` lookup with a literal fallback, covering `upstream.*`,
`stages.*` (`docker`, `balena`, `github_release`, `companion_docker`), `docker.*`, `scout.*`,
`balena.*`, `release.*`, `security_scan.*`, `repo_metadata.*`, `triggers.force_on_push`, and
`platforms`.

Because every stage defaults off, a minimal file is a valid file. The current one is
`{"sync_files": {"services": ["common", "lf_line_endings"]}}`, enabling only the two managed-file-sync
services this repository consumes — matching the `bos-automation-hub:common` markers in
`.editorconfig` and `.gitignore` and `bos-automation-hub:lf_line_endings` in `.gitattributes`. No
`stages.*` key is set, so the Docker, Balena, companion-Docker, and GitHub Release stages stay off;
this is a bash action with nothing to build or publish. Change gate or stage behaviour here, never in
the kicker.

## Conventions

Bash follows the style stated in `CONTRIBUTING.md`: `set -euo pipefail`, POSIX `[ ]` over `[[ ]]`
unless a bash-only feature is required, 4-space indent (an `.editorconfig` override deliberately
placed outside the managed marker block), every expansion quoted and braced. Hard failures go through
`die` so they surface as GitHub annotations; noisy output is wrapped in `::group::` / `::endgroup::`.
Input validation is a chain of `case` guards whose messages name the input and quote the value:

```bash
case "${CONFIG_PATH}" in
    '')   die "input 'config_path' must be non-empty" ;;
    /*)   die "input 'config_path' must be repo-relative (got absolute: '${CONFIG_PATH}')" ;;
    *..*) die "input 'config_path' must not contain '..' (got: '${CONFIG_PATH}')" ;;
esac
```

Comments explain why a non-obvious security or compatibility choice exists. The long blocks justifying
`--cap-add=CHOWN`, `nginx -t -e stderr`, the uppercase-only auto-fill heuristic, and the two-tier
hardening probe are load-bearing history — do not strip them.

## Blackout Secure conventions

These apply to every repository in the `blackoutsecure` organization.

### Branch model

- `dev` is the default branch and where all work lands.
- `main` is the promoted stable runtime that consumers reference through `@main`.
- Version tags (`vX.Y.Z` and a floating `vX`) point at promoted runtime commits.
- Promotion is driven from `bos-automation-hub` (`release-promote.yml`). Do not push
  directly to `main` and do not move tags by hand.

### Centrally managed files - do not hand-edit here

`blackoutsecure/bos-automation-hub` distributes these through
`bos-managed-file-sync-action`. Change the source under the hub's `sync-files/`, never the
copy in this repository:

- `LICENSE`, `CODE_OF_CONDUCT.md`, `CONTRIBUTING.md`, `SECURITY.md`, `SUPPORT.md`
- `.github/FUNDING.yml`, `.github/PULL_REQUEST_TEMPLATE.md`, `.github/ISSUE_TEMPLATE/`
- the managed kicker workflow under `.github/workflows/` — here that is
  `bos-universal-launchpad-kicker.yml`, not the gatekeeper kicker other action repos carry
- the `# >>> managed-file-sync:<service> >>> ... # <<< managed-file-sync:<service> <<<`
  delimited blocks inside `.editorconfig`, `.markdownlint.yaml`, `.shellcheckrc`,
  `.yamllint.yml`, `.gitignore`, and `README.md` — here the on-disk marker namespace is
  `bos-automation-hub:<service>` and the blocks present are in `.editorconfig`,
  `.gitattributes`, `.gitignore`, and `.github/dependabot.yml`

This repository has no `.github/bos-universal-config.json`; the repo-root
`bos-launchpad-config.json` is the repo-owned config and is where gate behaviour changes.

### CI gate

Pushes and pull requests run the hub's reusable `bos-universal-security.yml`, reported as a
single required check. It runs markdownlint, yamllint, shellcheck, and actionlint; ESLint,
Prettier, Ruff, pytest, and Bats where the repository has them; `bos-code-scanning-kit`
(secret scan, SAST, GHAS posture) and CodeQL; dependency review; and compliance checks for
the canonical README header and a conventional-commit PR title
(`feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert: subject`).

Every `uses:` reference in a workflow must be a commit SHA with a trailing version comment,
for example `actions/checkout@<sha> # v4.2.2`.

## Boundaries

### Always

- Keep `src/validate.sh` dependency-free: bash, `docker`, and POSIX tools only.
- Route a new input through `action.yml`, the step `env:` block, a defaulting line, and a
  `case` guard, in that order, then update the `README.md` input table.
- Add both a rejection and an acceptance Bats case for any new guard.
- Run `bash -n src/validate.sh`, `shellcheck src/validate.sh`, `bats test/`, and `actionlint`.
- Exercise changes to `in_container_script`, the hardening arrays, or the envsubst probe with a
  real `docker run` against both the LSIO default and an official `nginx:*-alpine`.
- Keep path inputs guarded against absolute prefixes and `..`, and keep mounts read-only.

### Ask first

- Renaming, removing, or re-defaulting any of the six inputs or the `validated` output — this
  is published Marketplace surface consumed through `@v1` and `@main`.
- Changing the default `nginx_image`, `auto_fill_unknown_vars`, or the uppercase-only heuristic.
- Changing the hardening flag set, the two-tier probe, or the `--cap-add=CHOWN` exception.
- Adding a runtime dependency, a network call, or a second `docker run`.
- Adding a locally-defined workflow, or editing `bos-launchpad-config.json` to enable a stage.
- Reconciling behaviour with the hub's parallel `.github/actions/nginx-config-validate`
  composite, which has its own consumers.

### Never

- Never weaken a validation rule to make a build pass — no relaxed path guard, no widened
  `template_vars` key pattern, no swallowed non-zero `nginx -t` exit, and no leaning on
  `auto_fill_unknown_vars` to mask a genuine template error.
- Never commit real production nginx configs, TLS private keys, certificates, internal upstream
  hostnames, or credentials. Fixtures stay synthetic and minimal.
- Never interpolate `${{ inputs.* }}` or any untrusted value into a `run:` body.
- Never hand-edit centrally managed files, including
  `.github/workflows/bos-universal-launchpad-kicker.yml` and the
  `bos-automation-hub:<service>` marker blocks.
- Never use an unpinned `uses:` ref; every reference is a commit SHA with a version comment.
- Never push directly to `main` or move a version tag by hand; promotion runs from the hub.
