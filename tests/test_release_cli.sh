#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034,SC2153
set -euo pipefail
# shellcheck source=test_helpers.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helpers.sh"

parse_succeeds() {
    reset_defaults
    parse_args "$@"
}

parse_fails() {
    reset_defaults
    parse_args "$@"
}

run_invalid_option() {
    local launcher=$1 stderr_file=${TEST_TEMP_ROOT}/entrypoint-stderr
    local stdout_file=${TEST_TEMP_ROOT}/entrypoint-stdout status
    local -a command

    case "$launcher" in
        bash) command=(bash "${ROOT_DIR}/rocm-install.sh" --not-a-valid-option) ;;
        direct) command=("${ROOT_DIR}/rocm-install.sh" --not-a-valid-option) ;;
        *) return 64 ;;
    esac
    if env -u ROCM_INSTALL_LIBRARY_MODE "${command[@]}" >"$stdout_file" 2>"$stderr_file"; then
        status=0
    else
        status=$?
    fi
    ENTRYPOINT_STDOUT=$(<"$stdout_file")
    ENTRYPOINT_STDERR=$(<"$stderr_file")
    return "$status"
}

assert_eq "7.14.0" "$ROCM_VERSION" "release is fixed at ROCm 7.14.0"
assert_eq "7.14" "$ROCM_SERIES" "package series is fixed at 7.14"
assert_eq "31.40" "$AMDGPU_RELEASE" "AMDGPU migration release is fixed at 31.40"
assert_eq "https://repo.amd.com/rocm/packages-multi-arch" "$ROCM_PACKAGES_ROOT" "APT package root is fixed"
assert_eq "https://repo.amd.com/rocm/whl-multi-arch/" "$ROCM_WHL_INDEX" "wheel index is fixed"
assert_eq "https://repo.amd.com/rocm/tarball-multi-arch/" "$ROCM_TARBALL_ROOT" "tarball root is fixed"
assert_eq "https://rocm.docs.amd.com/en/latest/install/rocm.html?fam=all&w=compute&os=ubuntu&ubuntu-ver=24.04&i=runfile" "$ROCM_GPU_LOOKUP_URL" "official GPU lookup URL is fixed"
assert_eq "https://github.com/amdjiahangpan/hello-rocm/blob/master/docs/zh/00-environment/rocm-gpu-architecture-table.md" "$ROCM_GPU_LOOKUP_ZH_URL" "Chinese GPU lookup URL is fixed"
assert_eq "https://repo.radeon.com/rocm/installer/rocm-runfile-installer/rocm-rel-7.14/rocm-installer-7.14.0-7.run" "$ROCM_RUNFILE_URL" "official ROCm 7.14 Runfile URL is fixed"

reset_defaults
assert_eq "compute" "$WORKLOAD" "compute is the only default workload"
assert_eq "apt" "$INSTALL_METHOD" "APT is the default install method"
assert_eq "full" "$PACKAGE_PROFILE" "the full SDK is installed by default"
assert_eq "" "$GPU_ARCHES" "GPU architecture collection is empty by default"
assert_eq "" "$GPU_PRODUCT_NAMES" "GPU product-name collection is empty by default"
assert_eq "false" "$SKIP_SSH" "SSH setup is enabled by default"
assert_eq "0" "$REBOOT_DELAY" "reboot is immediate by default"
assert_eq "false" "$PREPARE_KERNEL" "kernel preparation is disabled by default"
assert_eq "false" "$REBOOT_AFTER_KERNEL" "kernel reboot automation is disabled by default"
assert_eq "false" "$ALLOW_UNQUALIFIED_KERNEL" "unqualified kernel override is disabled by default"

GPU_ARCH=gfx1151
GPU_PRODUCT_NAME='AMD Radeon RX 9060 XT'
INSTALL_PLAN=([stale]=value)
reset_defaults
assert_fails "legacy scalar GPU architecture is cleared" test -v GPU_ARCH
assert_fails "legacy scalar GPU product name is cleared" test -v GPU_PRODUCT_NAME
assert_eq "0" "${#INSTALL_PLAN[@]}" "reset clears stale install plans"

assert_eq $'AMD Radeon RX 9060 XT\ngfx1100\ngfx1151' "$(normalize_records $'gfx1151\nAMD Radeon RX 9060 XT\ngfx1100\ngfx1151')" "records retain spaces and sort uniquely"
assert_fails "empty record collections are rejected" normalize_records ""
assert_fails "blank records are rejected" normalize_records $'gfx1151\n\ngfx1100'
assert_fails "carriage-return records are rejected" normalize_records $'gfx1151\ngfx1100\r'
assert_fails "multiple record collection arguments are rejected" normalize_records gfx1151 gfx1100

assert_eq $'gfx1100\ngfx1151' "$(normalize_gfxes $'gfx1151\ngfx1100\ngfx1151')" "supported gfx records normalize uniquely"
assert_fails "invalid gfx rejects the complete collection" normalize_gfxes $'gfx1151\ngfx9999'
assert_eq "gfx1100,gfx1151" "$(records_to_csv $'gfx1151\ngfx1100\ngfx1151')" "normalized records convert to CSV"

assert_success "APT method parses" parse_succeeds --method apt
assert_eq "apt" "$INSTALL_METHOD" "APT method is retained"
assert_success "pip method parses" parse_succeeds --method pip
assert_eq "pip" "$INSTALL_METHOD" "pip method is retained"
assert_success "tarball method parses" parse_succeeds --method tarball
assert_eq "tarball" "$INSTALL_METHOD" "tarball method is retained"
assert_success "runfile method parses" parse_succeeds --method runfile --gpu-arch all
assert_eq runfile "$INSTALL_METHOD" "runfile method is retained"
assert_eq all "$GPU_ARCHES" "runfile all architecture is retained"
assert_fails "APT rejects all architecture" parse_fails --method apt --gpu-arch all
assert_fails "pip rejects all architecture" parse_fails --method pip --gpu-arch all
assert_fails "tarball rejects all architecture" parse_fails --method tarball --gpu-arch all
assert_fails "runfile requires explicit all architecture" parse_fails --method runfile
assert_fails "runfile rejects architecture-specific payload" parse_fails --method runfile --gpu-arch gfx1201

parse_succeeds --gpu-arch gfx1151 --driver-mode dkms --skip-ssh --skip-reboot --non-interactive
assert_eq "gfx1151" "$GPU_ARCHES" "GPU architecture collection retains one architecture"
assert_eq "dkms" "$DRIVER_MODE" "explicit DKMS driver mode is retained"
assert_eq "true" "$SKIP_SSH" "SSH setup can be skipped"
assert_eq "-1" "$REBOOT_DELAY" "reboot can be skipped"
assert_eq "true" "$NON_INTERACTIVE" "non-interactive mode is retained"

parse_succeeds --prepare-kernel --reboot-after-kernel
assert_eq true "$PREPARE_KERNEL" "kernel preparation can be explicitly enabled"
assert_eq true "$REBOOT_AFTER_KERNEL" "one-shot kernel reboot can be explicitly enabled"
assert_fails "kernel reboot automation requires kernel preparation" parse_fails --reboot-after-kernel
parse_succeeds --allow-unqualified-kernel
assert_eq true "$ALLOW_UNQUALIFIED_KERNEL" "unqualified kernel override requires an explicit flag"
assert_fails "unqualified kernel override rejects kernel preparation" parse_fails --allow-unqualified-kernel --prepare-kernel
assert_fails "unqualified kernel override rejects automatic kernel reboot" parse_fails --allow-unqualified-kernel --prepare-kernel --reboot-after-kernel
assert_fails "unqualified kernel override rejects verify-only mode" parse_fails --allow-unqualified-kernel --verify-only
assert_fails "unqualified kernel override rejects uninstall mode" parse_fails --allow-unqualified-kernel --uninstall

parse_succeeds --gpu-arch gfx1151 --gpu-arch gfx1100 --gpu-arch gfx1151
assert_eq $'gfx1151\ngfx1100\ngfx1151' "$GPU_ARCHES" "repeated GPU architecture overrides append raw records"
assert_fails "GPU architecture requires a value" parse_fails --gpu-arch
assert_fails "GPU architecture rejects an empty value" parse_fails --gpu-arch ""

assert_eq "ubuntu-24.04.4" "$(normalize_os_key ubuntu 24.04)" "Ubuntu 24.04 resolves to the supported point release"
assert_eq "ubuntu-26.04" "$(normalize_os_key ubuntu 26.04)" "Ubuntu 26.04 is supported"
assert_fails "Ubuntu 22.04 is rejected" normalize_os_key ubuntu 22.04
assert_fails "Debian is rejected" normalize_os_key debian 13
assert_fails "RHEL is rejected" normalize_os_key rhel 10.2

assert_fails "version selection is not part of the fixed-release CLI" parse_fails --version 7.14.0
assert_fails "graphics workload is rejected" parse_fails --workload graphics
assert_fails "unknown installation method is rejected" parse_fails --method pkgman
assert_fails "model selection is not part of the gfx-only CLI" parse_fails --gpu-model max-pro-485
assert_fails "unknown driver mode is rejected" parse_fails --driver-mode legacy
assert_fails "unknown options are rejected" parse_fails --distribution ubuntu
assert_fails "verify and uninstall modes are exclusive" parse_fails --verify-only --uninstall
assert_fails "root passwords containing a newline are rejected" parse_fails --root-password $'unsafe\npassword'
assert_fails "root passwords containing a carriage return are rejected" parse_fails --root-password $'unsafe\rpassword'
assert_fails "verify-only rejects kernel preparation" parse_fails --verify-only --prepare-kernel
assert_fails "uninstall rejects kernel preparation" parse_fails --uninstall --prepare-kernel

assert_status 1 "bash launcher preserves an invalid-option failure" run_invalid_option bash
assert_eq "" "$ENTRYPOINT_STDOUT" "bash launcher keeps invalid-option diagnostics off stdout"
assert_contains "$ENTRYPOINT_STDERR" "argument parsing" "bash launcher identifies argument parsing failures on stderr"
assert_contains "$ENTRYPOINT_STDERR" "--help" "bash launcher tells users how to correct invalid options on stderr"
assert_status 1 "direct launcher preserves an invalid-option failure" run_invalid_option direct
assert_eq "" "$ENTRYPOINT_STDOUT" "direct launcher keeps invalid-option diagnostics off stdout"
assert_contains "$ENTRYPOINT_STDERR" "argument parsing" "direct launcher identifies argument parsing failures on stderr"
assert_contains "$ENTRYPOINT_STDERR" "--help" "direct launcher tells users how to correct invalid options on stderr"

help_output=$(show_help)
assert_contains "$help_output" "ROCm 7.14.0" "help names the fixed release"
assert_contains "$help_output" "apt, pip, tarball, or runfile" "help lists all four install methods"
assert_contains "$help_output" "may be repeated" "help documents repeated GPU architecture overrides"
assert_contains "$help_output" "--prepare-kernel" "help documents explicit kernel preparation"
assert_contains "$help_output" "--reboot-after-kernel" "help documents explicit one-shot kernel reboot"
assert_contains "$help_output" "--allow-unqualified-kernel" "help documents the unsupported 6.17 Radeon override"
assert_contains "$help_output" "$ROCM_GPU_LOOKUP_URL" "help prints the official GPU lookup URL"
assert_contains "$help_output" "gfx=all" "help documents the explicit Runfile all fallback"
assert_not_contains "$help_output" "graphics workload" "help does not advertise a graphics workload"
assert_not_contains "$help_output" "--version" "help does not advertise version selection"
assert_not_contains "$help_output" "--gpu-model" "help does not advertise model selection"
assert_not_contains "$help_output" "Debian" "help stays Ubuntu-only"
assert_not_contains "$help_output" "RHEL" "help stays Ubuntu-only"

finish_tests "release CLI"
