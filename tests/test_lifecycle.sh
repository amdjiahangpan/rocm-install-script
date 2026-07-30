#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034,SC2317
set -euo pipefail
# shellcheck source=test_helpers.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helpers.sh"

MANAGED_FILES=""
PASSWORD_UPDATES=""
CAPTURED_COMMANDS_FILE=""
MOCK_FAIL_FRAGMENT=""
MOCK_GROUPS_PRESENT=false
MOCK_ROCMINFO_OUTPUT=$'  Name:                    gfx1151\n'
MOCK_AMD_SMI_OUTPUT="ROCm version: 7.14.0"
MOCK_INSTALLED_ROCM_PACKAGES=""
MOCK_INSTALLED_LEGACY_ROCM_PACKAGES=""

lifecycle_run_cmd() {
    recording_run_cmd "$@"
    [[ -z "$MOCK_FAIL_FRAGMENT" || "$*" != *"$MOCK_FAIL_FRAGMENT"* ]] || return 23
}

write_managed_file() {
    local path=$1 mode=$2 content=$3 quoted
    printf -v quoted '%q' "$content"
    MANAGED_FILES+="${path} ${mode} ${quoted}"$'\n'
}

set_root_password() {
    PASSWORD_UPDATES+="root-password-updated"$'\n'
}

user_has_required_groups() {
    [[ "$MOCK_GROUPS_PRESENT" == true ]]
}

capture_cmd() {
    local argument quoted command_line=""

    for argument in "$@"; do
        printf -v quoted '%q' "$argument"
        command_line+="${command_line:+ }${quoted}"
    done
    printf '%s\n' "$command_line" >> "$CAPTURED_COMMANDS_FILE"
    case "$*" in
        */bin/rocminfo) printf '%s\n' "$MOCK_ROCMINFO_OUTPUT" ;;
        */bin/amd-smi\ version) printf '%s\n' "$MOCK_AMD_SMI_OUTPUT" ;;
        *) return 1 ;;
    esac
}

reset_lifecycle_state() {
    reset_test_state
    reset_defaults
    MANAGED_FILES=""
    PASSWORD_UPDATES=""
    CAPTURED_COMMANDS_FILE="${TEST_TEMP_ROOT}/captured-commands"
    : > "$CAPTURED_COMMANDS_FILE"
    MOCK_FAIL_FRAGMENT=""
    MOCK_GROUPS_PRESENT=false
    MOCK_ROCMINFO_OUTPUT=$'  Name:                    gfx1151\n'
    MOCK_AMD_SMI_OUTPUT="ROCm version: 7.14.0"
    MOCK_INSTALLED_ROCM_PACKAGES=""
    REBOOT_REQUIRED=false
    OS_ID=ubuntu
    OS_VERSION=24.04
    ARCH=x86_64
    KERNEL_VERSION=6.17.0-generic
    INSTALL_METHOD=apt
    GPU_ARCHES=gfx1151
    GPU_PRODUCT_NAMES='AMD Radeon 8060S Graphics'
    INSTALL_PLAN=(
        [gfxes]=gfx1151
        [os_key]=ubuntu-24.04.4
        [repo_slug]=ubuntu2404
        [method]=apt
        [artifacts]=amdrocm-core-sdk7.14-gfx1151
        [driver_mode]=inbox
        [product_names]="$GPU_PRODUCT_NAMES"
    )
}

run_cmd() { lifecycle_run_cmd "$@"; }

dpkg-query() {
    local package=${!#}

    if (( $# == 2 )) && [[ "$1" == -W ]]; then
        for package in $MOCK_INSTALLED_LEGACY_ROCM_PACKAGES; do
            printf '%s\tinstalled\n' "$package"
        done
        return 0
    fi
    [[ " $MOCK_INSTALLED_ROCM_PACKAGES " == *" $package "* ]] || return 1
    printf '%s\n' installed
}

os_release_fixture="${TEST_TEMP_ROOT}/os-release"
printf 'ID=ubuntu\nVERSION_ID="24.04"\n' > "$os_release_fixture"
OS_RELEASE_FILE=$os_release_fixture
SYSTEM_ARCH_OVERRIDE=x86_64
SYSTEM_KERNEL_OVERRIDE=6.17.0-generic
assert_success "Ubuntu 24.04 x86_64 is detected from os-release" detect_system
assert_eq ubuntu "$OS_ID" "system detection records Ubuntu"
assert_eq 24.04 "$OS_VERSION" "system detection records Ubuntu 24.04"
printf 'ID=ubuntu\nVERSION_ID="26.04"\n' > "$os_release_fixture"
SYSTEM_KERNEL_OVERRIDE=7.0.0-generic
assert_success "Ubuntu 26.04 x86_64 is detected from os-release" detect_system
printf 'ID=debian\nVERSION_ID="13"\n' > "$os_release_fixture"
assert_fails "non-Ubuntu os-release is rejected" detect_system
SYSTEM_ARCH_OVERRIDE=aarch64
printf 'ID=ubuntu\nVERSION_ID="26.04"\n' > "$os_release_fixture"
assert_fails "non-x86_64 architecture is rejected" detect_system
unset OS_RELEASE_FILE SYSTEM_ARCH_OVERRIDE SYSTEM_KERNEL_OVERRIDE

reset_lifecycle_state
assert_success "APT prerequisites install required and retained optional tools" step_prerequisites
assert_contains "$RECORDED_COMMANDS" "apt-get update" "prerequisites refresh APT metadata"
assert_contains "$RECORDED_COMMANDS" "curl ca-certificates gnupg pciutils" "required fetch, key, and detection tools are installed"
assert_contains "$RECORDED_COMMANDS" "build-essential cmake git" "retained development tools are attempted"
assert_contains "$RECORDED_COMMANDS" "systemctl enable --now systemd-timesyncd" "time synchronization is enabled"

reset_lifecycle_state
MOCK_FAIL_FRAGMENT="curl ca-certificates gnupg pciutils"
assert_status 23 "required prerequisite failure propagates" step_prerequisites
assert_not_contains "$RECORDED_COMMANDS" "build-essential" "optional tools are not attempted after required prerequisite failure"

reset_lifecycle_state
MOCK_FAIL_FRAGMENT="build-essential"
optional_output=$(step_prerequisites 2>&1)
assert_contains "$optional_output" "Optional tools could not be installed" "optional retained tool failure is explicit and nonfatal"

reset_lifecycle_state
ROOT_PASSWORD='do-not-record-this-secret'
assert_success "default SSH setup is implemented" step_ssh_config
assert_contains "$RECORDED_COMMANDS" "apt-get install --yes openssh-server" "SSH server installation is required"
assert_contains "$MANAGED_FILES" "/etc/ssh/sshd_config.d/99-rocm-installer.conf" "SSH uses a managed drop-in"
assert_contains "$MANAGED_FILES" "PermitRootLogin yes" "SSH permits root login by default"
assert_contains "$MANAGED_FILES" "PasswordAuthentication yes" "SSH permits password authentication by default"
assert_eq $'root-password-updated\n' "$PASSWORD_UPDATES" "a supplied root password uses the dedicated seam"
assert_not_contains "$RECORDED_COMMANDS$MANAGED_FILES$PASSWORD_UPDATES" "do-not-record-this-secret" "the root password is never logged or passed as a command argument"

reset_lifecycle_state
SKIP_SSH=true
ROOT_PASSWORD='still-secret'
assert_success "skip SSH is implemented" step_ssh_config
assert_eq "" "$RECORDED_COMMANDS$MANAGED_FILES$PASSWORD_UPDATES" "skip SSH emits no SSH or password mutation"

reset_lifecycle_state
SUDO_USER=installer-test-user
assert_success "APT environment and permissions are configured" step_configure_env
assert_contains "$RECORDED_COMMANDS" "usermod -aG video\,render installer-test-user" "the invoking user joins video and render"
assert_contains "$MANAGED_FILES" "/etc/udev/rules.d/70-amdgpu.rules" "GPU udev access is managed"
assert_contains "$MANAGED_FILES" "/etc/ld.so.conf.d/rocm.conf" "APT configures the ROCm linker path"
assert_contains "$MANAGED_FILES" "/etc/profile.d/rocm.sh" "APT configures a system-wide profile"
assert_contains "$MANAGED_FILES" "/opt/rocm/core-7.14" "APT environment uses the current ROCm package root"
assert_not_contains "$MANAGED_FILES" "/opt/rocm/bin" "APT environment does not use the stale active ROCm path"
assert_not_contains "$MANAGED_FILES" ".bashrc" "no user bashrc is edited"
assert_eq true "$REBOOT_REQUIRED" "group and udev changes require a reboot"
unset SUDO_USER

reset_lifecycle_state
INSTALL_METHOD=pip
INSTALL_PLAN[method]=pip
assert_success "pip environment points at the fixed virtual environment" step_configure_env
assert_contains "$MANAGED_FILES" "/opt/rocm-7.14.0-venv" "pip profile exposes the fixed venv"
assert_not_contains "$MANAGED_FILES" "bin/activate" "pip does not auto-activate the virtual environment"

reset_lifecycle_state
REBOOT_REQUIRED=true
pending_output=$(verify_installation)
assert_contains "$pending_output" "pending reboot" "pre-reboot verification reports pending"
assert_not_contains "$pending_output" "verified" "pre-reboot verification does not claim success"
assert_eq "" "$(<"$CAPTURED_COMMANDS_FILE")" "pre-reboot verification does not invoke binaries"

rocminfo_agents=$'  Name:                    gfx1201\n  Name:                    gfx1151\n    Name:                  gfx1201\n  Name:                    GFX12A1\n  Name:                    CPU\n  Name:                    gfx\n  Agent Name:              gfx1100\n'
assert_eq $'gfx1151\ngfx1201\ngfx12a1' "$(extract_rocminfo_gfxes "$rocminfo_agents")" "rocminfo agent extraction trims, lowercases, and normalizes concrete Name values"
assert_fails "rocminfo agent extraction requires exactly one output string" extract_rocminfo_gfxes

reset_lifecycle_state
verify_output=$(verify_installation)
assert_contains "$verify_output" "requested gfx agents" "single requested gfx verification reports target-aware success"
assert_eq $'/opt/rocm/core-7.14/bin/rocminfo\n/opt/rocm/core-7.14/bin/amd-smi version' "$(<"$CAPTURED_COMMANDS_FILE")" "APT verification captures only the current package-root binaries"

reset_lifecycle_state
INSTALL_PLAN[gfxes]=$'gfx1151\ngfx1201'
MOCK_ROCMINFO_OUTPUT=$'  Name:                    gfx1151\n  Name:                    gfx1201\n'
assert_success "verification accepts two requested gfx agents in rocminfo order" verify_installation

reset_lifecycle_state
INSTALL_PLAN[gfxes]=$'gfx1151\ngfx1201'
MOCK_ROCMINFO_OUTPUT=$'  Name:                    gfx1201\n  Name:                    gfx1151\n'
assert_success "verification accepts two requested gfx agents in reverse rocminfo order" verify_installation

reset_lifecycle_state
MOCK_ROCMINFO_OUTPUT=$'  Name:                    gfx1151\n  Name:                    gfx1151\n'
assert_success "verification accepts duplicate visible rocminfo agents" verify_installation

reset_lifecycle_state
MOCK_ROCMINFO_OUTPUT=$'  Name:                    gfx1201\n  Name:                    gfx1151\n  Name:                    gfx1100\n'
assert_success "verification permits visible rocminfo agents beyond the requested plan" verify_installation

reset_lifecycle_state
INSTALL_PLAN[gfxes]=$'gfx1151\ngfx1201'
MOCK_ROCMINFO_OUTPUT=$'  Name:                    gfx1201\n'
if missing_gfx_output=$(verify_installation 2>&1); then
    fail "verification rejects a missing requested gfx1151 target"
fi
assert_contains "$missing_gfx_output" "gfx1151" "verification names a missing requested gfx1151 target"

reset_lifecycle_state
INSTALL_PLAN[gfxes]=$'gfx1151\ngfx1201'
MOCK_ROCMINFO_OUTPUT=$'  Name:                    gfx1151\n'
if missing_gfx_output=$(verify_installation 2>&1); then
    fail "verification rejects a missing requested gfx1201 target"
fi
assert_contains "$missing_gfx_output" "gfx1201" "verification names a missing requested gfx1201 target"

reset_lifecycle_state
MOCK_ROCMINFO_OUTPUT=$'Agent 2\n  Name:                    CPU\n  Name:                    gfx\n'
assert_fails "verification rejects nonempty rocminfo output without a concrete gfx agent" verify_installation

reset_lifecycle_state
INSTALL_PLAN[gfxes]=$'gfx1201\ngfx1151'
MOCK_ROCMINFO_OUTPUT=$'  Name:                    gfx1151\n  Name:                    gfx1201\n'
assert_fails "verification requires normalized requested GFX plan records" verify_installation

reset_lifecycle_state
INSTALL_PLAN=()
GPU_ARCHES=$'gfx1201\ngfx1151'
MOCK_ROCMINFO_OUTPUT=$'  Name:                    gfx1151\n  Name:                    gfx1201\n'
assert_success "verification normalizes GPU architecture fallback records without an install plan" verify_installation

reset_lifecycle_state
INSTALL_PLAN[gfxes]=''
GPU_ARCHES=gfx1151
assert_fails "an empty present plan GFX key rejects verification instead of falling back" verify_installation
assert_eq "" "$(<"$CAPTURED_COMMANDS_FILE")" "an empty present plan GFX key fails before verification command capture"

reset_lifecycle_state
INSTALL_METHOD=pip
INSTALL_PLAN[method]=pip
assert_success "pip verification uses the fixed virtual environment binaries" verify_installation
assert_eq $'/opt/rocm-7.14.0-venv/bin/rocminfo\n/opt/rocm-7.14.0-venv/bin/amd-smi version' "$(<"$CAPTURED_COMMANDS_FILE")" "pip verification captures only the virtual environment binaries"

reset_lifecycle_state
INSTALL_METHOD=tarball
INSTALL_PLAN[method]=tarball
assert_success "tarball verification uses the selected absolute binary paths" verify_installation
assert_eq $'/opt/rocm/bin/rocminfo\n/opt/rocm/bin/amd-smi version' "$(<"$CAPTURED_COMMANDS_FILE")" "tarball verification captures only the /opt/rocm binaries"

reset_lifecycle_state
MOCK_AMD_SMI_OUTPUT="ROCm version: 7.13.0"
assert_fails "verification rejects a different ROCm release" verify_installation

reset_lifecycle_state
MOCK_AMD_SMI_OUTPUT="ROCm version: 7.14.0.1"
assert_fails "verification rejects a version with an extra release component" verify_installation

is_expected_rocm_link() { return 0; }
reset_lifecycle_state
NON_INTERACTIVE=true
assert_success "pip-only uninstall skips package purge and removes the fixed venv" do_uninstall
assert_not_contains "$RECORDED_COMMANDS" "apt-get purge" "no installed APT candidates means no purge command"
assert_contains "$RECORDED_COMMANDS" "rm -rf /opt/rocm/core-7.14 /opt/rocm-7.14.0 /opt/rocm-7.14.0-venv" "pip-only uninstall removes the fixed virtual environment and current APT root"
assert_contains "$RECORDED_COMMANDS" "/etc/profile.d/rocm.sh" "pip-only uninstall removes fixed configuration"

reset_lifecycle_state
NON_INTERACTIVE=true
assert_success "tarball-only uninstall skips package purge and removes its root and symlink" do_uninstall
assert_not_contains "$RECORDED_COMMANDS" "apt-get purge" "tarball-only uninstall does not purge absent APT packages"
assert_contains "$RECORDED_COMMANDS" "rm -rf /opt/rocm/core-7.14 /opt/rocm-7.14.0 /opt/rocm-7.14.0-venv" "tarball-only uninstall removes the fixed tarball root"
assert_contains "$RECORDED_COMMANDS" "rm -f /opt/rocm" "tarball-only uninstall removes the expected active symlink"

reset_lifecycle_state
NON_INTERACTIVE=true
MOCK_INSTALLED_ROCM_PACKAGES="amdrocm-core-sdk7.14-gfx1151 rocm"
assert_success "uninstall purges only the exact installed ROCm APT candidate" do_uninstall
assert_eq "apt-get purge --yes amdrocm-core-sdk7.14-gfx1151" "${RECORDED_COMMANDS%%$'\n'*}" "uninstall purges exactly the installed architecture-specific package"
assert_not_contains "$RECORDED_COMMANDS" "amdrocm-core-sdk7.14-gfx1201" "uninstall does not purge an uninstalled ROCm candidate"
assert_not_contains "$RECORDED_COMMANDS" "apt-get purge --yes rocm" "uninstall leaves legacy packages outside the current release candidates"

reset_lifecycle_state
NON_INTERACTIVE=true
MOCK_INSTALLED_ROCM_PACKAGES="amdrocm-core-sdk7.14-gfx1151"
MOCK_FAIL_FRAGMENT="apt-get purge --yes amdrocm-core-sdk7.14-gfx1151"
assert_status 23 "installed package purge failure is returned after independent cleanup" do_uninstall
assert_contains "$RECORDED_COMMANDS" "rm -rf /opt/rocm/core-7.14 /opt/rocm-7.14.0 /opt/rocm-7.14.0-venv" "purge failure still removes fixed installation roots"
assert_contains "$RECORDED_COMMANDS" "/etc/ld.so.conf.d/rocm.conf" "purge failure still removes fixed configuration"
assert_contains "$RECORDED_COMMANDS" "udevadm control --reload-rules" "purge failure still reloads udev rules"

MOCK_DKMS_PACKAGE_VERSION=""
MOCK_DKMS_FIRMWARE_PACKAGE_VERSION=""
MOCK_DKMS_STATUS=""
MOCK_KERNEL_VERSION=7.0.0-generic
MOCK_REQUIRE_DRIVER_MIGRATION_BEFORE_APT=false

require_root() { return 0; }
detect_system() {
    OS_ID=ubuntu
    OS_VERSION=26.04
    ARCH=x86_64
    KERNEL_VERSION=$MOCK_KERNEL_VERSION
}
managed_file_has_content() { return 1; }
rocm_apt_verification_root_exists() { return 0; }
dpkg-query() {
    local package

    if (( $# == 2 )) && [[ "$1" == -W ]]; then
        for package in $MOCK_INSTALLED_LEGACY_ROCM_PACKAGES; do
            printf '%s\tinstalled\n' "$package"
        done
        return 0
    fi
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
dkms() {
    [[ "${1:-}" == status && -n "$MOCK_DKMS_STATUS" ]] || return 1
    printf '%s\n' "$MOCK_DKMS_STATUS"
}
mktemp() {
    printf '%s\n' "${TEST_TEMP_ROOT}/mock-tarball"
}
lifecycle_run_cmd() {
    recording_run_cmd "$@"
    [[ -z "$MOCK_FAIL_FRAGMENT" || "$*" != *"$MOCK_FAIL_FRAGMENT"* ]] || return 23
    if [[ "$1" == apt-get && "$MOCK_REQUIRE_DRIVER_MIGRATION_BEFORE_APT" == true && ( -n "$MOCK_DKMS_PACKAGE_VERSION" || -n "$MOCK_DKMS_FIRMWARE_PACKAGE_VERSION" || -n "$MOCK_DKMS_STATUS" ) ]]; then
        return 29
    fi
    if [[ "$1" == dpkg && "${2:-}" == --purge ]]; then
        local package
        for package in "${@:3}"; do
            case "$package" in
                amdgpu-dkms) MOCK_DKMS_PACKAGE_VERSION="" ;;
                amdgpu-dkms-firmware) MOCK_DKMS_FIRMWARE_PACKAGE_VERSION="" ;;
            esac
        done
        MOCK_DKMS_STATUS=""
    fi
}

run_mocked_main() {
    local method=$1 output_file="${TEST_TEMP_ROOT}/main-output"
    shift

    reset_test_state
    MANAGED_FILES=""
    PASSWORD_UPDATES=""
    main --method "$method" --non-interactive --skip-ssh --skip-reboot "$@" > "$output_file"
}

recorded_command_count() {
    local command_fragment=$1 commands=$2 count=0

    while [[ "$commands" == *"$command_fragment"* ]]; do
        commands=${commands#*"$command_fragment"}
        count=$((count + 1))
    done
    printf '%s\n' "$count"
}

MOCK_DKMS_PACKAGE_VERSION=""
MOCK_DKMS_STATUS=""
MOCK_KERNEL_VERSION=7.0.0-generic
MOCK_INSTALLED_LEGACY_ROCM_PACKAGES="rocm-dev rocm amdrocm-core-sdk7.14-gfx1151"
assert_success "mocked inbox APT lifecycle runs through the real steps" run_mocked_main apt --gpu-arch gfx1151
assert_contains "$RECORDED_COMMANDS" "apt-get purge --yes rocm rocm-dev" "main flow purges only the installed legacy ROCm packages"
assert_not_contains "$RECORDED_COMMANDS" "apt-get purge --yes amdrocm" "main flow keeps amdrocm packages out of legacy migration purges"
assert_command_before "apt-get purge --yes rocm rocm-dev" "apt-get install --yes amdrocm-core-sdk7.14-gfx1151" "$RECORDED_COMMANDS" "main flow purges legacy ROCm before installing the current package"
assert_contains "$RECORDED_COMMANDS" "apt-get install --yes amdrocm-core-sdk7.14-gfx1151" "main flow installs the architecture-specific APT package"
assert_not_contains "$RECORDED_COMMANDS" "apt-get install --yes amdgpu-dkms" "auto driver mode keeps the inbox driver"

multi_gfxes=$'gfx1151\ngfx1201'
multi_packages=$'amdrocm-core-sdk7.14-gfx1151\namdrocm-core-sdk7.14-gfx1201'
multi_pip_requirement='rocm[libraries,device-gfx1151,device-gfx1201]==7.14.0'
MOCK_DKMS_PACKAGE_VERSION=""
MOCK_DKMS_FIRMWARE_PACKAGE_VERSION=""
MOCK_DKMS_STATUS=""
MOCK_REQUIRE_DRIVER_MIGRATION_BEFORE_APT=false
MOCK_INSTALLED_LEGACY_ROCM_PACKAGES=""
MOCK_FAIL_FRAGMENT=""
assert_success "mocked multi-GFX APT lifecycle runs through the real steps" run_mocked_main apt --gpu-arch gfx1201 --gpu-arch gfx1151 --gpu-arch gfx1201
assert_eq "$multi_gfxes" "$GPU_ARCHES" "duplicate explicit GPU architectures normalize before the APT plan"
assert_eq "$multi_gfxes" "${INSTALL_PLAN[gfxes]}" "multi-GFX APT plan retains both normalized architectures"
assert_eq "$multi_packages" "${INSTALL_PLAN[artifacts]}" "multi-GFX APT plan contains one SDK package per architecture"
assert_contains "$RECORDED_COMMANDS" "apt-get install --yes amdrocm-core-sdk7.14-gfx1151 amdrocm-core-sdk7.14-gfx1201" "multi-GFX main installs both SDK packages in one APT transaction"
assert_eq "1" "$(recorded_command_count "apt-get install --yes amdrocm-core-sdk7.14" "$RECORDED_COMMANDS")" "multi-GFX main performs one ROCm SDK APT transaction"
assert_not_contains "$RECORDED_COMMANDS" "$ROCM_MULTIARCH_TARBALL_ARTIFACT" "multi-GFX APT does not select a tarball artifact"

heterogeneous_fixture="${ROOT_DIR}/tests/fixtures/gfx1151-gfx1201"
GPU_DETECTION_KFD_ROOT="${heterogeneous_fixture}/kfd"
GPU_DETECTION_DRM_ROOT="${TEST_TEMP_ROOT}/missing-drm-root"
assert_success "explicit GPU architectures replace automatic heterogeneous detection" run_mocked_main apt --gpu-arch gfx1151
assert_eq "gfx1151" "$GPU_ARCHES" "explicit architecture replaces automatically detected heterogeneous targets"
assert_eq "gfx1151" "${INSTALL_PLAN[gfxes]}" "explicit architecture creates a single-GFX plan"
assert_contains "$RECORDED_COMMANDS" "apt-get install --yes amdrocm-core-sdk7.14-gfx1151" "explicit architecture selects its SDK package"
assert_not_contains "$RECORDED_COMMANDS" "amdrocm-core-sdk7.14-gfx1201" "explicit architecture does not retain an automatic heterogeneous target"
unset GPU_DETECTION_KFD_ROOT GPU_DETECTION_DRM_ROOT

MOCK_FAIL_FRAGMENT=""
assert_status 64 "unsupported explicit GPU architecture fails before lifecycle mutation" run_mocked_main apt --gpu-arch gfx1201 --gpu-arch gfx9999
assert_eq "" "$GPU_ARCHES" "unsupported explicit architecture clears resolved GPU state"
assert_eq "0" "${#INSTALL_PLAN[@]}" "unsupported explicit architecture creates no install plan"
assert_eq "" "$RECORDED_COMMANDS$MANAGED_FILES$PASSWORD_UPDATES" "unsupported explicit architecture runs no mutation command"

MOCK_DKMS_PACKAGE_VERSION=31.30.1
MOCK_DKMS_FIRMWARE_PACKAGE_VERSION=31.30.1
MOCK_DKMS_STATUS='amdgpu/31.30.1, 7.0.0, x86_64: installed'
MOCK_REQUIRE_DRIVER_MIGRATION_BEFORE_APT=true
assert_success "mocked DKMS APT lifecycle migrates an old driver" run_mocked_main apt --gpu-arch gfx1201 --driver-mode dkms --dkms-cleanup always
assert_contains "$RECORDED_COMMANDS" "dpkg --purge amdgpu-dkms amdgpu-dkms-firmware" "DKMS main flow purges the exact old driver packages"
assert_command_before "dpkg --purge amdgpu-dkms amdgpu-dkms-firmware" "apt-get update" "$RECORDED_COMMANDS" "driver migration completes before prerequisite APT work"
assert_contains "$RECORDED_COMMANDS" "apt-get install --yes amdgpu-dkms" "DKMS main flow installs AMDGPU 31.40"
assert_contains "$RECORDED_COMMANDS" "apt-get install --yes amdrocm-core-sdk7.14-gfx1201" "DKMS main flow installs its APT package"

MOCK_DKMS_PACKAGE_VERSION=31.30.1
MOCK_DKMS_FIRMWARE_PACKAGE_VERSION=''
MOCK_DKMS_STATUS='amdgpu/31.30.1, 7.0.0, x86_64: installed'
MOCK_REQUIRE_DRIVER_MIGRATION_BEFORE_APT=true
MOCK_FAIL_FRAGMENT="dpkg --purge amdgpu-dkms"
assert_status 23 "failed DKMS purge stops the lifecycle before prerequisite APT work" run_mocked_main apt --gpu-arch gfx1201 --driver-mode dkms --dkms-cleanup always
assert_not_contains "$RECORDED_COMMANDS" "apt-get update" "failed driver migration does not start prerequisite APT work"
assert_not_contains "$RECORDED_COMMANDS" "amdrocm-core-sdk7.14-gfx1201" "failed driver migration does not install ROCm"

MOCK_DKMS_PACKAGE_VERSION=""
MOCK_DKMS_FIRMWARE_PACKAGE_VERSION=""
MOCK_DKMS_STATUS=""
MOCK_REQUIRE_DRIVER_MIGRATION_BEFORE_APT=false
MOCK_INSTALLED_LEGACY_ROCM_PACKAGES="rocm"
MOCK_FAIL_FRAGMENT="apt-get purge --yes rocm"
assert_status 23 "failed legacy ROCm purge stops the lifecycle before current package install" run_mocked_main apt --gpu-arch gfx1151
assert_not_contains "$RECORDED_COMMANDS" "apt-get install --yes amdrocm-core-sdk7.14-gfx1151" "failed legacy migration does not install the current ROCm package"
assert_not_contains "$MANAGED_FILES" "/etc/profile.d/rocm.sh" "failed legacy migration does not configure the ROCm environment"

MOCK_INSTALLED_LEGACY_ROCM_PACKAGES=""
MOCK_FAIL_FRAGMENT=""
assert_success "mocked tarball lifecycle runs through the real steps" run_mocked_main tarball --gpu-arch gfx942 --driver-mode dkms
assert_contains "$RECORDED_COMMANDS" "therock-dist-linux-gfx94X-dcgpu-7.14.0.tar.gz" "Instinct main flow downloads the reviewed tarball"
assert_contains "$RECORDED_COMMANDS" "apt-get install --yes amdgpu-dkms" "explicit DKMS main flow installs AMDGPU 31.40"

MOCK_DKMS_PACKAGE_VERSION=""
MOCK_DKMS_FIRMWARE_PACKAGE_VERSION=""
MOCK_DKMS_STATUS=""
MOCK_REQUIRE_DRIVER_MIGRATION_BEFORE_APT=false
MOCK_FAIL_FRAGMENT=""
assert_success "mocked multi-GFX pip lifecycle runs through the real steps" run_mocked_main pip --gpu-arch gfx1201 --gpu-arch gfx1151
assert_eq "$multi_gfxes" "${INSTALL_PLAN[gfxes]}" "multi-GFX pip plan retains both normalized architectures"
assert_eq "$multi_pip_requirement" "${INSTALL_PLAN[artifacts]}" "multi-GFX pip plan composes one requirement"
assert_contains "$RECORDED_COMMANDS" 'rocm\[libraries\,device-gfx1151\,device-gfx1201\]==7.14.0' "multi-GFX pip installs one requirement containing both device extras"
assert_eq "1" "$(recorded_command_count "/opt/rocm-7.14.0-venv/bin/pip install --index-url" "$RECORDED_COMMANDS")" "multi-GFX pip performs one install transaction"

assert_success "mocked multi-GFX tarball lifecycle runs through the real steps" run_mocked_main tarball --gpu-arch gfx1201 --gpu-arch gfx1151
assert_eq "$multi_gfxes" "${INSTALL_PLAN[gfxes]}" "multi-GFX tarball plan retains both normalized architectures"
assert_eq "$ROCM_MULTIARCH_TARBALL_ARTIFACT" "${INSTALL_PLAN[artifacts]}" "multi-GFX tarball plan selects the full multiarch artifact"
assert_contains "$RECORDED_COMMANDS" "$ROCM_MULTIARCH_TARBALL_ARTIFACT" "multi-GFX tarball downloads the full multiarch artifact"
assert_eq "1" "$(recorded_command_count "curl -fL --retry 0 --output" "$RECORDED_COMMANDS")" "multi-GFX tarball downloads one artifact"
assert_not_contains "$RECORDED_COMMANDS" 'therock-dist-linux-gfx1151-7.14.0.tar.gz' "multi-GFX tarball does not download the gfx1151 artifact"
assert_not_contains "$RECORDED_COMMANDS" 'therock-dist-linux-gfx120X-all-7.14.0.tar.gz' "multi-GFX tarball does not download a GFX-family artifact"

MOCK_KERNEL_VERSION=6.8.0-generic
reset_test_state
assert_fails "kernel validation stops the main flow before mutation" main --gpu-arch gfx1151 --method apt --non-interactive --skip-reboot
assert_eq "" "$RECORDED_COMMANDS" "kernel rejection records no mutation command"

reset_lifecycle_state
GPU_DETECTION_DRM_ROOT="${TEST_TEMP_ROOT}/missing-drm-root"
MOCK_ROCMINFO_OUTPUT=$'  Name:                    gfx1201\n  Name:                    gfx1151\n'
verify_only_output="${TEST_TEMP_ROOT}/verify-only-output"
assert_success "verify-only resolves every repeated explicit GPU override without mutations" main --verify-only --method apt --gpu-arch gfx1201 --gpu-arch gfx1151 --gpu-arch gfx1201 > "$verify_only_output"
assert_eq $'gfx1151\ngfx1201' "$GPU_ARCHES" "verify-only normalizes the complete explicit GPU collection"
assert_eq "0" "${#INSTALL_PLAN[@]}" "verify-only keeps install plan state empty"
assert_eq "" "$RECORDED_COMMANDS$MANAGED_FILES$PASSWORD_UPDATES" "verify-only runs no install or configuration mutation commands"
assert_eq $'/opt/rocm/core-7.14/bin/rocminfo\n/opt/rocm/core-7.14/bin/amd-smi version' "$(<"$CAPTURED_COMMANDS_FILE")" "verify-only captures only the selected method verification binaries"
unset GPU_DETECTION_DRM_ROOT

reset_lifecycle_state
heterogeneous_fixture="${ROOT_DIR}/tests/fixtures/gfx1151-gfx1201"
GPU_DETECTION_KFD_ROOT="${heterogeneous_fixture}/kfd"
GPU_DETECTION_DRM_ROOT="${TEST_TEMP_ROOT}/missing-drm-root"
MOCK_ROCMINFO_OUTPUT=$'  Name:                    gfx1201\n  Name:                    gfx1151\n'
assert_success "verify-only automatically resolves every heterogeneous KFD GPU without mutations" main --verify-only --method apt > "$verify_only_output"
assert_eq $'gfx1151\ngfx1201' "$GPU_ARCHES" "automatic verify-only resolves the complete KFD GPU collection"
assert_eq "0" "${#INSTALL_PLAN[@]}" "automatic verify-only keeps install plan state empty"
assert_eq "" "$RECORDED_COMMANDS$MANAGED_FILES$PASSWORD_UPDATES" "automatic verify-only runs no install or configuration mutation commands"
assert_eq $'/opt/rocm/core-7.14/bin/rocminfo\n/opt/rocm/core-7.14/bin/amd-smi version' "$(<"$CAPTURED_COMMANDS_FILE")" "automatic verify-only captures only verification binaries"
unset GPU_DETECTION_KFD_ROOT GPU_DETECTION_DRM_ROOT

resolve_gpu_identity() { fail "uninstall must not resolve GPU identity"; }
reset_lifecycle_state
assert_success "uninstall exits before GPU identity resolution" main --uninstall --non-interactive

finish_tests "installer lifecycle"
