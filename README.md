# Blackout Secure Nginx Config Validate

**Copyright © 2025-2026 Blackout Secure | Apache License 2.0**

[![Marketplace](https://img.shields.io/badge/GitHub%20Marketplace-blue?logo=github)](https://github.com/marketplace/actions/blackout-secure-nginx-config-validate)
[![GitHub release](https://img.shields.io/github/v/release/blackoutsecure/bos-nginx-config-validate?sort=semver)](https://github.com/blackoutsecure/bos-nginx-config-validate/releases)
[![License](https://img.shields.io/badge/license-Apache%202.0-blue)](LICENSE)

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

      - uses: blackoutsecure/bos-nginx-config-validate@v1
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
- uses: blackoutsecure/bos-nginx-config-validate@v1
  with:
    config_path: conf/nginx.conf
    templates_path: ''   # disable template rendering entirely
```

### 2. Custom layout under `deploy/`

```yaml
- uses: blackoutsecure/bos-nginx-config-validate@v1
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
  uses: blackoutsecure/bos-nginx-config-validate@v1
  with:
    config_path: services/frontend/nginx/nginx.conf
    templates_path: services/frontend/nginx/http.d
    template_vars: |
      FRONTEND_PORT=8080

- name: Validate api nginx
  uses: blackoutsecure/bos-nginx-config-validate@v1
  with:
    config_path: services/api/nginx/nginx.conf
    templates_path: services/api/nginx/http.d
    template_vars: |
      API_PORT=9000
      UPSTREAM_HOST=api-backend
```

### 4. Pinning a specific nginx image

```yaml
- uses: blackoutsecure/bos-nginx-config-validate@v1
  with:
    nginx_image: docker.io/library/nginx:1.27.2-alpine
    template_vars: |
      APP_PORT=8080
```

Tip: pin to a major + flavor (e.g. `1.27-alpine`) and let Dependabot's
`docker` ecosystem bump the digest. Add this to your `.github/dependabot.yml`:

```yaml
- package-ecosystem: docker
  directory: /
  schedule:
    interval: weekly
```

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
- uses: blackoutsecure/bos-nginx-config-validate@v1
  with:
    template_vars: |
      APP_PORT=8080
    # $proxy_add_x_forwarded_for and $remote_addr are NOT in template_vars,
    # so they pass through to nginx unchanged. Only ${APP_PORT} is replaced.
```

## ⚙️ Inputs

| Input | Default | Description |
|---|---|---|
| `config_path` | `root/etc/nginx/nginx.conf` | Repo-relative path to `nginx.conf`. |
| `templates_path` | `root/etc/nginx/http.d` | Repo-relative directory of `*.conf.template` files. Empty / missing disables template rendering. |
| `template_vars` | `''` | Newline-separated `KEY=VALUE` pairs passed to `envsubst`. Only the listed keys are substituted. |
| `templates_target_dir` | `/run/nginx/http.d` | Absolute path inside the container where rendered templates land. Must match the `include` directive in `nginx.conf`. |
| `nginx_image` | `docker.io/library/nginx:1.27-alpine` | Container image used for validation. |

### `template_vars` shape

- One `KEY=VALUE` per line.
- Keys must match `[A-Za-z_][A-Za-z0-9_]*`.
- Blank lines and lines starting with `#` are ignored.
- Values may not contain newlines.
- Values are passed via `docker run -e KEY=VALUE`; quoting is not needed.

```yaml
template_vars: |
  # comments are allowed
  APP_PORT=8080
  UPSTREAM_HOST=backend.internal
  STATIC_ROOT=/srv/www
```

## 📤 Outputs

| Output | Description |
|---|---|
| `validated` | `true` when `nginx -t` exits 0. The step fails before this is written on a validation error, so consumers can rely on it being either `true` or absent. |

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

See [SECURITY.md](SECURITY.md) for the reporting process.

## 🐛 Troubleshooting

### `nginx: [emerg] open() "/etc/nginx/modules/..." failed`

You probably picked a stripped-down image that lacks the modules tree.
Switch back to the default `nginx:1.27-alpine`, or pick an image that
ships the modules your `nginx.conf` references.

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

- **Issues**: [GitHub Issues](https://github.com/blackoutsecure/bos-nginx-config-validate/issues)
- **Security**: see [SECURITY.md](SECURITY.md)

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
