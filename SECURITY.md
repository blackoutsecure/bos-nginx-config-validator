# Security Policy

## Reporting Security Vulnerabilities

**Do not open public GitHub issues for security vulnerabilities.**

Report privately via
**[GitHub Security Advisories](https://github.com/blackoutsecure/bos-nginx-config-validate/security/advisories/new)**
("Report a vulnerability"). This delivers the report to maintainers only
and provides a coordinated disclosure workflow.

Please include:

- A description of the vulnerability
- Steps to reproduce (a minimal caller workflow is ideal)
- Potential impact
- Suggested remediation (if any)

We acknowledge all security reports within **3 business days** and aim to
provide a remediation plan or disposition within **14 days**.

## Security best practices

### When using this action

1. **Pin to a major version tag**, never to `main`:

   ```yaml
   - uses: blackoutsecure/bos-nginx-config-validate@v1
   ```

   For audit-grade pinning, use the commit SHA:

   ```yaml
   - uses: blackoutsecure/bos-nginx-config-validate@<full-sha>  # v1.0.0
   ```

2. **Restrict workflow permissions**. The action itself only needs the
   default `contents: read`:

   ```yaml
   permissions:
     contents: read
   ```

3. **Pin the nginx image**. The default tracks a major + flavor
   (`1.27-alpine`) so Dependabot's `docker` ecosystem can bump it.
   Pin to a digest for the strongest guarantee:

   ```yaml
   - uses: blackoutsecure/bos-nginx-config-validate@v1
     with:
       nginx_image: docker.io/library/nginx@sha256:<digest>
   ```

4. **Treat `template_vars` values as data, not code**. Values are forwarded
   to the container via `docker run -e KEY=VALUE`. They are not subject
   to shell expansion on the runner, but downstream tooling that consumes
   the rendered templates should still avoid passing user-controlled data
   into shell or template-engine contexts without proper escaping.

5. **Do not put secrets in `template_vars`**. Templates are validation
   artifacts only — placeholder values are sufficient for `nginx -t`.
   Putting a real secret here exposes it to anyone who can read the
   workflow logs.

## Trust boundaries

| Boundary | Treatment |
|---|---|
| All `inputs.*` | Forwarded via `env:`; never interpolated into `run:` bodies |
| `config_path`, `templates_path` | Rejected if absolute or containing `..` |
| `templates_target_dir` | Must be absolute (in-container path) |
| `template_vars` keys | Validated against `[A-Za-z_][A-Za-z0-9_]*` |
| `template_vars` values | Newlines rejected; forwarded only via `docker run -e` |
| `nginx_image` | Single-line non-empty image ref required |
| Repo mounts | `nginx.conf` and templates mounted read-only into the container |

## Supported versions

| Version | Status |
|---|---|
| `1.x` | Active |

## Dependencies

This action is **bash + Docker only**. No `pip install`, no `npm install`,
no third-party runtime dependencies. The validation container is the
upstream `nginx` image of your choice (default
`docker.io/library/nginx:1.27-alpine`).

## Vulnerability scanning

- Dependabot watches the `github-actions` ecosystem in this repo.
- Workflows and shell scripts are linted by `actionlint` and `shellcheck`
  on every push.

## Related files

- [LICENSE](./LICENSE) — Apache License 2.0
- [NOTICE](./NOTICE) — Third-party attribution

---

For security-related questions, open a GitHub Security Advisory at the
link above.
