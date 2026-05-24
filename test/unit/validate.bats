#!/usr/bin/env bats
# Unit tests for src/validate.sh. These tests stub the docker binary via
# the DOCKER_BIN env var so they run anywhere bash is available — no
# Docker daemon required.

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    SCRIPT="${REPO_ROOT}/src/validate.sh"
    FIXTURES="${REPO_ROOT}/test/fixtures"

    # Per-test scratch dir for fake docker stubs and GITHUB_OUTPUT.
    TMP="$(mktemp -d)"
    export GITHUB_OUTPUT="${TMP}/gh-out"
    : > "${GITHUB_OUTPUT}"

    # Fake docker that always succeeds and records its argv for inspection.
    FAKE_DOCKER="${TMP}/docker"
    cat > "${FAKE_DOCKER}" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "${TMP}/docker-argv"
exit 0
EOF
    chmod +x "${FAKE_DOCKER}"
    export DOCKER_BIN="${FAKE_DOCKER}"

    # Sensible defaults; individual tests override as needed.
    export CONFIG_PATH="test/fixtures/basic/nginx.conf"
    export TEMPLATES_PATH="test/fixtures/basic/http.d"
    export TEMPLATES_TARGET_DIR="/run/nginx/http.d"
    export NGINX_IMAGE="docker.io/library/nginx:1.27-alpine"
    export TEMPLATE_VARS=""
}

teardown() {
    rm -rf "${TMP}"
}

# ─── Input validation: paths ─────────────────────────────────────────────

@test "rejects absolute config_path" {
    export CONFIG_PATH="/etc/nginx/nginx.conf"
    cd "${REPO_ROOT}"
    run bash "${SCRIPT}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"must be repo-relative"* ]]
}

@test "rejects config_path with .." {
    export CONFIG_PATH="../etc/nginx/nginx.conf"
    cd "${REPO_ROOT}"
    run bash "${SCRIPT}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"must not contain '..'"* ]]
}

@test "rejects empty config_path" {
    export CONFIG_PATH=""
    cd "${REPO_ROOT}"
    run bash "${SCRIPT}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"must be non-empty"* ]]
}

@test "rejects missing config_path file" {
    export CONFIG_PATH="does/not/exist/nginx.conf"
    cd "${REPO_ROOT}"
    run bash "${SCRIPT}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"does not exist"* ]]
}

@test "rejects absolute templates_path" {
    export TEMPLATES_PATH="/etc/nginx/http.d"
    cd "${REPO_ROOT}"
    run bash "${SCRIPT}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"templates_path"* ]]
    [[ "${output}" == *"must be repo-relative"* ]]
}

@test "rejects templates_path with .." {
    export TEMPLATES_PATH="../etc/nginx/http.d"
    cd "${REPO_ROOT}"
    run bash "${SCRIPT}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"templates_path"* ]]
    [[ "${output}" == *"must not contain '..'"* ]]
}

@test "rejects relative templates_target_dir" {
    export TEMPLATES_TARGET_DIR="relative/path"
    cd "${REPO_ROOT}"
    run bash "${SCRIPT}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"templates_target_dir"* ]]
    [[ "${output}" == *"must be absolute"* ]]
}

@test "rejects empty nginx_image" {
    export NGINX_IMAGE=""
    cd "${REPO_ROOT}"
    run bash "${SCRIPT}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"nginx_image"* ]]
    [[ "${output}" == *"single-line non-empty"* ]]
}

# ─── Input validation: template_vars ─────────────────────────────────────

@test "rejects template_vars entry without =" {
    export TEMPLATE_VARS="APP_PORT"
    cd "${REPO_ROOT}"
    run bash "${SCRIPT}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"must be KEY=VALUE"* ]]
}

@test "rejects template_vars key starting with digit" {
    export TEMPLATE_VARS="1BAD=value"
    cd "${REPO_ROOT}"
    run bash "${SCRIPT}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"must not start with a digit"* ]]
}

@test "rejects template_vars key with invalid character" {
    export TEMPLATE_VARS="BAD-KEY=value"
    cd "${REPO_ROOT}"
    run bash "${SCRIPT}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"KEY must match"* ]]
}

@test "accepts template_vars with comments and blank lines" {
    export TEMPLATE_VARS=$'# leading comment\n\nAPP_PORT=8080\n  \nUPSTREAM_HOST=127.0.0.1\n'
    cd "${REPO_ROOT}"
    run bash "${SCRIPT}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"APP_PORT"* ]]
    [[ "${output}" == *"UPSTREAM_HOST"* ]]
}

@test "tolerates underscore-led and mixed-case keys" {
    export TEMPLATE_VARS=$'_PRIVATE=ok\nMixedCase=ok'
    cd "${REPO_ROOT}"
    run bash "${SCRIPT}"
    [ "${status}" -eq 0 ]
}

# ─── docker invocation ───────────────────────────────────────────────────

@test "writes validated=true to GITHUB_OUTPUT on success" {
    cd "${REPO_ROOT}"
    run bash "${SCRIPT}"
    [ "${status}" -eq 0 ]
    grep -qx 'validated=true' "${GITHUB_OUTPUT}"
}

@test "writes validated=false to GITHUB_OUTPUT on docker failure" {
    # Replace the fake docker with one that fails.
    cat > "${DOCKER_BIN}" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
    chmod +x "${DOCKER_BIN}"
    cd "${REPO_ROOT}"
    run bash "${SCRIPT}"
    [ "${status}" -ne 0 ]
    grep -qx 'validated=false' "${GITHUB_OUTPUT}"
}

@test "docker argv mounts config_path read-only at /etc/nginx/nginx.conf" {
    cd "${REPO_ROOT}"
    run bash "${SCRIPT}"
    [ "${status}" -eq 0 ]
    grep -q ":/etc/nginx/nginx.conf:ro" "${TMP}/docker-argv"
}

@test "docker argv mounts templates dir read-only at /templates when present" {
    cd "${REPO_ROOT}"
    run bash "${SCRIPT}"
    [ "${status}" -eq 0 ]
    grep -q ":/templates:ro" "${TMP}/docker-argv"
}

@test "docker argv forwards template_vars via -e KEY=VALUE" {
    export TEMPLATE_VARS=$'APP_PORT=8080\nUPSTREAM_HOST=127.0.0.1'
    cd "${REPO_ROOT}"
    run bash "${SCRIPT}"
    [ "${status}" -eq 0 ]
    grep -qx 'APP_PORT=8080' "${TMP}/docker-argv"
    grep -qx 'UPSTREAM_HOST=127.0.0.1' "${TMP}/docker-argv"
}

@test "docker argv uses the requested nginx_image" {
    export NGINX_IMAGE="docker.io/library/nginx:1.25-alpine"
    cd "${REPO_ROOT}"
    run bash "${SCRIPT}"
    [ "${status}" -eq 0 ]
    grep -qx 'docker.io/library/nginx:1.25-alpine' "${TMP}/docker-argv"
}

@test "skips template mount when templates_path is missing" {
    export TEMPLATES_PATH="does/not/exist"
    cd "${REPO_ROOT}"
    run bash "${SCRIPT}"
    [ "${status}" -eq 0 ]
    ! grep -q ":/templates:ro" "${TMP}/docker-argv"
    [[ "${output}" == *"missing or empty"* ]]
}

@test "skips template mount when templates_path is empty string" {
    export TEMPLATES_PATH=""
    cd "${REPO_ROOT}"
    run bash "${SCRIPT}"
    [ "${status}" -eq 0 ]
    ! grep -q ":/templates:ro" "${TMP}/docker-argv"
}

@test "skips template mount when templates dir has no *.conf.template" {
    EMPTY_DIR="${TMP}/empty-templates"
    mkdir -p "${EMPTY_DIR}"
    export TEMPLATES_PATH="${EMPTY_DIR#"${REPO_ROOT}/"}"
    # Move the empty dir inside the repo root so the repo-relative check passes.
    INSIDE="${REPO_ROOT}/test/output-empty"
    mkdir -p "${INSIDE}"
    export TEMPLATES_PATH="test/output-empty"
    cd "${REPO_ROOT}"
    run bash "${SCRIPT}"
    rm -rf "${INSIDE}"
    [ "${status}" -eq 0 ]
    ! grep -q ":/templates:ro" "${TMP}/docker-argv"
    [[ "${output}" == *"no *.conf.template files"* ]]
}
