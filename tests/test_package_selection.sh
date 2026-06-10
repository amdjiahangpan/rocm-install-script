#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export ROCM_INSTALL_LIBRARY_MODE=1
source "${ROOT_DIR}/rocm-install.sh"

pass_count=0

assert_eq() {
    local expected="$1"
    local actual="$2"
    local message="$3"

    if [[ "$actual" != "$expected" ]]; then
        printf 'FAIL: %s\nexpected: %s\nactual:   %s\n' "$message" "$expected" "$actual" >&2
        exit 1
    fi

    pass_count=$((pass_count + 1))
}

assert_fails() {
    local message="$1"
    shift

    if "$@" >/dev/null 2>&1; then
        printf 'FAIL: %s\ncommand unexpectedly succeeded\n' "$message" >&2
        exit 1
    fi

    pass_count=$((pass_count + 1))
}

assert_eq "gfx1103" "$(detect_gpu_arch_from_text 'Advanced Micro Devices, Inc. [AMD/ATI] Phoenix3 [Radeon 780M Graphics]')" "Radeon 780M maps to gfx1103"
assert_eq "gfx1150" "$(detect_gpu_arch_from_text 'Advanced Micro Devices, Inc. [AMD/ATI] Strix [Radeon 890M Graphics]')" "Radeon 890M maps to gfx1150"
assert_eq "gfx1151" "$(detect_gpu_arch_from_text 'Advanced Micro Devices, Inc. [AMD/ATI] Strix Halo [Radeon 8060S Graphics]')" "Radeon 8060S maps to gfx1151"
assert_eq "gfx1152" "$(detect_gpu_arch_from_text 'Advanced Micro Devices, Inc. [AMD/ATI] Krackan [Radeon 860M Graphics]')" "Radeon 860M maps to gfx1152"

GPU_ARCH=gfx1103
assert_eq "amdrocm7.13-gfx110x" "$(get_native_rocm_apt_package 7.13.0)" "gfx1103 selects gfx110x package"

GPU_ARCH=gfx1150
assert_eq "amdrocm7.13-gfx1150" "$(get_native_rocm_apt_package 7.13.0)" "gfx1150 selects gfx1150 package"

GPU_ARCH=gfx1151
assert_eq "amdrocm7.13-gfx1151" "$(get_native_rocm_apt_package 7.13.0)" "gfx1151 selects gfx1151 package"

assert_fails "unknown ROCm 7.13 architecture must not select all-arch package" bash -c "export ROCM_INSTALL_LIBRARY_MODE=1; source '${ROOT_DIR}/rocm-install.sh'; GPU_ARCH=; detect_gpu_architecture() { :; }; get_native_rocm_apt_package 7.13.0"

printf 'PASS: %d package selection checks\n' "$pass_count"
