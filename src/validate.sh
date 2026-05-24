#!/usr/bin/env bash
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Blackout Secure Nginx Config Validator — validation script
# Copyright © 2025-2026 Blackout Secure
# Licensed under Apache License 2.0
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#
# Reads inputs from the env vars set by the composite action's `env:` block,
# validates them, renders any `*.conf.template` files via `envsubst`, then
# runs `nginx -t -c /etc/nginx/nginx.conf` inside the requested nginx image.
#
# Required env vars (all set by action.yml):
#   CONFIG_PATH            Repo-relative path to nginx.conf.
#   TEMPLATES_PATH         Repo-relative path to *.conf.template directory.
#   TEMPLATE_VARS          Newline-separated KEY=VALUE pairs.
#   TEMPLATES_TARGET_DIR   Absolute path inside the container.
#   NGINX_IMAGE            Container image reference.
#
# Optional env vars (mainly for tests):
#   GITHUB_OUTPUT          Path to the GitHub Actions output file. When
#                          unset (e.g. local invocation), output writes
#                          are skipped silently.
#   DOCKER_BIN             Override the docker binary (default: docker).

set -euo pipefail

die() {
    echo "::error::nginx-config-validator: $*" >&2
    exit 1
}

emit_output() {
    # $1 = key, $2 = value. No-op when GITHUB_OUTPUT is unset.
    if [ -n "${GITHUB_OUTPUT:-}" ]; then
        printf '%s=%s\n' "$1" "$2" >> "${GITHUB_OUTPUT}"
    fi
}

# All inputs are set by action.yml's `env:` block. Treat them as
# possibly-empty strings here so the case-based checks below can produce
# user-friendly error messages (instead of bash's parameter-expansion
# error).
CONFIG_PATH="${CONFIG_PATH:-}"
TEMPLATES_PATH="${TEMPLATES_PATH:-}"
TEMPLATE_VARS="${TEMPLATE_VARS:-}"
TEMPLATES_TARGET_DIR="${TEMPLATES_TARGET_DIR:-}"
NGINX_IMAGE="${NGINX_IMAGE:-}"
DOCKER_BIN="${DOCKER_BIN:-docker}"

# ── Input shape validation ──────────────────────────────────────────────
case "${CONFIG_PATH}" in
    '')   die "input 'config_path' must be non-empty" ;;
    /*)   die "input 'config_path' must be repo-relative (got absolute: '${CONFIG_PATH}')" ;;
    *..*) die "input 'config_path' must not contain '..' (got: '${CONFIG_PATH}')" ;;
esac

case "${TEMPLATES_PATH}" in
    /*)   die "input 'templates_path' must be repo-relative (got absolute: '${TEMPLATES_PATH}')" ;;
    *..*) die "input 'templates_path' must not contain '..' (got: '${TEMPLATES_PATH}')" ;;
esac

case "${TEMPLATES_TARGET_DIR}" in
    /*) ;;  # absolute is required for the in-container target
    *)  die "input 'templates_target_dir' must be absolute (got: '${TEMPLATES_TARGET_DIR}')" ;;
esac

case "${NGINX_IMAGE}" in
    ''|*$'\n'*) die "input 'nginx_image' must be a single-line non-empty image ref" ;;
esac

if [ ! -f "${CONFIG_PATH}" ]; then
    die "config_path '${CONFIG_PATH}' does not exist or is not a file"
fi

# ── Parse template_vars into a KEY list + docker -e args ────────────────
# Passing envsubst a positional list of `${KEY}` tokens limits substitution
# to just those keys; every other `${...}` in the template passes through
# verbatim, which is what protects nginx-native variables like
# `$remote_addr` from being silently blanked.
var_names=()
docker_env_args=()
while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -z "${line}" ] && continue
    case "${line}" in
        '#'*) continue ;;
    esac
    case "${line}" in
        *=*) ;;
        *)   die "template_vars entry must be KEY=VALUE (got: '${line}')" ;;
    esac
    k="${line%%=*}"
    v="${line#*=}"
    case "${k}" in
        ''|*[!A-Za-z0-9_]*)
            die "template_vars KEY must match [A-Za-z_][A-Za-z0-9_]* (got: '${k}')" ;;
    esac
    case "${k}" in
        [0-9]*) die "template_vars KEY must not start with a digit (got: '${k}')" ;;
    esac
    case "${v}" in
        *$'\n'*) die "template_vars value for '${k}' must not contain newlines" ;;
    esac
    var_names+=("\${${k}}")
    docker_env_args+=(-e "${k}=${v}")
done <<< "${TEMPLATE_VARS}"

envsubst_keys=""
if [ "${#var_names[@]}" -gt 0 ]; then
    envsubst_keys="${var_names[*]}"
fi

echo "::group::nginx-config-validator: inputs"
echo "  config_path:          ${CONFIG_PATH}"
echo "  templates_path:       ${TEMPLATES_PATH:-(none)}"
echo "  templates_target_dir: ${TEMPLATES_TARGET_DIR}"
echo "  nginx_image:          ${NGINX_IMAGE}"
if [ "${#var_names[@]}" -gt 0 ]; then
    echo "  template_vars (keys): ${envsubst_keys}"
else
    echo "  template_vars:        (none — templates rendered with empty substitutions)"
fi
echo "::endgroup::"

# ── Build docker run argv ───────────────────────────────────────────────
config_abs="$(cd "$(dirname "${CONFIG_PATH}")" && pwd)/$(basename "${CONFIG_PATH}")"
mount_args=(-v "${config_abs}:/etc/nginx/nginx.conf:ro")

templates_mount=""
if [ -n "${TEMPLATES_PATH}" ] && [ -d "${TEMPLATES_PATH}" ]; then
    templates_abs="$(cd "${TEMPLATES_PATH}" && pwd)"
    tmpl_count="$(find "${templates_abs}" -maxdepth 1 -type f -name '*.conf.template' | wc -l | tr -d '[:space:]')"
    if [ "${tmpl_count}" -gt 0 ]; then
        mount_args+=(-v "${templates_abs}:/templates:ro")
        templates_mount="yes"
        echo "nginx-config-validator: found ${tmpl_count} template(s) to render"
    else
        echo "nginx-config-validator: no *.conf.template files in '${TEMPLATES_PATH}' — skipping template render"
    fi
else
    echo "nginx-config-validator: templates_path '${TEMPLATES_PATH:-(empty)}' missing or empty — skipping template render"
fi

# ── In-container script ─────────────────────────────────────────────────
# `envsubst` ships with the official nginx images (Debian and Alpine flavours)
# as part of the `gettext-base` / `gettext` package and is used at runtime by
# the image's own /docker-entrypoint.d scripts.
# shellcheck disable=SC2016 # variables expand inside the container, not here
in_container_script='
set -eu

# nginx.conf often references these temp paths — create them so any
# post-`nginx -t` warnings about unwritable paths are suppressed.
mkdir -p /run/nginx /tmp/nginx-client-body /tmp/nginx-proxy-temp \
    /tmp/nginx-fastcgi-temp /tmp/nginx-uwsgi-temp /tmp/nginx-scgi-temp

if [ -n "${TEMPLATES_TARGET_DIR_IN:-}" ]; then
    mkdir -p "${TEMPLATES_TARGET_DIR_IN}"
fi

if [ -d /templates ]; then
    if ! command -v envsubst >/dev/null 2>&1; then
        echo "::error::nginx-config-validator: envsubst missing from image ${NGINX_IMAGE_IN}" >&2
        exit 2
    fi
    for tmpl in /templates/*.conf.template; do
        [ -e "${tmpl}" ] || continue
        out="${TEMPLATES_TARGET_DIR_IN}/$(basename "${tmpl%.template}")"
        if [ -n "${ENVSUBST_KEYS_IN}" ]; then
            # shellcheck disable=SC2016
            envsubst "${ENVSUBST_KEYS_IN}" < "${tmpl}" > "${out}"
        else
            # No keys supplied: copy unchanged so any unresolved ${VAR}
            # surfaces clearly via the subsequent `nginx -t`.
            cp "${tmpl}" "${out}"
        fi
        echo "rendered: ${tmpl} -> ${out}"
    done
fi

echo "--- nginx -t ---"
nginx -t -c /etc/nginx/nginx.conf
'

docker_env_args+=(
    -e "TEMPLATES_TARGET_DIR_IN=${TEMPLATES_TARGET_DIR}"
    -e "ENVSUBST_KEYS_IN=${envsubst_keys}"
    -e "NGINX_IMAGE_IN=${NGINX_IMAGE}"
)

# `--entrypoint sh` overrides the image's docker-entrypoint.sh (which would
# otherwise spawn nginx in the foreground rather than running our script).
echo "::group::nginx -t output"
if "${DOCKER_BIN}" run --rm \
    --entrypoint sh \
    "${mount_args[@]}" \
    "${docker_env_args[@]}" \
    "${NGINX_IMAGE}" \
    -c "${in_container_script}"; then
    echo "::endgroup::"
    emit_output "validated" "true"
    echo "nginx-config-validator: ✓ nginx -t passed"
else
    rc=$?
    echo "::endgroup::"
    emit_output "validated" "false"
    die "nginx -t failed (exit ${rc}). See grouped output above. templates_mount=${templates_mount:-no}"
fi
