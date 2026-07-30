#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helpers.sh"

FLOW=""
record_step() { FLOW+="$1"$'\n'; }
require_root() { record_step root; }
detect_system() { record_step system; OS_ID=ubuntu; OS_VERSION=24.04; ARCH=x86_64; KERNEL_VERSION=6.17.0-generic; }
resolve_gpu_identity() { record_step gpu; GPU_ARCH=${1:-gfx1151}; GPU_PRODUCT_NAME='AMD Radeon 8060S Graphics'; }
resolve_install_plan() { record_step plan; INSTALL_PLAN=([gfx]="$GPU_ARCH" [os_key]=ubuntu-24.04.4 [repo_slug]=ubuntu2404 [method]="$INSTALL_METHOD" [artifact]=test [driver_mode]="$(resolve_driver_mode "$DRIVER_MODE")"); }
print_install_plan() { record_step print-plan; }
confirm_install_plan() { record_step confirm; }
step_prerequisites() { record_step prerequisites; }
step_install_driver() { record_step "driver:${INSTALL_PLAN[driver_mode]}"; }
step_install_rocm() { record_step "rocm:${INSTALL_PLAN[method]}"; }
step_ssh_config() { record_step ssh; }
step_configure_env() { record_step environment; }
verify_installation() { record_step verify; }

assert_success "auto driver mode resolves to inbox" main --gpu-arch gfx1151 --non-interactive --skip-reboot
assert_eq $'root\nsystem\ngpu\nplan\nprint-plan\nconfirm\ndriver:inbox\nprerequisites\nrocm:apt\nssh\nenvironment\nverify' "${FLOW%$'\n'}" "main migrates the driver before prerequisites"
FLOW=""
assert_success "explicit DKMS driver mode reaches the driver step" main --gpu-arch gfx1201 --driver-mode dkms --non-interactive --skip-reboot
assert_eq $'root\nsystem\ngpu\nplan\nprint-plan\nconfirm\ndriver:dkms\nprerequisites\nrocm:apt\nssh\nenvironment\nverify' "${FLOW%$'\n'}" "DKMS migration precedes prerequisite installation"

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
