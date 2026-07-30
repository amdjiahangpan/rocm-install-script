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

assert_eq "7.14.0" "$ROCM_VERSION" "release is fixed at ROCm 7.14.0"
assert_eq "7.14" "$ROCM_SERIES" "package series is fixed at 7.14"
assert_eq "31.40" "$AMDGPU_RELEASE" "AMDGPU migration release is fixed at 31.40"
assert_eq "https://repo.amd.com/rocm/packages-multi-arch" "$ROCM_PACKAGES_ROOT" "APT package root is fixed"
assert_eq "https://repo.amd.com/rocm/whl-multi-arch/" "$ROCM_WHL_INDEX" "wheel index is fixed"
assert_eq "https://repo.amd.com/rocm/tarball-multi-arch/" "$ROCM_TARBALL_ROOT" "tarball root is fixed"

reset_defaults
assert_eq "compute" "$WORKLOAD" "compute is the only default workload"
assert_eq "apt" "$INSTALL_METHOD" "APT is the default install method"
assert_eq "full" "$PACKAGE_PROFILE" "the full SDK is installed by default"
assert_eq "" "$GPU_ARCHES" "GPU architecture collection is empty by default"
assert_eq "" "$GPU_PRODUCT_NAMES" "GPU product-name collection is empty by default"
assert_eq "false" "$SKIP_SSH" "SSH setup is enabled by default"
assert_eq "0" "$REBOOT_DELAY" "reboot is immediate by default"

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

parse_succeeds --gpu-arch gfx1151 --driver-mode dkms --skip-ssh --skip-reboot --non-interactive
assert_eq "gfx1151" "$GPU_ARCHES" "GPU architecture collection retains one architecture"
assert_eq "dkms" "$DRIVER_MODE" "explicit DKMS driver mode is retained"
assert_eq "true" "$SKIP_SSH" "SSH setup can be skipped"
assert_eq "-1" "$REBOOT_DELAY" "reboot can be skipped"
assert_eq "true" "$NON_INTERACTIVE" "non-interactive mode is retained"

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
assert_fails "runfile method is rejected" parse_fails --method runfile
assert_fails "legacy pkgman method is rejected" parse_fails --method pkgman
assert_fails "model selection is not part of the gfx-only CLI" parse_fails --gpu-model max-pro-485
assert_fails "unknown driver mode is rejected" parse_fails --driver-mode legacy
assert_fails "unknown options are rejected" parse_fails --distribution ubuntu
assert_fails "verify and uninstall modes are exclusive" parse_fails --verify-only --uninstall
assert_fails "root passwords containing a newline are rejected" parse_fails --root-password $'unsafe\npassword'
assert_fails "root passwords containing a carriage return are rejected" parse_fails --root-password $'unsafe\rpassword'

help_output=$(show_help)
assert_contains "$help_output" "ROCm 7.14.0" "help names the fixed release"
assert_contains "$help_output" "apt, pip, or tarball" "help lists the three install methods"
assert_contains "$help_output" "may be repeated" "help documents repeated GPU architecture overrides"
assert_not_contains "$help_output" "graphics" "help does not advertise graphics"
assert_not_contains "$help_output" "runfile" "help does not advertise runfile"
assert_not_contains "$help_output" "--version" "help does not advertise version selection"
assert_not_contains "$help_output" "--gpu-model" "help does not advertise model selection"
assert_not_contains "$help_output" "Debian" "help stays Ubuntu-only"
assert_not_contains "$help_output" "RHEL" "help stays Ubuntu-only"

finish_tests "release CLI"
