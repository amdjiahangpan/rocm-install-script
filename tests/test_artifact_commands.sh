#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helpers.sh"

artifact_fixture="${ROOT_DIR}/tests/fixtures/rocm-7.14-artifacts.tsv"

IFS= read -r fixture_header < "$artifact_fixture"
assert_eq $'gfx\tpackage_suffix\tpip_extra\ttarball_artifact' "$fixture_header" "artifact fixture contains apt, pip, and tarball data only"

assert_eq "apt|ubuntu2404" "$(resolve_os_record ubuntu-24.04.4)" "Ubuntu 24.04 uses the ubuntu2404 APT repository"
assert_eq "apt|ubuntu2604" "$(resolve_os_record ubuntu-26.04)" "Ubuntu 26.04 uses the ubuntu2604 APT repository"
assert_eq "https://repo.amd.com/rocm/packages-multi-arch/ubuntu2404" "${ROCM_PACKAGES_ROOT}/ubuntu2404" "Ubuntu 24.04 APT repository URL is exact"
assert_eq "https://repo.amd.com/rocm/packages-multi-arch/ubuntu2604" "${ROCM_PACKAGES_ROOT}/ubuntu2604" "Ubuntu 26.04 APT repository URL is exact"

row_count=0
while IFS=$'\t' read -r gfx package_suffix pip_extra tarball_artifact; do
    [[ "$gfx" == gfx ]] && continue
    row_count=$((row_count + 1))
    assert_eq "amdrocm-core-sdk7.14-${package_suffix}" "$(resolve_package_name full "$gfx")" "${gfx} selects the full SDK package"
    assert_eq "rocm[libraries,${pip_extra}]==7.14.0" "$(resolve_pip_requirement "$gfx")" "${gfx} selects the pinned wheel extra"
    assert_eq "$tarball_artifact" "$(resolve_tarball_artifact "$gfx")" "${gfx} selects the reviewed tarball"
done < "$artifact_fixture"
assert_eq "15" "$row_count" "all supported architectures have explicit artifacts"

assert_eq "amdrocm-core-sdk7.14-gfx1151" "$(resolve_package_name full gfx1151)" "Ryzen full SDK package is architecture-specific"
assert_eq "rocm[libraries,device-gfx1201]==7.14.0" "$(resolve_pip_requirement gfx1201)" "RX 9070 wheel requirement is architecture-specific"
assert_eq "therock-dist-linux-gfx94X-dcgpu-7.14.0.tar.gz" "$(resolve_tarball_artifact gfx942)" "MI300X tarball uses the reviewed gfx94X bundle"

assert_fails "unknown package architecture has no fallback" resolve_package_name full gfx9999
assert_fails "unknown pip architecture has no fallback" resolve_pip_requirement gfx9999
assert_fails "unknown tarball architecture has no fallback" resolve_tarball_artifact gfx9999
assert_fails "generic package selection is unavailable" resolve_package_name full all
assert_fails "generic wheel selection is unavailable" resolve_pip_requirement all
assert_fails "generic tarball selection is unavailable" resolve_tarball_artifact all

assert_command_before() {
    local first=$1 second=$2 commands=$3 message=$4 prefix

    [[ "$commands" == *"$first"* && "$commands" == *"$second"* ]] || fail "$message (missing command)"
    prefix=${commands%%"$second"*}
    [[ "$prefix" == *"$first"* ]] || fail "$message (wrong order)"
    PASS_COUNT=$((PASS_COUNT + 1))
}

set_artifact_plan() {
    INSTALL_PLAN=(
        [repo_slug]=$1
        [artifact]=$2
    )
}

MOCK_DPKG_QUERY_OUTPUT=""
dpkg-query() {
    [[ -n "$MOCK_DPKG_QUERY_OUTPUT" ]] || return 0
    printf '%s\n' "$MOCK_DPKG_QUERY_OUTPUT"
}

layout_root="${TEST_TEMP_ROOT}/rocm"
layout_run_cmd() {
    recording_run_cmd "$@"
    command "$@"
}

reset_test_state
normal_legacy_root="${layout_root}-7.1.0"
mkdir -p "${normal_legacy_root}/core-7.14"
ln -s "$normal_legacy_root" "$layout_root"
captured_legacy_root=$(capture_legacy_rocm_layout_target "$layout_root")
rm "$layout_root"
run_cmd() { layout_run_cmd "$@"; }
assert_success "legacy symlink target is restored after package purge" repair_legacy_rocm_layout "$layout_root" "$captured_legacy_root"
assert_success "restored legacy layout contains the APT verification root" rocm_apt_verification_root_exists "$layout_root"
assert_contains "$RECORDED_COMMANDS" "mv ${normal_legacy_root} ${layout_root}" "legacy symlink recovery atomically promotes the captured target"

reset_test_state
rm -rf "$layout_root" "${layout_root}-7.1.0"
interrupted_legacy_root="${layout_root}-7.1.0"
mkdir -p "${interrupted_legacy_root}/core-7.14"
run_cmd() { layout_run_cmd "$@"; }
assert_success "interrupted legacy layout is recovered from one candidate" repair_legacy_rocm_layout "$layout_root" ""
assert_success "interrupted recovery creates the APT verification root" rocm_apt_verification_root_exists "$layout_root"
assert_contains "$RECORDED_COMMANDS" "mv ${interrupted_legacy_root} ${layout_root}" "interrupted recovery atomically promotes its only candidate"

reset_test_state
rm -rf "$layout_root" "${layout_root}-7.1.0" "${layout_root}-7.1.1"
mkdir -p "${layout_root}-7.1.0/core-7.14" "${layout_root}-7.1.1/core-7.14"
run_cmd() { layout_run_cmd "$@"; }
assert_fails "multiple interrupted legacy layout candidates fail safely" repair_legacy_rocm_layout "$layout_root" ""
assert_fails "ambiguous recovery leaves the active ROCm root absent" test -e "$layout_root"
assert_not_contains "$RECORDED_COMMANDS" "mv " "ambiguous recovery does not move either candidate"

reset_test_state
rm -rf "$layout_root" "${layout_root}-7.1.0" "${layout_root}-7.1.1"
mkdir -p "${layout_root}/core-7.14"
run_cmd() { layout_run_cmd "$@"; }
assert_success "existing correct ROCm root is left unchanged" repair_legacy_rocm_layout "$layout_root" ""
assert_eq "" "$RECORDED_COMMANDS" "existing correct ROCm root needs no layout command"

reset_test_state
rm -rf "$layout_root" "${layout_root}-7.1.0"
mkdir -p "${layout_root}-7.1.0/core-7.14"
layout_move_fails() {
    recording_run_cmd "$@"
    [[ "$1" != mv ]] || return 23
    command "$@"
}
run_cmd() { layout_move_fails "$@"; }
assert_status 23 "legacy layout move failure propagates" repair_legacy_rocm_layout "$layout_root" ""
assert_fails "failed legacy layout move leaves the active root absent" test -e "$layout_root"

reset_test_state
rm -rf "$layout_root" "${layout_root}-7.1.0"
run_cmd() { layout_run_cmd "$@"; }
assert_success "fresh APT host creates the active ROCm root" repair_legacy_rocm_layout "$layout_root" ""
assert_success "fresh APT host creates the active ROCm directory" test -d "$layout_root"
assert_contains "$RECORDED_COMMANDS" "install -d -m 0755 ${layout_root}" "fresh APT host creates its active ROCm directory"

reset_test_state
MOCK_DPKG_QUERY_OUTPUT=$'rocm-dev\tinstalled\nrocm\tinstalled\nrocm-core\tconfig-files\nrocmfoo\tinstalled\nrocm:amd64\tinstalled\namdrocm\tinstalled\namdrocm-core-sdk7.14-gfx1151\tinstalled'
assert_eq $'rocm\nrocm-dev' "$(detect_legacy_rocm_packages)" "legacy package detection selects only installed exact rocm names in deterministic order"

capture_legacy_rocm_layout_target() { printf '%s\n' /opt/rocm-7.1.0; }
repair_legacy_rocm_layout() { recording_run_cmd mv "$2" "$1"; }
rocm_apt_verification_root_exists() { return 0; }

reset_test_state
run_cmd() { recording_run_cmd "$@"; }
rocm_apt_verification_root_exists() { return 0; }
MOCK_DPKG_QUERY_OUTPUT=$'rocm-dev\tinstalled\nrocm\tinstalled\namdrocm-core-sdk7.14-gfx1151\tinstalled'
set_artifact_plan ubuntu2604 "$(resolve_package_name full gfx1151)"
assert_success "APT installation configures the ROCm multi-arch repository" install_rocm_apt
assert_contains "$RECORDED_COMMANDS" "install -d -m 0755 /etc/apt/keyrings" "APT creates the keyring directory"
assert_contains "$RECORDED_COMMANDS" "${ROCM_GPG_KEY_URL}" "APT downloads the ROCm signing key"
assert_contains "$RECORDED_COMMANDS" "/etc/apt/keyrings/amdrocm.gpg" "APT stores the dearmored key at the required path"
assert_contains "$RECORDED_COMMANDS" "${ROCM_PACKAGES_ROOT}/ubuntu2604" "APT writes the Ubuntu 26.04 ROCm source URL"
assert_contains "$RECORDED_COMMANDS" 'stable\ main' "APT writes the stable ROCm source suite and component"
assert_contains "$RECORDED_COMMANDS" "apt-get update" "APT refreshes package metadata after repository setup"
assert_contains "$RECORDED_COMMANDS" "apt-get purge --yes rocm rocm-dev" "APT removes only installed legacy ROCm packages"
assert_not_contains "$RECORDED_COMMANDS" "apt-get purge --yes amdrocm" "APT never purges amdrocm packages during legacy migration"
assert_command_before "apt-get purge --yes rocm rocm-dev" "apt-get install --yes amdrocm-core-sdk7.14-gfx1151" "$RECORDED_COMMANDS" "legacy ROCm purge happens before the current APT package install"
assert_command_before "apt-get purge --yes rocm rocm-dev" "mv /opt/rocm-7.1.0 /opt/rocm" "$RECORDED_COMMANDS" "legacy layout repair happens after package purge"
assert_command_before "mv /opt/rocm-7.1.0 /opt/rocm" "apt-get install --yes amdrocm-core-sdk7.14-gfx1151" "$RECORDED_COMMANDS" "legacy layout repair happens before current package installation"
assert_contains "$RECORDED_COMMANDS" "apt-get install --yes amdrocm-core-sdk7.14-gfx1151" "APT installs the exact full SDK package"

reset_test_state
RUN_CMD_STATUS=23
set_artifact_plan ubuntu2404 "$(resolve_package_name full gfx1201)"
assert_status 23 "a required APT repository command propagates its exact status" install_rocm_apt
assert_not_contains "$RECORDED_COMMANDS" "apt-get update" "APT does not continue after a repository failure"

apt_purge_fails() {
    recording_run_cmd "$@"
    [[ "$1 $2" != "apt-get purge" ]] || return 23
}

reset_test_state
MOCK_DPKG_QUERY_OUTPUT=$'rocm\tinstalled\namdrocm-core-sdk7.14-gfx1151\tinstalled'
run_cmd() { apt_purge_fails "$@"; }
set_artifact_plan ubuntu2604 "$(resolve_package_name full gfx1151)"
assert_status 23 "legacy ROCm purge failure stops the current APT install" install_rocm_apt
assert_contains "$RECORDED_COMMANDS" "apt-get purge --yes rocm" "APT attempts the exact legacy package purge"
assert_not_contains "$RECORDED_COMMANDS" "apt-get install --yes amdrocm-core-sdk7.14-gfx1151" "APT does not install the current package after a legacy purge failure"

reset_test_state
RUN_CMD_STATUS=0
MOCK_DPKG_QUERY_OUTPUT=""
run_cmd() { recording_run_cmd "$@"; }
set_artifact_plan ubuntu2604 "$(resolve_pip_requirement gfx1151)"
assert_success "pip installs ROCm into the fixed virtual environment" install_rocm_pip
assert_contains "$RECORDED_COMMANDS" "python3 -m venv /opt/rocm-7.14.0-venv" "pip creates the versioned virtual environment"
assert_contains "$RECORDED_COMMANDS" "/opt/rocm-7.14.0-venv/bin/pip install --index-url ${ROCM_WHL_INDEX}" "pip uses the multi-architecture wheel index"
assert_contains "$RECORDED_COMMANDS" 'rocm\[libraries\,device-gfx1151\]==7.14.0' "pip installs the exact architecture requirement"

tarball_temp_dir="${TEST_TEMP_ROOT}/tarball-work"
tarball_stage_dir="${tarball_temp_dir}/staging"
tarball_backup_dir="${tarball_temp_dir}/previous-rocm-7.14.0"
mktemp() {
    [[ "$1" == -d ]] || return 1
    printf '%s\n' "$tarball_temp_dir"
}

reset_test_state
tarball_artifact=$(resolve_tarball_artifact gfx942)
set_artifact_plan ubuntu2404 "$tarball_artifact"
assert_success "tarball installation stages the explicit reviewed artifact" install_rocm_tarball
assert_contains "$RECORDED_COMMANDS" "${ROCM_TARBALL_ROOT}${tarball_artifact}" "tarball download uses the explicit artifact URL"
assert_contains "$RECORDED_COMMANDS" "tar -xzf ${tarball_temp_dir}/${tarball_artifact}" "tarball extraction uses the downloaded artifact"
assert_contains "$RECORDED_COMMANDS" "-C ${tarball_stage_dir}" "tarball extraction targets only temporary staging"
assert_command_before "tar -xzf" "mv ${tarball_stage_dir} /opt/rocm-7.14.0" "$RECORDED_COMMANDS" "tarball promotes staging only after extraction"
assert_command_before "mv ${tarball_stage_dir} /opt/rocm-7.14.0" "ln -sfn /opt/rocm-7.14.0 /opt/rocm" "$RECORDED_COMMANDS" "tarball updates the active link only after promotion"
assert_contains "$RECORDED_COMMANDS" "rm -rf ${tarball_temp_dir}" "tarball cleanup removes the temporary directory"

tarball_extract_fails() {
    recording_run_cmd "$@"
    if [[ "$1" == tar ]]; then
        return 23
    fi
}

reset_test_state
set_artifact_plan ubuntu2404 "$tarball_artifact"
run_cmd() { tarball_extract_fails "$@"; }
assert_status 23 "tarball extraction failure propagates its exact status" install_rocm_tarball
assert_not_contains "$RECORDED_COMMANDS" "mv ${tarball_stage_dir} /opt/rocm-7.14.0" "tarball extraction failure leaves the prior final root untouched"
assert_not_contains "$RECORDED_COMMANDS" "ln -sfn /opt/rocm-7.14.0 /opt/rocm" "tarball extraction failure leaves the active link untouched"
assert_contains "$RECORDED_COMMANDS" "rm -rf ${tarball_temp_dir}" "tarball extraction failure still cleans the temporary directory"

tarball_move_fails() {
    recording_run_cmd "$@"
    if [[ "$1" == test ]]; then
        return 0
    fi
    if [[ "$1" == mv && "$2" == "$tarball_stage_dir" && "$3" == /opt/rocm-7.14.0 ]]; then
        return 23
    fi
}

reset_test_state
set_artifact_plan ubuntu2404 "$tarball_artifact"
run_cmd() { tarball_move_fails "$@"; }
assert_status 23 "tarball promotion failure propagates its exact status" install_rocm_tarball
assert_command_before "mv /opt/rocm-7.14.0 ${tarball_backup_dir}" "mv ${tarball_stage_dir} /opt/rocm-7.14.0" "$RECORDED_COMMANDS" "tarball saves the prior root before promotion"
assert_command_before "mv ${tarball_stage_dir} /opt/rocm-7.14.0" "mv ${tarball_backup_dir} /opt/rocm-7.14.0" "$RECORDED_COMMANDS" "tarball restores the prior root after promotion failure"
assert_not_contains "$RECORDED_COMMANDS" "ln -sfn /opt/rocm-7.14.0 /opt/rocm" "tarball promotion failure leaves the prior active link untouched"
assert_contains "$RECORDED_COMMANDS" "rm -rf ${tarball_temp_dir}" "tarball promotion failure cleans staging and temporary files"

tarball_symlink_fails_with_existing_root() {
    recording_run_cmd "$@"
    if [[ "$1" == test ]]; then
        return 0
    fi
    if [[ "$1" == ln ]]; then
        return 23
    fi
}

reset_test_state
set_artifact_plan ubuntu2404 "$tarball_artifact"
run_cmd() { tarball_symlink_fails_with_existing_root "$@"; }
assert_status 23 "symlink activation failure preserves its original status after rollback" install_rocm_tarball
assert_command_before "ln -sfn /opt/rocm-7.14.0 /opt/rocm" "rm -rf /opt/rocm-7.14.0" "$RECORDED_COMMANDS" "symlink failure removes the newly promoted root"
assert_command_before "rm -rf /opt/rocm-7.14.0" "mv ${tarball_backup_dir} /opt/rocm-7.14.0" "$RECORDED_COMMANDS" "symlink failure restores the prior root after removing the new root"
assert_contains "$RECORDED_COMMANDS" "rm -rf ${tarball_temp_dir}" "symlink rollback cleans temporary staging after restoring the prior root"

tarball_symlink_fails_without_existing_root() {
    recording_run_cmd "$@"
    if [[ "$1" == test ]]; then
        return 1
    fi
    if [[ "$1" == ln ]]; then
        return 23
    fi
}

reset_test_state
set_artifact_plan ubuntu2404 "$tarball_artifact"
run_cmd() { tarball_symlink_fails_without_existing_root "$@"; }
assert_status 23 "symlink activation failure preserves its original status without a prior root" install_rocm_tarball
assert_contains "$RECORDED_COMMANDS" "rm -rf /opt/rocm-7.14.0" "symlink failure without a prior root removes the new root"
assert_not_contains "$RECORDED_COMMANDS" "mv /opt/rocm-7.14.0 ${tarball_backup_dir}" "symlink failure without a prior root has no backup move"
assert_not_contains "$RECORDED_COMMANDS" "mv ${tarball_backup_dir} /opt/rocm-7.14.0" "symlink failure without a prior root has no restore move"
assert_contains "$RECORDED_COMMANDS" "rm -rf ${tarball_temp_dir}" "symlink failure without a prior root cleans temporary staging"

tarball_symlink_rollback_fails() {
    recording_run_cmd "$@"
    if [[ "$1" == test ]]; then
        return 0
    fi
    if [[ "$1" == ln ]]; then
        return 23
    fi
    if [[ "$1" == mv && "$2" == "$tarball_backup_dir" && "$3" == /opt/rocm-7.14.0 ]]; then
        return 41
    fi
}

reset_test_state
set_artifact_plan ubuntu2404 "$tarball_artifact"
run_cmd() { tarball_symlink_rollback_fails "$@"; }
assert_status 41 "failed prior-root restoration reports the rollback failure" install_rocm_tarball
assert_contains "$RECORDED_COMMANDS" "mv ${tarball_backup_dir} /opt/rocm-7.14.0" "failed rollback attempts to restore the prior root"
assert_not_contains "$RECORDED_COMMANDS" "rm -rf ${tarball_temp_dir}" "failed rollback preserves the temporary backup for recovery"

finish_tests "artifact command"
