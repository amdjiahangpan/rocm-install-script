#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034
set -euo pipefail
# shellcheck source=test_helpers.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helpers.sh"

ROCM_RUNFILE_STATE_ROOT="${TEST_TEMP_ROOT}/runfile-state"
ROCM_RUNFILE_ROOT="${TEST_TEMP_ROOT}/runfile-root"
TMPDIR=$TEST_TEMP_ROOT
ROCM_PIP_ROOT="${TEST_TEMP_ROOT}/pip-root"
ROCM_TARBALL_INSTALL_ROOT="${TEST_TEMP_ROOT}/tarball-root"
MOCK_APT_CONFLICT=''
rocm_apt_installed_package_candidates() {
    [[ -z "$MOCK_APT_CONFLICT" ]] || printf '%s\n' "$MOCK_APT_CONFLICT"
    return 0
}
MOCK_LEGACY_CONFLICT=''
detect_legacy_rocm_packages() {
    [[ -z "$MOCK_LEGACY_CONFLICT" ]] || printf '%s\n' "$MOCK_LEGACY_CONFLICT"
    return 0
}
MOCK_RUNFILE_INSTALLED_GFX=$'gfx1030\ngfx1100\ngfx1101\ngfx1102\ngfx1103\ngfx1150\ngfx1151\ngfx1152\ngfx1153\ngfx1200\ngfx1201\ngfx908\ngfx90a\ngfx942\ngfx950'
capture_cmd() {
    recording_run_cmd "$@"
    if [[ "$1" == bash && "$2" == *.run && "${3:-}" == gfx=list-installed ]]; then
        printf '%s\n' "$MOCK_RUNFILE_INSTALLED_GFX"
        return 0
    fi
    return 1
}

runfile_run_cmd() {
    local output_path

    recording_run_cmd "$@"
    if [[ "$1" == curl ]]; then
        output_path=$6
        printf 'mock runfile\n' > "$output_path"
    elif [[ "$1" == bash && "$2" == *.run ]]; then
        if [[ "$*" == *uninstall-rocm* ]]; then
            rm -rf "$ROCM_RUNFILE_ROOT"
        else
            mkdir -p "${ROCM_RUNFILE_ROOT}/bin"
            printf '#!/usr/bin/env bash\n' > "${ROCM_RUNFILE_ROOT}/bin/rocminfo"
            printf '#!/usr/bin/env bash\n' > "${ROCM_RUNFILE_ROOT}/bin/amd-smi"
            chmod +x "${ROCM_RUNFILE_ROOT}/bin/rocminfo" "${ROCM_RUNFILE_ROOT}/bin/amd-smi"
        fi
    elif [[ "$1" == rm && "$*" == *"$TEST_TEMP_ROOT"* ]]; then
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
assert_eq function "$(type -t validate_rocm_layout_compatibility || true)" "layout conflict checks use a production helper"
state_path=$(runfile_state_path)
printf 'version=7.14.0\ngfx=gfx1201\nurl=%s\n' "$ROCM_RUNFILE_URL" > "$state_path"
assert_fails "Runfile marker with non-all payload is not ready" runfile_installation_is_ready
printf 'version=7.14.0\ngfx=all\nurl=%s\n' "$ROCM_RUNFILE_URL" > "$state_path"
assert_success "exact all marker restores readiness" runfile_installation_is_ready

reset_test_state
assert_success "ready Runfile all installation is idempotent" install_rocm_runfile
assert_fails "registered Runfile layout blocks APT" validate_rocm_layout_compatibility apt
assert_fails "registered Runfile layout blocks pip" validate_rocm_layout_compatibility pip
assert_fails "registered Runfile layout blocks tarball" validate_rocm_layout_compatibility tarball
assert_contains "$RECORDED_COMMANDS" "gfx=list-installed" "idempotent Runfile validates installed architecture metadata"
assert_not_contains "$RECORDED_COMMANDS" "deps=install" "idempotent Runfile does not reinstall an all payload"

rm -f "$(runfile_state_path)"
rm -rf "$ROCM_RUNFILE_ROOT"
MOCK_APT_CONFLICT=amdrocm-core-sdk7.14-gfx1200
reset_test_state
assert_fails "Runfile installation rejects an existing APT ROCm layout" install_rocm_runfile

MOCK_APT_CONFLICT=''
MOCK_LEGACY_CONFLICT=rocm-dev
assert_fails "legacy package-manager ROCm blocks Runfile" validate_rocm_layout_compatibility runfile
MOCK_LEGACY_CONFLICT=''
mkdir -p "$ROCM_PIP_ROOT"
assert_fails "existing pip layout blocks Runfile" validate_rocm_layout_compatibility runfile
rm -rf "$ROCM_PIP_ROOT"
mkdir -p "$ROCM_TARBALL_INSTALL_ROOT"
assert_fails "existing tarball layout blocks Runfile" validate_rocm_layout_compatibility runfile
rm -rf "$ROCM_TARBALL_INSTALL_ROOT"
assert_eq '' "$RECORDED_COMMANDS" "APT conflict is detected before Runfile download"

rm -rf "$ROCM_RUNFILE_ROOT" "$ROCM_RUNFILE_STATE_ROOT"
state_blocker="${TEST_TEMP_ROOT}/state-blocker"
printf 'not a directory\n' > "$state_blocker"
ROCM_RUNFILE_STATE_ROOT="${state_blocker}/child"
INSTALL_PLAN=([method]=runfile [artifacts]="$ROCM_RUNFILE_URL" [runfile_gfx]=all)
reset_test_state
assert_fails "marker-write failure rolls back the external Runfile install" install_rocm_runfile
assert_contains "$RECORDED_COMMANDS" "uninstall-rocm gfx=all" "marker failure invokes the pinned official rollback"
assert_fails "marker failure leaves no unregistered Runfile layout" runfile_layout_is_ready
ROCM_RUNFILE_STATE_ROOT="${TEST_TEMP_ROOT}/runfile-state"
rm -rf "$ROCM_RUNFILE_STATE_ROOT"

MOCK_APT_CONFLICT=''
reset_test_state
assert_success "Runfile layout can be reinstalled for uninstall testing" install_rocm_runfile
INSTALL_PLAN=([method]=runfile)
assert_eq "$ROCM_RUNFILE_ROOT" "$(rocm_install_root)" "Runfile verification uses the configured core root"
NON_INTERACTIVE=true

INSTALL_METHOD=apt
default_uninstall_output="${TEST_TEMP_ROOT}/default-uninstall-output"
reset_test_state
if do_uninstall 2> "$default_uninstall_output"; then
    fail "default package-manager uninstall refuses a registered Runfile layout"
fi
assert_success "refused default uninstall preserves the Runfile layout" runfile_installation_is_ready
assert_eq '' "$RECORDED_COMMANDS" "refused default uninstall performs no mutation"
assert_contains "$(<"$default_uninstall_output")" "--method runfile --gpu-arch all --uninstall" "refused default uninstall prints the exact Runfile command"

INSTALL_METHOD=runfile
reset_test_state
assert_success "Runfile uninstall invokes the pinned official uninstaller" do_uninstall_runfile
assert_contains "$RECORDED_COMMANDS" "uninstall-rocm gfx=all" "Runfile uninstall requests all installed architectures"
assert_contains "$RECORDED_COMMANDS" "/etc/profile.d/rocm.sh" "Runfile uninstall removes the managed profile"
assert_contains "$RECORDED_COMMANDS" "/etc/ld.so.conf.d/rocm.conf" "Runfile uninstall removes the managed linker config"
assert_contains "$RECORDED_COMMANDS" "/etc/udev/rules.d/70-amdgpu.rules" "Runfile uninstall removes the managed udev rules"
assert_contains "$RECORDED_COMMANDS" "ldconfig" "Runfile uninstall refreshes the linker cache"
assert_contains "$RECORDED_COMMANDS" "udevadm control --reload-rules" "Runfile uninstall reloads udev rules"
assert_not_contains "$RECORDED_COMMANDS" "rm -rf ${ROCM_RUNFILE_ROOT}" "Runfile root is removed by the official uninstaller, not emulated cleanup"
assert_fails "Runfile uninstall removes the registered layout" runfile_installation_is_ready
assert_fails "Runfile uninstall removes the installer marker" test -e "$(runfile_state_path)"

finish_tests "runfile"
