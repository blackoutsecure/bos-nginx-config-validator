# Contributing to Blackout Secure Nginx Config Validate

Thank you for your interest in contributing.

## Getting started

1. Fork the repository.
2. Clone your fork:
   `git clone https://github.com/your-username/bos-nginx-config-validate.git`
3. Create a feature branch: `git checkout -b feat/your-feature`.
4. Install local tooling (all optional, but recommended):
   - [`shellcheck`](https://www.shellcheck.net/) — `brew install shellcheck` / `apt install shellcheck`
   - [`actionlint`](https://github.com/rhysd/actionlint) — `brew install actionlint`
   - [`bats-core`](https://github.com/bats-core/bats-core) — `brew install bats-core`
   - Docker (for end-to-end validation against the real nginx image)

The action itself is **bash + Docker only**. No runtime dependencies are
shipped with it.

## Development

### Run the script directly

```bash
GITHUB_OUTPUT=/tmp/gh-out \
CONFIG_PATH=test/fixtures/basic/nginx.conf \
TEMPLATES_PATH=test/fixtures/basic/http.d \
TEMPLATES_TARGET_DIR=/run/nginx/http.d \
NGINX_IMAGE=docker.io/library/nginx:1.27-alpine \
TEMPLATE_VARS=$'APP_PORT=8080\nUPSTREAM_HOST=127.0.0.1' \
bash src/validate.sh
```

### Lint

```bash
shellcheck src/validate.sh
actionlint
```

### Run the test suite

```bash
bats test/
```

Tests that require Docker are tagged and skipped automatically when
Docker is not available.

## Pull request process

1. Add a test for any new behaviour (`test/`).
2. Run `bats test/` and `shellcheck src/validate.sh` locally.
3. Update `README.md` if you add or change an input/output.
4. Open the PR with a clear description of the change and the motivation.

## Code style

- Follow the existing bash style (`set -euo pipefail`, `[ ]` over `[[ ]]`
  except where a feature requires it, 4-space indent — matches
  `.editorconfig`).
- Inputs flow through `env:`; never interpolate inputs into `run:` bodies.
- Validate path inputs against `..` and absolute prefixes.
- Wrap noisy output in `::group::` / `::endgroup::` so the workflow log
  stays readable.

## Reporting issues

- Use [GitHub Issues](https://github.com/blackoutsecure/bos-nginx-config-validate/issues)
  for bug reports.
- Include the failing run URL, sanitized inputs, and the relevant section
  of your `nginx.conf` if applicable.
- For security issues, see [SECURITY.md](./SECURITY.md).

## License

By contributing, you agree that your contributions will be licensed under
the Apache License 2.0.
