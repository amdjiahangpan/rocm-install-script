#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034
set -euo pipefail
# shellcheck source=test_helpers.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helpers.sh"

FLOW=""
record_step() { FLOW+="$1"$'\n'; }
require_root() { record_step root; }
detect_system() { record_step system; OS_ID=ubuntu; OS_VERSION=24.04; ARCH=x86_64; KERNEL_VERSION=6.17.0-generic; }
resolve_gpu_identity() {
    [[ $# -eq 0 ]] || return 64
    GPU_ARCHES=$(normalize_gfxes "$GPU_ARCHES") || return $?
    GPU_PRODUCT_NAMES='AMD Radeon 8060S Graphics'
    record_step "gpu:$(records_to_csv "$GPU_ARCHES")"
}
resolve_install_plan() {
    local artifacts

    artifacts=$(resolve_plan_artifacts "$INSTALL_METHOD" "$GPU_ARCHES") || return $?
    INSTALL_PLAN=(
        [gfxes]="$GPU_ARCHES"
        [os_key]=ubuntu-24.04.4
        [repo_slug]=ubuntu2404
        [method]="$INSTALL_METHOD"
        [artifacts]="$artifacts"
        [driver_mode]="$(resolve_driver_mode "$DRIVER_MODE")"
        [product_names]="$GPU_PRODUCT_NAMES"
    )
    record_step plan
}
print_install_plan() { record_step print-plan; }
confirm_install_plan() { record_step confirm; }
step_prerequisites() { record_step prerequisites; }
step_install_driver() { record_step "driver:${INSTALL_PLAN[driver_mode]}"; }
step_install_rocm() { record_step "rocm:${INSTALL_PLAN[method]}"; }
step_ssh_config() { record_step ssh; }
step_configure_env() { record_step environment; }
verify_installation() { record_step verify; }

assert_success "auto driver mode resolves to inbox" main --gpu-arch gfx1151 --non-interactive --skip-reboot
assert_eq $'root\nsystem\ngpu:gfx1151\nplan\nprint-plan\nconfirm\ndriver:inbox\nprerequisites\nrocm:apt\nssh\nenvironment\nverify' "${FLOW%$'\n'}" "main migrates the driver before prerequisites"
FLOW=""
assert_success "explicit DKMS driver mode reaches the driver step" main --gpu-arch gfx1201 --driver-mode dkms --non-interactive --skip-reboot
assert_eq $'root\nsystem\ngpu:gfx1201\nplan\nprint-plan\nconfirm\ndriver:dkms\nprerequisites\nrocm:apt\nssh\nenvironment\nverify' "${FLOW%$'\n'}" "DKMS migration precedes prerequisite installation"

FLOW=""
assert_success "repeated GPU architectures create one normalized lifecycle" main --gpu-arch gfx1201 --gpu-arch gfx1151 --gpu-arch gfx1201 --non-interactive --skip-reboot
assert_eq $'gfx1151\ngfx1201' "$GPU_ARCHES" "repeated GPU architectures normalize before planning"
assert_eq $'root\nsystem\ngpu:gfx1151,gfx1201\nplan\nprint-plan\nconfirm\ndriver:inbox\nprerequisites\nrocm:apt\nssh\nenvironment\nverify' "${FLOW%$'\n'}" "multi-GFX main flow runs every lifecycle phase once in order"

FLOW=""
assert_success "verify-only normalizes repeated GPU architectures" main --verify-only --method apt --gpu-arch gfx1201 --gpu-arch gfx1151 --gpu-arch gfx1201
assert_eq $'gfx1151\ngfx1201' "$GPU_ARCHES" "verify-only normalizes GPU architectures before verification"
assert_eq "0" "${#INSTALL_PLAN[@]}" "verify-only does not create an install plan"
assert_eq $'root\nsystem\ngpu:gfx1151,gfx1201\nverify' "${FLOW%$'\n'}" "verify-only runs no planning or mutation lifecycle steps"

MOCK_DKMS_PACKAGE_VERSION=''
MOCK_DKMS_FIRMWARE_PACKAGE_VERSION=''
MOCK_DKMS_STATUS=''
dpkg-query() {
    case "${!#}" in
        amdgpu-dkms)
            [[ -n "$MOCK_DKMS_PACKAGE_VERSION" ]] || return 1
            printf 'installed %s\n' "$MOCK_DKMS_PACKAGE_VERSION"
            ;;
        amdgpu-dkms-firmware)
            [[ -n "$MOCK_DKMS_FIRMWARE_PACKAGE_VERSION" ]] || return 1
            printf 'installed %s\n' "$MOCK_DKMS_FIRMWARE_PACKAGE_VERSION"
            ;;
        *) return 1 ;;
    esac
}
dkms() { [[ "${1:-}" == status && -n "$MOCK_DKMS_STATUS" ]] || return 1; printf '%s\n' "$MOCK_DKMS_STATUS"; }
run_cmd() {
    recording_run_cmd "$@"
    if [[ "$1" == dpkg && "$2" == --purge ]]; then
        local package
        for package in "${@:3}"; do
            case "$package" in
                amdgpu-dkms) MOCK_DKMS_PACKAGE_VERSION='' ;;
                amdgpu-dkms-firmware) MOCK_DKMS_FIRMWARE_PACKAGE_VERSION='' ;;
            esac
        done
        MOCK_DKMS_STATUS=''
    fi
}

reset_test_state
MOCK_DKMS_PACKAGE_VERSION=31.30.1
MOCK_DKMS_FIRMWARE_PACKAGE_VERSION=31.30.1
MOCK_DKMS_STATUS='amdgpu/31.30.1, 6.17.0, x86_64: installed'
DKMS_CLEANUP_POLICY=always
NON_INTERACTIVE=true
INSTALL_PLAN=([driver_mode]=inbox [os_key]=ubuntu-24.04.4)
assert_success "inbox removes conflicting old DKMS state" migrate_driver
assert_contains "$RECORDED_COMMANDS" "dpkg --purge amdgpu-dkms amdgpu-dkms-firmware" "inbox cleanup purges both exact legacy DKMS packages"
assert_not_contains "$RECORDED_COMMANDS" "apt-get" "inbox cleanup does not run APT before removing old DKMS state"
assert_not_contains "$RECORDED_COMMANDS" "repo.radeon.com" "inbox does not configure the external driver repository"

reset_test_state
MOCK_DKMS_PACKAGE_VERSION=31.30.1
MOCK_DKMS_FIRMWARE_PACKAGE_VERSION=''
MOCK_DKMS_STATUS='amdgpu/31.30.1, 6.8.0, x86_64: installed'
DKMS_CLEANUP_POLICY=always
NON_INTERACTIVE=true
INSTALL_PLAN=([driver_mode]=dkms [os_key]=ubuntu-24.04.4)
assert_success "DKMS mode migrates to AMDGPU 31.40" migrate_driver
assert_contains "$RECORDED_COMMANDS" "dpkg --purge amdgpu-dkms" "DKMS purges conflicting old state before repository setup"
assert_contains "$RECORDED_COMMANDS" "apt-get install --yes amdgpu-dkms" "DKMS installs AMDGPU 31.40"

assert_success "Ubuntu 24 inbox accepts 6.17" validate_ubuntu_kernel inbox ubuntu-24.04.4 6.17.0-generic
assert_fails "Ubuntu 24 inbox rejects 6.8" validate_ubuntu_kernel inbox ubuntu-24.04.4 6.8.0-generic
assert_success "Ubuntu 24 DKMS accepts 6.8" validate_ubuntu_kernel dkms ubuntu-24.04.4 6.8.0-generic
assert_success "Ubuntu 26 accepts 7.0 for either driver mode" validate_ubuntu_kernel inbox ubuntu-26.04 7.0.0-generic
assert_success "Ubuntu 26 accepts 7.0 DKMS" validate_ubuntu_kernel dkms ubuntu-26.04 7.0.0-generic

finish_tests "system flow"
