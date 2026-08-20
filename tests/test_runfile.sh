#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034
set -euo pipefail
# shellcheck source=test_helpers.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helpers.sh"

ROCM_RUNFILE_STATE_ROOT="${TEST_TEMP_ROOT}/runfile-state"
ROCM_RUNFILE_ROOT="${TEST_TEMP_ROOT}/runfile-root"
MOCK_APT_CONFLICT=''
rocm_apt_installed_package_candidates() {
    [[ -z "$MOCK_APT_CONFLICT" ]] || printf '%s\n' "$MOCK_APT_CONFLICT"
    return 0
}

runfile_run_cmd() {
    local output_path

    recording_run_cmd "$@"
    if [[ "$1" == curl ]]; then
        output_path=$6
        printf 'mock runfile\n' > "$output_path"
    elif [[ "$1" == bash && "$2" == *.run ]]; then
        mkdir -p "${ROCM_RUNFILE_ROOT}/bin"
        printf '#!/usr/bin/env bash\n' > "${ROCM_RUNFILE_ROOT}/bin/rocminfo"
        printf '#!/usr/bin/env bash\n' > "${ROCM_RUNFILE_ROOT}/bin/amd-smi"
        chmod +x "${ROCM_RUNFILE_ROOT}/bin/rocminfo" "${ROCM_RUNFILE_ROOT}/bin/amd-smi"
    elif [[ "$1" == rm ]]; then
        command rm "${@:2}"
    fi
}
run_cmd() { runfile_run_cmd "$@"; }

INSTALL_PLAN=(
    [method]=runfile
    [artifacts]="$ROCM_RUNFILE_URL"
    [runfile_gfx]=all
)

assert_fails "missing Runfile layout is not ready" runfile_installation_is_ready
reset_test_state
assert_success "Runfile all installation executes the pinned installer" install_rocm_runfile
assert_contains "$RECORDED_COMMANDS" "curl -fL --retry 0 --output" "Runfile installation downloads one staged artifact"
assert_contains "$RECORDED_COMMANDS" "$ROCM_RUNFILE_URL" "Runfile installation downloads only the pinned official URL"
assert_contains "$RECORDED_COMMANDS" "deps=install rocm gfx=all compo=core\,core-dev" "Runfile installation requests all architectures and core development components"
assert_success "installed Runfile layout is ready" runfile_installation_is_ready

reset_test_state
assert_success "ready Runfile all installation is idempotent" install_rocm_runfile
assert_eq '' "$RECORDED_COMMANDS" "idempotent Runfile installation performs no download or execution"

rm -rf "$ROCM_RUNFILE_ROOT"
MOCK_APT_CONFLICT=amdrocm-core-sdk7.14-gfx1200
reset_test_state
assert_fails "Runfile installation rejects an existing APT ROCm layout" install_rocm_runfile
assert_eq '' "$RECORDED_COMMANDS" "APT conflict is detected before Runfile download"

finish_tests "runfile"
