# Blackout Secure Nginx Config Validator

**Copyright © 2025-2026 Blackout Secure | Apache License 2.0**

[![Marketplace](https://img.shields.io/badge/GitHub%20Marketplace-blue?logo=github)](https://github.com/marketplace/actions/blackout-secure-nginx-config-validator)
[![GitHub release](https://img.shields.io/github/v/release/blackoutsecure/bos-nginx-config-validator?sort=semver)](https://github.com/blackoutsecure/bos-nginx-config-validator/releases)
[![License](https://img.shields.io/badge/license-Apache%202.0-blue)](LICENSE)
[![Made by BlackoutSecure](https://img.shields.io/badge/made%20by-BlackoutSecure-1f1f1f)](https://github.com/blackoutsecure)

Pre-merge `nginx -t` validation for an in-repo nginx config tree. Renders
`*.conf.template` files via `envsubst`, runs `nginx -t` inside the official
`nginx` container, and catches syntax errors, unresolved directives, and
missing `include` targets at PR time — not at container start.

## ✨ Features

- **Runtime-faithful**: validates inside the official `nginx` container so
  package-managed paths (`/etc/nginx/modules/*.conf`, `/etc/nginx/mime.types`)
  resolve the same way they do in production.
- **Template-aware**: renders `*.conf.template` files via `envsubst` with a
  caller-supplied `KEY=VALUE` list before running `nginx -t`.
- **Positional-key `envsubst`**: only the keys you list are substituted, so
  nginx-native variables like `$remote_addr`, `$status`, and `$request_uri`
  pass through your templates unchanged.
- **Smart defaults for undeclared template vars**: any `${UPPERCASE_VAR}`
  referenced in a template but not declared in `template_vars` is auto-filled
  with `127.0.0.1` (override via `auto_fill_unknown_vars` or set it to `''`
  for strict mode), so a forgotten `${UPSTREAM_HOST}` doesn't break the build
  before you see the warning telling you to declare it.
- **Hardened container runtime**: `--cap-drop=ALL` (only `CHOWN` re-added),
  `--security-opt=no-new-privileges`, `--pids-limit`, `--memory` cap, tmpfs
  `/tmp` + `/run` (noexec, nosuid), and `--read-only` root filesystem when
  the image ships `envsubst` natively. See [Container hardening](#container-hardening).
- **Safe inputs**: paths are validated for absolute prefixes and `..`
  traversal; all inputs flow through `env:` (never interpolated into
  `run:` bodies).
- **Tolerant of layouts**: missing templates directory? Empty? No
  problem — only `nginx.conf` is validated in that case.
- **Dependabot-friendly**: the nginx image ref is a plain input default,
  so `docker` ecosystem updates flow through your `dependabot.yml`.
- **No runtime dependencies**: pure bash + Docker on the runner. Works on
  every GitHub-hosted Ubuntu runner out of the box.

## 📋 Prerequisites

- A GitHub Actions runner with Docker (every `ubuntu-latest` runner
  qualifies; self-hosted runners need a working `docker` CLI on `PATH`).
- An in-repo nginx config tree — typically a `nginx.conf` plus a directory
  of `*.conf.template` files that get rendered at container start.

## 🚀 Quick start

```yaml
name: Lint nginx config

on:
  push:
    paths: ['root/etc/nginx/**', '.github/workflows/lint-nginx.yml']
  pull_request:
    paths: ['root/etc/nginx/**', '.github/workflows/lint-nginx.yml']
  workflow_dispatch:

permissions:
  contents: read

jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          persist-credentials: false

      - uses: blackoutsecure/bos-nginx-config-validator@v1
        with:
          # Placeholder values used only at validation time. Production
          # values get resolved at container start by your own init scripts.
          template_vars: |
            APP_PORT=8080
            UPSTREAM_HOST=127.0.0.1
```

The defaults assume the common docker-image-style layout:

```text
root/etc/nginx/
├── nginx.conf
└── http.d/
    ├── default.conf.template
    └── api.conf.template
```

If your layout differs, pass `config_path` and `templates_path`.

## 📖 Examples

### 1. Plain `nginx.conf` — no templates

```yaml
- uses: blackoutsecure/bos-nginx-config-validator@v1
  with:
    config_path: conf/nginx.conf
    templates_path: ''   # disable template rendering entirely
```

### 2. Custom layout under `deploy/`

```yaml
- uses: blackoutsecure/bos-nginx-config-validator@v1
  with:
    config_path: deploy/nginx/nginx.conf
    templates_path: deploy/nginx/conf.d
    templates_target_dir: /etc/nginx/conf.d
    template_vars: |
      APP_PORT=3000
      STATIC_ROOT=/srv/www
```

### 3. Multiple config trees in one repo

Call the action once per tree. Each step gets its own
`config_path` / `templates_path` / `template_vars`:

```yaml
- name: Validate frontend nginx
  uses: blackoutsecure/bos-nginx-config-validator@v1
  with:
    config_path: services/frontend/nginx/nginx.conf
    templates_path: services/frontend/nginx/http.d
    template_vars: |
      FRONTEND_PORT=8080

- name: Validate api nginx
  uses: blackoutsecure/bos-nginx-config-validator@v1
  with:
    config_path: services/api/nginx/nginx.conf
    templates_path: services/api/nginx/http.d
    template_vars: |
      API_PORT=9000
      UPSTREAM_HOST=api-backend
```

### 4. Using a different nginx image

The default `lscr.io/linuxserver/nginx:latest` matches the runtime of the
BOS `docker-*` repos. To validate against a different image (e.g. the
official Docker Hub `nginx`):

```yaml
- uses: blackoutsecure/bos-nginx-config-validator@v1
  with:
    nginx_image: docker.io/library/nginx:1.27-alpine
    template_vars: |
      APP_PORT=8080
```

Tip: pin to a specific tag so Dependabot's `docker` ecosystem can bump it.
Add this to your `.github/dependabot.yml`:

```yaml
- package-ecosystem: docker
  directory: /
  schedule:
    interval: weekly
```

See [Docker image requirements](#-docker-image-requirements) below for
the full contract a custom image must satisfy.

### 5. Validating nginx-managed variables

This is the whole point of the positional-key `envsubst` design: list
**only your own template variables** in `template_vars`. Anything else
(nginx vars, awk-style `$0`, etc.) passes through untouched.

```nginx
# api.conf.template
server {
    listen ${APP_PORT};
    location / {
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        access_log /var/log/nginx/api.log combined;
        return 200 "Hello from $remote_addr\n";
    }
}
```

```yaml
- uses: blackoutsecure/bos-nginx-config-validator@v1
  with:
    template_vars: |
      APP_PORT=8080
    # $proxy_add_x_forwarded_for and $remote_addr are NOT in template_vars,
    # so they pass through to nginx unchanged. Only ${APP_PORT} is replaced.
```

## ⚙️ Inputs

All inputs are GitHub Actions strings. Format constraints and validation
rules below are enforced by the action — violations fail fast with a
specific `::error::` annotation, never an opaque bash crash.

| Input | Type / format | Default | Description |
|---|---|---|---|
| `config_path` | Repo-relative POSIX path (no leading `./`, no `..` segments) | `root/etc/nginx/nginx.conf` | Path to your `nginx.conf`. Mounted read-only at `/etc/nginx/nginx.conf` inside the validation container. |
| `templates_path` | Repo-relative POSIX path, **or** empty string to disable | `root/etc/nginx/http.d` | Directory of `*.conf.template` files. Empty / missing / no matching files disables template rendering (only `nginx.conf` is validated). |
| `template_vars` | Multiline string — one `KEY=VALUE` per line | `''` (empty) | Variables forwarded to `envsubst`. See [`template_vars` shape](#template_vars-shape) below. |
| `templates_target_dir` | Absolute POSIX path (must start with `/`) | `/run/nginx/http.d` | Where rendered templates land **inside the container**. Must match the `include` directive in your `nginx.conf`. |
| `nginx_image` | Single-line OCI image reference (registry/repo[:tag][@digest]) | `lscr.io/linuxserver/nginx:latest` | Container image used for validation. See [Docker image requirements](#-docker-image-requirements) below. |
| `auto_fill_unknown_vars` | Single-line string, or empty string to disable | `'127.0.0.1'` | Fallback value substituted for any `${UPPERCASE_VAR}` reference found in your templates but **not** declared in `template_vars`. Makes the common case (an unresolved `${UPSTREAM_HOST}` in `proxy_pass`) validate out-of-the-box. See [auto-fill behavior](#auto-fill-behavior) below for the full semantics. |

### `template_vars` shape

- One `KEY=VALUE` per line.
- `KEY` must match `[A-Za-z_][A-Za-z0-9_]*` (shell-identifier rules).
- `VALUE` may not contain newlines (multi-line values are not supported).
- Blank lines and lines starting with `#` are ignored.
- Values are passed via `docker run -e KEY=VALUE`; no shell quoting required.

```yaml
template_vars: |
  # comments are allowed
  APP_PORT=8080
  UPSTREAM_HOST=backend.internal
  STATIC_ROOT=/srv/www
```

### Auto-fill behavior

The single most common validation failure is an unresolved
`${UPSTREAM_HOST}` (or similar) in `proxy_pass http://${HOST}:port;` —
`nginx -t` resolves literal upstream hostnames at config-load time, and
an empty expansion (no `template_vars` entry) yields a syntax error
*before* nginx even tries DNS. To make the common case validate
out-of-the-box, the action **scans every `*.conf.template` for
`${UPPERCASE_VAR}` references that aren't declared in `template_vars`
and auto-fills them** with `auto_fill_unknown_vars` (default
`'127.0.0.1'`).

What the auto-fill does and doesn't do:

| | Auto-filled? | Why |
|---|:-:|---|
| `${UPSTREAM_HOST}` (uppercase, not in `template_vars`) | ✓ | Common envsubst convention; auto-fill makes `nginx -t` succeed and warns you so you can declare the key. |
| `${APP_PORT}` (uppercase, already in `template_vars`) | ✗ | Your explicit value always wins — auto-fill never overrides. |
| `${remote_addr}`, `${host}`, `${proxy_add_x_forwarded_for}` | ✗ | Lowercase — the heuristic targets uppercase names only, so nginx-native variables are never masked. |
| `${var}` (lowercase, intended as envsubst) | ✗ | Lowercase — declare in `template_vars` or rename to uppercase. |

Every auto-fill emits a GitHub Actions `::warning::` annotation listing
the affected keys so they show up in the workflow run summary. Example:

```
::warning::nginx-config-validator: auto-filled 1 undeclared template var(s) with '127.0.0.1': UPSTREAM_HOST
nginx-config-validator:   declare these in template_vars to silence this warning, or set auto_fill_unknown_vars: '' for strict mode
```

**Tuning the fill value.** `127.0.0.1` parses as a valid `proxy_pass`
host, a valid `listen` address (without port), and a valid `server_name`
token — enough to satisfy nginx for the vast majority of templates. If
your templates use unresolved vars in contexts where `127.0.0.1` would
be rejected (e.g. as a port number or filesystem path), supply your own
value:

```yaml
with:
  auto_fill_unknown_vars: 'placeholder.example'   # any single-line string
```

**Strict mode (opt-out).** Set `auto_fill_unknown_vars: ''` to disable
the scan entirely. In strict mode, undeclared `${UPPERCASE_VAR}` tokens
pass through `envsubst` untouched and surface as `nginx -t` parse
errors — surfacing missing `template_vars` declarations loudly at
review time:

```yaml
with:
  template_vars: |
    APP_PORT=8080
    UPSTREAM_HOST=backend.internal
  auto_fill_unknown_vars: ''   # forbid auto-fill; every key must be declared
```

## 📤 Outputs

| Output | Type | Value | When set |
|---|---|---|---|
| `validated` | String (`'true'`) | `'true'` exactly when `nginx -t` exits 0. | Written only on success. On any validation failure the step `die`s with an `::error::` annotation **before** this is written, so consumers can treat the output as either `'true'` or absent (no `'false'` is ever emitted). |

## 🐳 Docker image requirements

The `nginx_image` input accepts any OCI-compatible image that satisfies
the contract below. The default ([`lscr.io/linuxserver/nginx`](https://github.com/linuxserver/docker-nginx))
matches the runtime of the BOS `docker-*` image stack.

| Requirement | Default LSIO image | Notes |
|---|---|---|
| `nginx` on `PATH` | ✓ (`/usr/sbin/nginx`, currently 1.28.x) | The action runs `nginx -t -c /etc/nginx/nginx.conf`. |
| `sh` on `PATH` | ✓ | The action invokes `--entrypoint sh -c '<script>'` to bypass the image's own `ENTRYPOINT`. |
| `envsubst` on `PATH` | Auto-installed | Required only when `templates_path` resolves to at least one `*.conf.template` file. If missing, the action tries `apk add gettext` → `apt-get install gettext-base` → `dnf install gettext` → `yum install gettext` in that order. |
| Compiled-in modules referenced by your `nginx.conf` | ✓ (brotli, dav_ext, echo, fancyindex, devel_kit, geoip2, headers_more, etc.) | If your `nginx.conf` has `include /etc/nginx/modules/*.conf;` or `load_module`, the image must ship the matching `.so` files. |
| Writable `/tmp` and `/run` | n/a | The action mounts these as `tmpfs` (writable, `noexec`, `nosuid`) so the image's own `/tmp` and `/run` are never touched — see [Container hardening](#container-hardening). |
| Standard OCI manifest (multi-arch optional) | ✓ (linux/amd64, linux/arm64, linux/arm/v7) | The runner pulls the manifest matching its own architecture; both `linux/amd64` and `linux/arm64` runners work. |

### Bypassing image init systems

The `--entrypoint sh` override discards the image's `ENTRYPOINT` and
`CMD`, so init systems like **s6-overlay** (LSIO), **supervisord**, or
**tini** are bypassed entirely. `nginx -t` runs directly as PID 1's
child — no service supervision, no port binding, no privilege
escalation. This is what makes the LSIO image (which normally boots
through s6-overlay) safe and fast to use for validation.

### Container hardening

Validation containers run under the strictest `docker run` settings that
still let `nginx -t` succeed. The exact flag set is decided per run by a
one-shot probe: if the image already ships `envsubst`, the main run gets
**full lockdown**; otherwise it falls back to **standard lockdown** (the
auto-install path needs a writable `/usr` so `apk add gettext` can land
the binary).

| Flag | Full lockdown | Standard lockdown | Why |
|---|:-:|:-:|---|
| `--rm` | ✓ | ✓ | Container is destroyed on exit; nothing persists. |
| `--entrypoint sh` | ✓ | ✓ | Bypasses the image's init system (s6-overlay, etc.). |
| `-v <config>:/etc/nginx/nginx.conf:ro` | ✓ | ✓ | Your config file is mounted **read-only**. |
| `-v <templates>:/templates:ro` (when present) | ✓ | ✓ | Templates are mounted **read-only**. |
| `--cap-drop=ALL` | ✓ | ✓ | Drops every Linux capability. |
| `--cap-add=CHOWN` | ✓ | ✓ | Re-added only because `nginx -t` calls `chown()` on its `client_body_temp_path` / `proxy_temp_path` dirs to match the configured worker user (UID 101 on alpine-based images). Without this single capability, validation fails with `Operation not permitted`. |
| `--security-opt=no-new-privileges:true` | ✓ | ✓ | Disables setuid / sudo / file-cap escalation paths. |
| `--pids-limit=64` | ✓ | ✓ | Caps process count inside the container (defense against fork-bomb-shaped bugs). |
| `--memory=512m` + `--memory-swap=512m` | ✓ | ✓ | Caps RAM at 512 MiB and forbids swap usage. |
| `--hostname=nginx-validator` | ✓ | ✓ | Hides the host's identifier inside the container. |
| `--tmpfs /tmp:rw,noexec,nosuid,size=64m` | ✓ | ✓ | Writable but non-executable scratch space for nginx temp paths. |
| `--tmpfs /run:rw,noexec,nosuid,size=16m` | ✓ | ✓ | Writable, non-executable space where rendered template configs land. Shadows the image's pre-created `/run/nginx` (which on LSIO is owned by the `nginx` user — unreachable to us once `DAC_OVERRIDE` is dropped). |
| `--read-only` | ✓ | ✗ | Root filesystem is read-only. Skipped in standard lockdown so `apk add` / `apt-get install` can write the auto-installed `envsubst` binary to `/usr/bin`. |
| `nginx -t -e stderr -c /etc/nginx/nginx.conf` | ✓ | ✓ | `-e stderr` overrides nginx's compile-time default error-log path (which on LSIO is `/var/lib/nginx/logs/error.log`, owned by the `nginx` user) so we get clean CI output without granting `DAC_OVERRIDE`. |

**The probe.** Before the main run, the action launches a tiny container
with the same image under maximum lockdown (`--read-only`, `--network=none`,
`--cap-drop=ALL`, 64 MiB / 16 PID / 4 MiB-`/tmp` limits) and runs `command
-v envsubst`. The probe is purely informational — it never sees your
config or templates.

The `hardening = full (…)` or `hardening = standard (…)` line in the
step log tells you which mode was chosen. If you want to force full
lockdown on every run, pin `nginx_image` to an image that ships
`envsubst` natively (the official `docker.io/library/nginx:*-alpine`
family does) or build a custom LSIO image with `gettext` baked in.

### Choosing an image

| Your runtime is… | Recommended `nginx_image` |
|---|---|
| `lscr.io/linuxserver/nginx` | Leave the default. |
| `ghcr.io/linuxserver/baseimage-alpine` + `apk add nginx` (BOS docker-* pattern) | Leave the default — the LSIO image is package-compatible with what your runtime ends up with. |
| Official `nginx` image (Docker Hub) | `docker.io/library/nginx:1.27-alpine` (ships `envsubst` natively, smaller image, no extra modules). |
| A custom image you build yourself | Pin to your own image. Ensure it ships `nginx` and (if you use templates) `envsubst`. |
| You use unusual modules not in the LSIO image | Pin to an image that compiles them in, or build a custom one. |

## 🔐 Permissions

The action itself only needs the default `contents: read`. It does not
write to the repo, call the GitHub API, or upload artifacts.

```yaml
permissions:
  contents: read
```

## 🔒 Security model

| Boundary | Treatment |
|---|---|
| All `inputs.*` | Forwarded via `env:`; never interpolated into `run:` bodies. |
| `config_path` / `templates_path` | Rejected if absolute or containing `..`. |
| `templates_target_dir` | Must be absolute (in-container path). |
| `template_vars` keys | Validated against `[A-Za-z_][A-Za-z0-9_]*`. |
| `template_vars` values | Newlines rejected; forwarded only via `docker run -e`. |
| `nginx_image` | Single-line non-empty image ref required. |
| Mounts | `nginx.conf` and templates are mounted **read-only** into the container. |
| `envsubst` substitution | Positional key list — only keys you supply are touched; nginx-native variables pass through. |
| Container runtime | `--cap-drop=ALL` (only `CHOWN` re-added for `nginx -t`'s temp-path chown), `--security-opt=no-new-privileges`, `--pids-limit=64`, `--memory=512m` (no swap), `--tmpfs /tmp` + `/run` (`noexec`, `nosuid`), `--read-only` root FS when the image ships `envsubst` natively. See [Container hardening](#container-hardening) for the full flag matrix. |

See the organization-wide
[Security Policy](https://github.com/blackoutsecure/.github/blob/main/SECURITY.md)
for the reporting process. Report privately via
[GitHub Security Advisories](https://github.com/blackoutsecure/bos-nginx-config-validator/security/advisories/new).

## 🐛 Troubleshooting

### `nginx: [emerg] open() "/etc/nginx/modules/..." failed`

You picked an image that lacks the modules tree your `nginx.conf`
references. The default LSIO image ships brotli, dav_ext, echo,
fancyindex, devel_kit, geoip2, headers_more, and others. The official
`docker.io/library/nginx:1.27-alpine` is minimal — if you need extra
modules, switch back to the LSIO default or pin to a custom image.

### `nginx: [emerg] host not found in upstream "..."`

`nginx -t` resolves literal hostnames in `proxy_pass http://hostname;`
at config-load time — *not* at request time. If the rendered hostname
isn't resolvable from inside the validation container (e.g. it's a
Kubernetes service, a Docker network alias, or a private DNS name),
`nginx -t` will fail.

Four fixes, in order of preference:

1. **Do nothing — the action's auto-fill already handles this** for
   undeclared `${UPPERCASE_VAR}` references: they're filled with
   `127.0.0.1` (resolvable everywhere) and a `::warning::` annotation
   lists what was filled. See [auto-fill behavior](#auto-fill-behavior).
2. **Defer resolution to request time by assigning the hostname to a
   variable** before `proxy_pass`. nginx only does startup resolution
   for literal hostnames:
   ```nginx
   set $upstream "${UPSTREAM_HOST}";
   proxy_pass http://$upstream:8000;
   ```
3. **In CI, supply a resolvable value** for `template_vars`
   (e.g. `UPSTREAM_HOST=127.0.0.1`) — different from your production
   value, but enough to satisfy `nginx -t`. This silences the auto-fill
   warning.
4. **Define a `resolver`** in your `nginx.conf` and use a variable in
   `proxy_pass` (as in fix #2).

This is standard nginx behaviour, identical across the LSIO default
and the official `docker.io/library/nginx` image.

### `::warning:: auto-filled N undeclared template var(s) ...`

The action found `${UPPERCASE_VAR}` references in your templates that
weren't declared in `template_vars`. They were auto-filled with the
`auto_fill_unknown_vars` value (default `'127.0.0.1'`) so validation
could proceed. To silence the warning, **either** add the listed keys
to `template_vars` with real values **or** opt out of auto-fill with
`auto_fill_unknown_vars: ''` and rely on `nginx -t` to fail on
undeclared keys.

### `nginx: [emerg] unknown directive "..."`

Either the directive really is wrong, **or** an unrendered template
variable left a stray `${VAR}` in a directive name. Check that every
`${KEY}` referenced in your templates appears in `template_vars`.

### `template_vars KEY must match [A-Za-z_][A-Za-z0-9_]*`

`envsubst` only accepts shell-identifier-shaped keys. Rename the key
in both the template and `template_vars`.

### My nginx variable `$remote_addr` got blanked out

You added `remote_addr=...` to `template_vars`. Remove it — anything
that's NOT in `template_vars` passes through to nginx unchanged, which
is exactly what you want for nginx-native vars.

### `templates_path '...' must not contain '..'`

Path-traversal guard. Move your config inside the workspace and pass
a clean relative path.

### Docker pull is slow

After the first run on a runner, the nginx image is cached in the
runner's layer cache and subsequent runs reuse it. On GitHub-hosted
runners the cache is per-runner-image-version.

## 🤝 Contributing

Contributions welcome — see [CONTRIBUTING.md](CONTRIBUTING.md).

## 📄 License

Copyright © 2025-2026 Blackout Secure

Licensed under the Apache License, Version 2.0. See [LICENSE](LICENSE) for
details.

## 💬 Support

- **Issues**: [GitHub Issues](https://github.com/blackoutsecure/bos-nginx-config-validator/issues)
- **Security**: see the organization-wide [Security Policy](https://github.com/blackoutsecure/.github/blob/main/SECURITY.md) and report via [GitHub Security Advisories](https://github.com/blackoutsecure/bos-nginx-config-validator/security/advisories/new)

## 🔗 Related

- [bos-upstream-watcher](https://github.com/blackoutsecure/bos-upstream-watcher)
  — detect upstream version changes from GitHub Releases, npm, PyPI,
  Docker Hub, or any URL.
- [bos-sitemap-generator](https://github.com/blackoutsecure/bos-sitemap-generator)
  — automated XML/TXT/GZIP sitemaps for static sites and SSG frameworks.
- [bos-automation-hub](https://github.com/blackoutsecure/bos-automation-hub)
  — reusable workflows for container builds, Balena deploys, GitHub
  Releases, and Cloudflare Pages.

---

**Made with care by [Blackout Secure](https://github.com/blackoutsecure)**
