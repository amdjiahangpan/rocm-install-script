#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034,SC2317
set -euo pipefail
# shellcheck source=test_helpers.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helpers.sh"

FLOW=""
record_step() { FLOW+="$1"$'\n'; }
require_root() { record_step root; }
detect_system() { record_step system; OS_ID=ubuntu; OS_VERSION=24.04; ARCH=x86_64; KERNEL_VERSION=6.14.0-1020-oem; }
resolve_gpu_identity() {
    [[ $# -eq 0 ]] || return 64
    GPU_ARCHES=$(normalize_gfxes "$GPU_ARCHES") || return $?
    GPU_CLASSES=$(resolve_gpu_classes "$GPU_ARCHES") || return $?
    GPU_DETECTION_SOURCE=explicit
    GPU_PRODUCT_NAMES='AMD Radeon 8060S Graphics'
    record_step "gpu:$(records_to_csv "$GPU_ARCHES")"
}
resolve_install_plan() {
    local artifacts gpu_classes

    artifacts=$(resolve_plan_artifacts "$INSTALL_METHOD" "$GPU_ARCHES") || return $?
    gpu_classes=$(resolve_gpu_classes "$GPU_ARCHES") || return $?
    INSTALL_PLAN=(
        [gfxes]="$GPU_ARCHES"
        [gpu_classes]="$gpu_classes"
        [gpu_source]=explicit
        [os_key]=ubuntu-24.04.4
        [repo_slug]=ubuntu2404
        [method]="$INSTALL_METHOD"
        [artifacts]="$artifacts"
        [driver_mode]="$(resolve_driver_mode "$DRIVER_MODE" ubuntu-24.04.4 "$gpu_classes" "$GPU_ARCHES")"
        [kernel_status]=ready
        [kernel_target]='6.14.*-oem'
        [kernel_package]=linux-oem-6.14
        [product_names]="$GPU_PRODUCT_NAMES"
    )
    record_step plan
}
print_install_plan() { record_step print-plan; }
confirm_install_plan() { record_step confirm; }
prepare_approved_kernel() { record_step "kernel:${INSTALL_PLAN[kernel_status]}"; }
validate_install_plan() { return 0; }
step_prerequisites() { record_step prerequisites; }
step_install_driver() { record_step "driver:${INSTALL_PLAN[driver_mode]}"; }
step_install_rocm() { record_step "rocm:${INSTALL_PLAN[method]}"; }
step_ssh_config() { record_step ssh; }
step_configure_env() { record_step environment; }
verify_installation() { record_step verify; }

capture_main_output() {
    local output_file=${TEST_TEMP_ROOT}/main-output status

    if main "$@" 2>"$output_file"; then
        MAIN_OUTPUT=$(<"$output_file")
        return 0
    else
        status=$?
        MAIN_OUTPUT=$(<"$output_file")
        return "$status"
    fi
}

assert_success "auto driver mode resolves to inbox" main --gpu-arch gfx1151 --non-interactive --skip-reboot
assert_eq $'root\nsystem\ngpu:gfx1151\nplan\nprint-plan\nconfirm\ndriver:inbox\nprerequisites\nrocm:apt\nssh\nenvironment\nverify' "${FLOW%$'\n'}" "ready-kernel main flow proceeds directly to driver migration"
FLOW=""
assert_success "explicit DKMS driver mode reaches the driver step" main --gpu-arch gfx1201 --driver-mode dkms --non-interactive --skip-reboot
assert_eq $'root\nsystem\ngpu:gfx1201\nplan\nprint-plan\nconfirm\ndriver:dkms\nprerequisites\nrocm:apt\nssh\nenvironment\nverify' "${FLOW%$'\n'}" "DKMS migration follows ready-kernel validation"

FLOW=""
assert_success "repeated Radeon GPU architectures create one normalized lifecycle" main --gpu-arch gfx1201 --gpu-arch gfx1200 --gpu-arch gfx1201 --non-interactive --skip-reboot
assert_eq $'gfx1200\ngfx1201' "$GPU_ARCHES" "repeated Radeon GPU architectures normalize before planning"
assert_eq $'root\nsystem\ngpu:gfx1200,gfx1201\nplan\nprint-plan\nconfirm\ndriver:dkms\nprerequisites\nrocm:apt\nssh\nenvironment\nverify' "${FLOW%$'\n'}" "multi-GFX main flow runs every ready-kernel lifecycle phase once in order"

FLOW=""
assert_success "verify-only normalizes repeated GPU architectures" main --verify-only --method apt --gpu-arch gfx1201 --gpu-arch gfx1151 --gpu-arch gfx1201
assert_eq $'gfx1151\ngfx1201' "$GPU_ARCHES" "verify-only normalizes GPU architectures before verification"
assert_eq "0" "${#INSTALL_PLAN[@]}" "verify-only does not create an install plan"
assert_eq $'root\nsystem\ngpu:gfx1151,gfx1201\nverify' "${FLOW%$'\n'}" "verify-only runs no planning or mutation lifecycle steps"

require_root() { record_step root; return 23; }
FLOW=""
assert_status 23 "root preflight preserves its failure status" capture_main_output --gpu-arch gfx1151 --non-interactive --skip-reboot
assert_contains "$MAIN_OUTPUT" "root privilege" "root preflight identifies the failed stage"
assert_contains "$MAIN_OUTPUT" "sudo" "root preflight tells users how to proceed"
assert_eq "root" "${FLOW%$'\n'}" "root preflight runs no later stage"

require_root() { record_step root; }
detect_system() { record_step system; OS_ID=debian; OS_VERSION=13; ARCH=x86_64; KERNEL_VERSION=6.14.0-1020-oem; return 29; }
FLOW=""
assert_status 29 "system detection preserves its failure status" capture_main_output --gpu-arch gfx1151 --non-interactive --skip-reboot
assert_contains "$MAIN_OUTPUT" "system detection" "system detection identifies the failed stage"
assert_contains "$MAIN_OUTPUT" "Ubuntu/x86_64" "system detection tells users the supported host"
assert_contains "$MAIN_OUTPUT" "os=debian-13" "system detection reports detected host context"
assert_eq $'root\nsystem' "${FLOW%$'\n'}" "system detection runs no mutation stage"

detect_system() { record_step system; OS_ID=ubuntu; OS_VERSION=24.04; ARCH=x86_64; KERNEL_VERSION=6.14.0-1020-oem; }
resolve_gpu_identity() { record_step gpu; return 31; }
FLOW=""
assert_status 31 "GPU preflight preserves its failure status" capture_main_output --gpu-arch gfx1151 --non-interactive --skip-reboot
assert_contains "$MAIN_OUTPUT" "GPU/KFD" "GPU preflight identifies the failed stage"
assert_contains "$MAIN_OUTPUT" "--gpu-arch" "GPU preflight tells users how to proceed"
assert_eq $'root\nsystem\ngpu' "${FLOW%$'\n'}" "GPU preflight runs no mutation stage"

resolve_gpu_identity() {
    [[ $# -eq 0 ]] || return 64
    GPU_ARCHES=$(normalize_gfxes "$GPU_ARCHES") || return $?
    GPU_CLASSES=$(resolve_gpu_classes "$GPU_ARCHES") || return $?
    GPU_DETECTION_SOURCE=explicit
    GPU_PRODUCT_NAMES='AMD Radeon 8060S Graphics'
    record_step "gpu:$(records_to_csv "$GPU_ARCHES")"
}
resolve_install_plan() { record_step plan; return 37; }
FLOW=""
assert_status 37 "plan validation preserves its failure status" capture_main_output --gpu-arch gfx1151 --non-interactive --skip-reboot
assert_contains "$MAIN_OUTPUT" "installation plan validation" "plan validation identifies the failed stage"
assert_contains "$MAIN_OUTPUT" "os=ubuntu-24.04" "plan validation reports operating-system context"
assert_contains "$MAIN_OUTPUT" "kernel=6.14.0-1020-oem" "plan validation reports kernel context"
assert_contains "$MAIN_OUTPUT" "driver=auto" "plan validation reports driver context"
assert_contains "$MAIN_OUTPUT" "gfx=gfx1151" "plan validation reports GPU context"
assert_eq $'root\nsystem\ngpu:gfx1151\nplan' "${FLOW%$'\n'}" "plan validation runs no mutation stage"

resolve_install_plan() {
    local artifacts gpu_classes

    artifacts=$(resolve_plan_artifacts "$INSTALL_METHOD" "$GPU_ARCHES") || return $?
    gpu_classes=$(resolve_gpu_classes "$GPU_ARCHES") || return $?
    INSTALL_PLAN=(
        [gfxes]="$GPU_ARCHES"
        [gpu_classes]="$gpu_classes"
        [gpu_source]=explicit
        [os_key]=ubuntu-24.04.4
        [repo_slug]=ubuntu2404
        [method]="$INSTALL_METHOD"
        [artifacts]="$artifacts"
        [driver_mode]="$(resolve_driver_mode "$DRIVER_MODE" ubuntu-24.04.4 "$gpu_classes" "$GPU_ARCHES")"
        [kernel_status]=ready
        [kernel_target]='6.14.*-oem'
        [kernel_package]=linux-oem-6.14
        [product_names]="$GPU_PRODUCT_NAMES"
    )
    record_step plan
}
print_install_plan() { record_step print-plan; return 41; }
FLOW=""
assert_status 41 "plan rendering preserves its failure status" capture_main_output --gpu-arch gfx1151 --non-interactive --skip-reboot
assert_contains "$MAIN_OUTPUT" "installation plan rendering" "plan rendering identifies the failed stage"
assert_contains "$MAIN_OUTPUT" "output destination" "plan rendering tells users how to proceed"
assert_eq $'root\nsystem\ngpu:gfx1151\nplan\nprint-plan' "${FLOW%$'\n'}" "plan rendering runs no mutation stage"

print_install_plan() { record_step print-plan; }
confirm_install_plan() { record_step confirm; return 43; }
FLOW=""
assert_status 43 "installation confirmation preserves its failure status" capture_main_output --gpu-arch gfx1151 --non-interactive --skip-reboot
assert_contains "$MAIN_OUTPUT" "installation confirmation" "installation confirmation identifies the failed stage"
assert_contains "$MAIN_OUTPUT" "cancelled" "installation confirmation tells users it was cancelled"
assert_contains "$MAIN_OUTPUT" "--non-interactive" "installation confirmation tells users how to bypass prompts"
assert_eq $'root\nsystem\ngpu:gfx1151\nplan\nprint-plan\nconfirm' "${FLOW%$'\n'}" "installation confirmation runs no mutation stage"

resolve_install_plan() {
    local artifacts gpu_classes

    artifacts=$(resolve_plan_artifacts "$INSTALL_METHOD" "$GPU_ARCHES") || return $?
    gpu_classes=$(resolve_gpu_classes "$GPU_ARCHES") || return $?
    INSTALL_PLAN=(
        [gfxes]="$GPU_ARCHES"
        [gpu_classes]="$gpu_classes"
        [gpu_source]=explicit
        [os_key]=ubuntu-24.04.4
        [repo_slug]=ubuntu2404
        [method]="$INSTALL_METHOD"
        [artifacts]="$artifacts"
        [driver_mode]=inbox
        [kernel_status]=install-required
        [kernel_target]='6.14.*-oem'
        [kernel_package]=linux-oem-6.14
        [product_names]="$GPU_PRODUCT_NAMES"
    )
    record_step plan
}
confirm_install_plan() { record_step confirm; }
prepare_approved_kernel() { fail "default kernel mismatch must not prepare a kernel"; }
handle_reboot() { fail "default kernel mismatch must not reboot"; }
FLOW=""
assert_status 20 "default kernel mismatch requires explicit action" capture_main_output --gpu-arch gfx1151 --non-interactive --skip-reboot
assert_contains "$MAIN_OUTPUT" "current kernel" "kernel mismatch reports the running kernel"
assert_contains "$MAIN_OUTPUT" "6.14.*-oem" "kernel mismatch reports the target kernel"
assert_contains "$MAIN_OUTPUT" "linux-oem-6.14" "kernel mismatch reports the approved metapackage"
assert_eq $'root\nsystem\ngpu:gfx1151\nplan\nprint-plan\nconfirm' "${FLOW%$'\n'}" "default mismatch stops before every mutation"

prepare_approved_kernel() { record_step "kernel:${INSTALL_PLAN[kernel_status]}"; }
FLOW=""
assert_status 21 "explicit kernel preparation reports pending reboot" capture_main_output --gpu-arch gfx1151 --prepare-kernel --non-interactive --skip-reboot
assert_eq $'root\nsystem\ngpu:gfx1151\nplan\nprint-plan\nconfirm\nkernel:install-required' "${FLOW%$'\n'}" "explicit preparation stops after preparing the target kernel"

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
    if [[ "$1 ${2:-} ${3:-} ${4:-}" == 'apt-get install --yes amdgpu-dkms' ]]; then
        MOCK_DKMS_PACKAGE_VERSION=$real_dkms_package_version
        MOCK_DKMS_FIRMWARE_PACKAGE_VERSION=$real_dkms_firmware_version
        MOCK_DKMS_STATUS=$real_dkms_status
    fi
}

real_dkms_package_version='1:6.19.14.31400000-2364437.24.04'
real_dkms_firmware_version='1:31.40.0.0.31400000-2364437.24.04'
real_dkms_status=$'amdgpu/6.19.14-2364437.24.04, 6.8.0-138-generic, x86_64: installed\namdgpu/6.19.14-2364437.24.04, 7.0.0-28-generic, x86_64: installed'
AMDGPU_DKMS_PACKAGE_VERSION=$real_dkms_package_version
AMDGPU_DKMS_FIRMWARE_PACKAGE_VERSION=$real_dkms_firmware_version
AMDGPU_DKMS_STATUS=$real_dkms_status
KERNEL_VERSION=6.8.0-138-generic
assert_success "real AMDGPU 31.40 package and DKMS metadata is clean" amdgpu_dkms_is_clean_3140
AMDGPU_DKMS_STATUS='amdgpu/6.19.14-2364437.24.04, 7.0.0-28-generic, x86_64: installed'
assert_fails "AMDGPU 31.40 without the running-kernel module is not clean" amdgpu_dkms_is_clean_3140
AMDGPU_DKMS_STATUS=$real_dkms_status
AMDGPU_DKMS_FIRMWARE_PACKAGE_VERSION='1:31.30.0.0.31300000-older.24.04'
assert_fails "AMDGPU 31.40 with mismatched firmware is not clean" amdgpu_dkms_is_clean_3140

reset_test_state
MOCK_DKMS_PACKAGE_VERSION=$real_dkms_package_version
MOCK_DKMS_FIRMWARE_PACKAGE_VERSION=$real_dkms_firmware_version
MOCK_DKMS_STATUS=$real_dkms_status
DKMS_CLEANUP_POLICY=never
NON_INTERACTIVE=true
INSTALL_PLAN=([driver_mode]=dkms [os_key]=ubuntu-24.04.4)
assert_success "a clean real AMDGPU 31.40 installation is left unchanged" migrate_driver
assert_eq '' "$RECORDED_COMMANDS" "a clean AMDGPU 31.40 rerun performs no purge or install"

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

assert_eq radeon "$(resolve_gpu_classes gfx1200)" "gfx1200 resolves to the Radeon policy class"
assert_eq ryzen "$(resolve_gpu_classes gfx1151)" "gfx1151 resolves to the Ryzen policy class"
assert_eq instinct "$(resolve_gpu_classes gfx942)" "gfx942 resolves to the Instinct policy class"
assert_eq dkms "$(resolve_driver_mode auto ubuntu-24.04.4 radeon gfx1200)" "Ubuntu 24 Radeon auto mode selects AMDGPU DKMS"
assert_eq inbox "$(resolve_driver_mode auto ubuntu-24.04.4 ryzen gfx1151)" "Ubuntu 24 Ryzen auto mode selects the inbox driver"
assert_eq dkms "$(resolve_driver_mode dkms ubuntu-24.04.4 radeon gfx1200)" "Ubuntu 24 Radeon accepts explicit DKMS"
assert_fails "Ubuntu 24 Ryzen rejects explicit DKMS" resolve_driver_mode dkms ubuntu-24.04.4 ryzen gfx1151

assert_eq '6.14.*-oem|linux-oem-6.14' "$(kernel_policy_for inbox ubuntu-24.04.4 gfx1151)" "Ubuntu 24 Ryzen targets select the approved OEM metapackage"
assert_success "Ubuntu 24 Ryzen accepts the current OEM kernel release" validate_ubuntu_kernel inbox ubuntu-24.04.4 6.14.0-1020-oem gfx1151
assert_fails "Ubuntu 24 Ryzen rejects a matching series with generic flavor" validate_ubuntu_kernel inbox ubuntu-24.04.4 6.14.0-1020-generic gfx1151
assert_fails "Ubuntu 24 Ryzen rejects DKMS mode" kernel_policy_for dkms ubuntu-24.04.4 gfx1151
assert_fails "Ubuntu 24 mixed Ryzen and non-Ryzen targets fail closed" kernel_policy_for inbox ubuntu-24.04.4 $'gfx1151\ngfx1201'
assert_eq '6.8.*-generic|linux-generic' "$(kernel_policy_for inbox ubuntu-24.04.4 gfx1201)" "Ubuntu 24 non-Ryzen targets select the GA generic metapackage"
assert_success "Ubuntu 24 non-Ryzen DKMS accepts the GA generic kernel" validate_ubuntu_kernel dkms ubuntu-24.04.4 6.8.0-101-generic gfx1201
assert_eq '7.0.*-generic|linux-generic-7.0' "$(kernel_policy_for inbox ubuntu-26.04 gfx1151)" "Ubuntu 26 selects the approved generic metapackage"
assert_success "Ubuntu 26 accepts the generic kernel for either driver mode" validate_ubuntu_kernel dkms ubuntu-26.04 7.0.0-11-generic gfx1151

finish_tests "system flow"
