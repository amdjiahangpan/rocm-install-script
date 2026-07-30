#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helpers.sh"

MANAGED_FILES=""
PASSWORD_UPDATES=""
CAPTURED_COMMANDS_FILE=""
MOCK_FAIL_FRAGMENT=""
MOCK_GROUPS_PRESENT=false
MOCK_ROCMINFO_OUTPUT="Agent 2"
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
    MOCK_ROCMINFO_OUTPUT="Agent 2"
    MOCK_AMD_SMI_OUTPUT="ROCm version: 7.14.0"
    MOCK_INSTALLED_ROCM_PACKAGES=""
    REBOOT_REQUIRED=false
    OS_ID=ubuntu
    OS_VERSION=24.04
    ARCH=x86_64
    KERNEL_VERSION=6.17.0-generic
    INSTALL_METHOD=apt
    INSTALL_PLAN=(
        [gfx]=gfx1151
        [os_key]=ubuntu-24.04.4
        [repo_slug]=ubuntu2404
        [method]=apt
        [artifact]=amdrocm-core-sdk7.14-gfx1151
        [driver_mode]=inbox
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

reset_lifecycle_state
assert_success "APT verification uses the selected absolute binary paths" verify_installation
assert_eq $'/opt/rocm/core-7.14/bin/rocminfo\n/opt/rocm/core-7.14/bin/amd-smi version' "$(<"$CAPTURED_COMMANDS_FILE")" "APT verification captures only the current package-root binaries"

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
    local gfx=$1 method=$2 output_file="${TEST_TEMP_ROOT}/main-output"
    shift 2

    reset_test_state
    MANAGED_FILES=""
    PASSWORD_UPDATES=""
    main --gpu-arch "$gfx" --method "$method" --non-interactive --skip-ssh --skip-reboot "$@" > "$output_file"
}

MOCK_DKMS_PACKAGE_VERSION=""
MOCK_DKMS_STATUS=""
MOCK_KERNEL_VERSION=7.0.0-generic
MOCK_INSTALLED_LEGACY_ROCM_PACKAGES="rocm-dev rocm amdrocm-core-sdk7.14-gfx1151"
assert_success "mocked inbox APT lifecycle runs through the real steps" run_mocked_main gfx1151 apt
assert_contains "$RECORDED_COMMANDS" "apt-get purge --yes rocm rocm-dev" "main flow purges only the installed legacy ROCm packages"
assert_not_contains "$RECORDED_COMMANDS" "apt-get purge --yes amdrocm" "main flow keeps amdrocm packages out of legacy migration purges"
assert_command_before "apt-get purge --yes rocm rocm-dev" "apt-get install --yes amdrocm-core-sdk7.14-gfx1151" "$RECORDED_COMMANDS" "main flow purges legacy ROCm before installing the current package"
assert_contains "$RECORDED_COMMANDS" "apt-get install --yes amdrocm-core-sdk7.14-gfx1151" "main flow installs the architecture-specific APT package"
assert_not_contains "$RECORDED_COMMANDS" "apt-get install --yes amdgpu-dkms" "auto driver mode keeps the inbox driver"

MOCK_DKMS_PACKAGE_VERSION=31.30.1
MOCK_DKMS_FIRMWARE_PACKAGE_VERSION=31.30.1
MOCK_DKMS_STATUS='amdgpu/31.30.1, 7.0.0, x86_64: installed'
MOCK_REQUIRE_DRIVER_MIGRATION_BEFORE_APT=true
assert_success "mocked DKMS APT lifecycle migrates an old driver" run_mocked_main gfx1201 apt --driver-mode dkms --dkms-cleanup always
assert_contains "$RECORDED_COMMANDS" "dpkg --purge amdgpu-dkms amdgpu-dkms-firmware" "DKMS main flow purges the exact old driver packages"
assert_command_before "dpkg --purge amdgpu-dkms amdgpu-dkms-firmware" "apt-get update" "$RECORDED_COMMANDS" "driver migration completes before prerequisite APT work"
assert_contains "$RECORDED_COMMANDS" "apt-get install --yes amdgpu-dkms" "DKMS main flow installs AMDGPU 31.40"
assert_contains "$RECORDED_COMMANDS" "apt-get install --yes amdrocm-core-sdk7.14-gfx1201" "DKMS main flow installs its APT package"

MOCK_DKMS_PACKAGE_VERSION=31.30.1
MOCK_DKMS_FIRMWARE_PACKAGE_VERSION=''
MOCK_DKMS_STATUS='amdgpu/31.30.1, 7.0.0, x86_64: installed'
MOCK_REQUIRE_DRIVER_MIGRATION_BEFORE_APT=true
MOCK_FAIL_FRAGMENT="dpkg --purge amdgpu-dkms"
assert_status 23 "failed DKMS purge stops the lifecycle before prerequisite APT work" run_mocked_main gfx1201 apt --driver-mode dkms --dkms-cleanup always
assert_not_contains "$RECORDED_COMMANDS" "apt-get update" "failed driver migration does not start prerequisite APT work"
assert_not_contains "$RECORDED_COMMANDS" "amdrocm-core-sdk7.14-gfx1201" "failed driver migration does not install ROCm"

MOCK_DKMS_PACKAGE_VERSION=""
MOCK_DKMS_FIRMWARE_PACKAGE_VERSION=""
MOCK_DKMS_STATUS=""
MOCK_REQUIRE_DRIVER_MIGRATION_BEFORE_APT=false
MOCK_INSTALLED_LEGACY_ROCM_PACKAGES="rocm"
MOCK_FAIL_FRAGMENT="apt-get purge --yes rocm"
assert_status 23 "failed legacy ROCm purge stops the lifecycle before current package install" run_mocked_main gfx1151 apt
assert_not_contains "$RECORDED_COMMANDS" "apt-get install --yes amdrocm-core-sdk7.14-gfx1151" "failed legacy migration does not install the current ROCm package"
assert_not_contains "$MANAGED_FILES" "/etc/profile.d/rocm.sh" "failed legacy migration does not configure the ROCm environment"

MOCK_INSTALLED_LEGACY_ROCM_PACKAGES=""
MOCK_FAIL_FRAGMENT=""
assert_success "mocked tarball lifecycle runs through the real steps" run_mocked_main gfx942 tarball --driver-mode dkms
assert_contains "$RECORDED_COMMANDS" "therock-dist-linux-gfx94X-dcgpu-7.14.0.tar.gz" "Instinct main flow downloads the reviewed tarball"
assert_contains "$RECORDED_COMMANDS" "apt-get install --yes amdgpu-dkms" "explicit DKMS main flow installs AMDGPU 31.40"

MOCK_KERNEL_VERSION=6.8.0-generic
reset_test_state
assert_fails "kernel validation stops the main flow before mutation" main --gpu-arch gfx1151 --method apt --non-interactive --skip-reboot
assert_eq "" "$RECORDED_COMMANDS" "kernel rejection records no mutation command"

finish_tests "installer lifecycle"
