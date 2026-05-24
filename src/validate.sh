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
AUTO_FILL_UNKNOWN_VARS="${AUTO_FILL_UNKNOWN_VARS-127.0.0.1}"
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

# ── Auto-fill: ${UPPERCASE_VAR} tokens missing from template_vars ─────────
# Why: the single most common validation failure is an unresolved
# `${UPSTREAM_HOST}` (or similar) in `proxy_pass http://${HOST}:port;` —
# `nginx -t` resolves literal upstream hostnames at config-load time, and
# an empty expansion (no template_vars entry) yields a syntax error
# *before* nginx can complain about DNS. Auto-filling missing keys with
# a safe-for-most-cases value (default `127.0.0.1`) makes the common
# case validate out-of-the-box, with a loud WARNING listing exactly
# what was filled so authors know to declare the keys explicitly.
#
# Convention: the heuristic targets `${UPPERCASE_VAR}` only. Nginx's
# own variables (`${remote_addr}`, `${host}`, `${proxy_add_x_forwarded_for}`,
# …) are all lowercase — the case-split keeps us from masking native
# variables. Users wanting lowercase envsubst keys must declare them in
# `template_vars` explicitly.
#
# Opt-out: setting `AUTO_FILL_UNKNOWN_VARS=''` disables scanning. In
# that mode, undeclared `${UPPERCASE_VAR}` tokens pass through to nginx
# untouched and surface as parse errors — the previous strict behavior.
auto_filled=()
if [ "${templates_mount}" = "yes" ] && [ -n "${AUTO_FILL_UNKNOWN_VARS}" ]; then
    # Gather every ${UPPERCASE_NAME} referenced in any template, dedup.
    # `|| true` so an empty grep (no matches) doesn't trip `set -e`.
    referenced_vars="$(grep -hoE '\$\{[A-Z][A-Z0-9_]*\}' "${templates_abs}"/*.conf.template 2>/dev/null \
        | sort -u \
        | sed -E 's/^\$\{(.+)\}$/\1/' \
        || true)"
    if [ -n "${referenced_vars}" ]; then
        while IFS= read -r ref; do
            [ -z "${ref}" ] && continue
            # Skip if already declared in template_vars.
            declared="no"
            if [ "${#var_names[@]}" -gt 0 ]; then
                for d in "${var_names[@]}"; do
                    if [ "${d}" = "\${${ref}}" ]; then
                        declared="yes"
                        break
                    fi
                done
            fi
            if [ "${declared}" = "no" ]; then
                var_names+=("\${${ref}}")
                docker_env_args+=(-e "${ref}=${AUTO_FILL_UNKNOWN_VARS}")
                auto_filled+=("${ref}")
            fi
        done <<< "${referenced_vars}"
        # Rebuild envsubst_keys so the auto-filled tokens are passed to envsubst.
        if [ "${#var_names[@]}" -gt 0 ]; then
            envsubst_keys="${var_names[*]}"
        fi
    fi
fi

if [ "${#auto_filled[@]}" -gt 0 ]; then
    echo "::warning::nginx-config-validator: auto-filled ${#auto_filled[@]} undeclared template var(s) with '${AUTO_FILL_UNKNOWN_VARS}': ${auto_filled[*]}"
    echo "nginx-config-validator:   declare these in template_vars to silence this warning, or set auto_fill_unknown_vars: '' for strict mode"
elif [ "${templates_mount}" = "yes" ] && [ -z "${AUTO_FILL_UNKNOWN_VARS}" ]; then
    echo "nginx-config-validator: auto-fill disabled (auto_fill_unknown_vars is empty) — undeclared \${UPPERCASE_VAR} tokens will pass through to nginx"
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
        echo "nginx-config-validator: envsubst not found in ${NGINX_IMAGE_IN} — attempting auto-install (gettext)"
        if   command -v apk     >/dev/null 2>&1; then apk add --no-cache gettext            >/dev/null 2>&1 || true
        elif command -v apt-get >/dev/null 2>&1; then apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq gettext-base >/dev/null 2>&1 || true
        elif command -v dnf     >/dev/null 2>&1; then dnf install -y -q gettext           >/dev/null 2>&1 || true
        elif command -v yum     >/dev/null 2>&1; then yum install -y -q gettext           >/dev/null 2>&1 || true
        fi
        if ! command -v envsubst >/dev/null 2>&1; then
            echo "::error::nginx-config-validator: envsubst missing from image ${NGINX_IMAGE_IN} and auto-install failed. Pick an image that ships gettext, or build a custom image that includes it." >&2
            exit 2
        fi
        echo "nginx-config-validator: envsubst installed via package manager"
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
# `-e stderr` overrides the compile-time default error-log path. Without
# it, the LSIO image (which has CMD `nginx -g daemon off;` and a default
# of `/var/lib/nginx/logs/error.log`, owned by the nginx user) emits a
# cosmetic "[alert] could not open error log file" before parsing the
# user config — confusing in CI output. Granting DAC_OVERRIDE would
# silence it but defeats half the cap-drop hardening; `-e stderr` is the
# narrowly-scoped fix. The error_log directive inside nginx.conf still
# takes precedence at runtime, so this affects only the pre-config-parse
# early log path.
nginx -t -e stderr -c /etc/nginx/nginx.conf
'

docker_env_args+=(
    -e "TEMPLATES_TARGET_DIR_IN=${TEMPLATES_TARGET_DIR}"
    -e "ENVSUBST_KEYS_IN=${envsubst_keys}"
    -e "NGINX_IMAGE_IN=${NGINX_IMAGE}"
)

# ── Hardening probe: detect envsubst presence ───────────────────────────
# Why: a fully-locked-down container (--read-only + cap-drop=ALL +
# no-new-privileges) breaks the auto-install path because `apk add`
# needs to write binaries to /usr/{bin,sbin,lib}, which is RO when
# --read-only is set. We probe the image with the strictest possible
# settings — if envsubst is already on PATH, we get full lockdown for
# the main run; if it's missing, we drop --read-only (still apply every
# other hardening flag) so the auto-install can land gettext.
#
# The probe itself runs under maximum lockdown: read-only root, no
# network, cap-drop=ALL, no-new-privs, 4 MiB tmpfs /tmp, 64 MiB memory,
# 16 PID limit. `command -v` is a shell builtin so no binaries execute.
# shellcheck disable=SC2054 # docker tmpfs uses comma-separated options
probe_hardening=(
    --read-only
    --tmpfs /tmp:rw,noexec,nosuid,size=4m
    --cap-drop=ALL
    --security-opt=no-new-privileges:true
    --pids-limit=16
    --memory=64m
    --memory-swap=64m
    --network=none
)
if "${DOCKER_BIN}" run --rm \
        --entrypoint sh \
        "${probe_hardening[@]}" \
        "${NGINX_IMAGE}" \
        -c 'command -v envsubst >/dev/null 2>&1' >/dev/null 2>&1; then
    envsubst_present="yes"
else
    envsubst_present="no"
fi

# Hardening flags applied to every validation run, regardless of probe.
# Justification per flag:
#   --cap-drop=ALL                drop every Linux capability …
#   --cap-add=CHOWN               … then re-add only CHOWN, which
#                                 `nginx -t` needs to chown its
#                                 client_body_temp_path / proxy_temp_path
#                                 dirs to the configured worker user
#                                 (UID 101 on alpine-based images).
#                                 Without it, `nginx -t` fails with
#                                 `chown(...) failed (1: Operation not
#                                 permitted)` even on otherwise-valid
#                                 configs.
#   --security-opt=no-new-privs   block setuid/sudo escalation paths.
#   --pids-limit=64               cap process count; defend against
#                                 fork-bomb-shaped bugs.
#   --memory / --memory-swap      cap RAM at 512 MiB and disable swap.
#   --hostname=nginx-validator    obscure host identity inside container.
#   --tmpfs /tmp                  writable but noexec + nosuid; needed
#                                 for nginx -t temp path setup.
#   --tmpfs /run                  writable, noexec, nosuid; shadows
#                                 LSIO's pre-created /run/nginx (owned
#                                 by nginx:nginx, which the dropped
#                                 DAC_OVERRIDE cap would otherwise
#                                 prevent us from writing to) and is
#                                 where rendered template configs land.
# shellcheck disable=SC2054 # docker tmpfs uses comma-separated options
hardening_args=(
    --cap-drop=ALL
    --cap-add=CHOWN
    --security-opt=no-new-privileges:true
    --pids-limit=64
    --memory=512m
    --memory-swap=512m
    --hostname=nginx-validator
    --tmpfs /tmp:rw,noexec,nosuid,size=64m
    --tmpfs /run:rw,noexec,nosuid,size=16m
)

if [ "${envsubst_present}" = "yes" ]; then
    # Full lockdown: root FS is read-only. Combined with the tmpfs
    # mounts above, nothing outside /tmp and /run can be modified.
    hardening_args+=(--read-only)
    hardening_mode="full (--read-only + tmpfs + cap-drop=ALL + no-new-privs)"
else
    # Auto-install path: writable root needed so `apk add` / `apt-get
    # install` can land envsubst under /usr. Every other hardening flag
    # above still applies (cap-drop, no-new-privs, pid/memory limits,
    # tmpfs /tmp + /run).
    hardening_mode="standard (cap-drop=ALL + no-new-privs; root FS writable so envsubst auto-install can succeed)"
fi
echo "nginx-config-validator: hardening = ${hardening_mode}"

# `--entrypoint sh` overrides the image's docker-entrypoint.sh (which would
# otherwise spawn nginx in the foreground rather than running our script).
echo "::group::nginx -t output"
if "${DOCKER_BIN}" run --rm \
    --entrypoint sh \
    "${hardening_args[@]}" \
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
