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
assert_eq "gfx1103" "$(detect_gpu_arch_from_gfx_target_version 110003)" "gfx_target_version 110003 maps to gfx1103"
assert_eq "gfx1150" "$(detect_gpu_arch_from_gfx_target_version 110500)" "gfx_target_version 110500 maps to gfx1150"
assert_eq "gfx1151" "$(detect_gpu_arch_from_gfx_target_version 110501)" "gfx_target_version 110501 maps to gfx1151"
assert_eq "gfx1152" "$(detect_gpu_arch_from_gfx_target_version 110502)" "gfx_target_version 110502 maps to gfx1152"
assert_eq "gfx1150" "$(detect_gpu_arch_from_pci_device_id 0x150e)" "PCI device 0x150e maps to gfx1150"
assert_eq "gfx1150" "$(detect_gpu_arch_from_pci_device_id 150e)" "PCI device 150e maps to gfx1150"
assert_eq "gfx1150" "$(detect_gpu_arch_from_pci_device_id 5390)" "PCI device 5390 maps to gfx1150"
assert_eq "gfx1150" "$(detect_gpu_arch_from_text '64:00.0 VGA compatible controller [0300]: Advanced Micro Devices, Inc. [AMD/ATI] Device [1002:150e]')" "lspci PCI ID 150e maps to gfx1150"

apt_has_package() {
    [[ "$1" == "linux-oem-24.04c" ]]
}
assert_eq "linux-oem-24.04c" "$(resolve_oem_kernel_package linux-oem-24.04c 6.14)" "OEM kernel resolver prefers Ubuntu 24.04c meta-package"

apt_has_package() {
    [[ "$1" == "linux-oem-6.14" ]]
}
assert_eq "linux-oem-6.14" "$(resolve_oem_kernel_package linux-oem-24.04c 6.14)" "OEM kernel resolver falls back to series meta-package"

apt_cache_fixture=$(mktemp -d)
mkdir -p "${apt_cache_fixture}/bin"
cat > "${apt_cache_fixture}/bin/apt-cache" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "search" ]]; then
    printf 'linux-image-6.14.0-1018-oem - Linux kernel image\n'
    printf 'linux-image-6.14.0-1021-oem - Linux kernel image\n'
    exit 0
fi
exit 1
EOF
chmod +x "${apt_cache_fixture}/bin/apt-cache"
old_path="$PATH"
PATH="${apt_cache_fixture}/bin:${PATH}"
apt_has_package() {
    return 1
}
assert_eq "linux-image-6.14.0-1021-oem" "$(resolve_oem_kernel_package linux-oem-24.04c 6.14)" "OEM kernel resolver falls back to newest matching image package"
PATH="$old_path"
rm -rf "$apt_cache_fixture"

sysfs_fixture=$(mktemp -d)
trap 'rm -rf "$sysfs_fixture"' EXIT
mkdir -p "${sysfs_fixture}/0" "${sysfs_fixture}/1"
printf 'cpu_cores_count 16\ngfx_target_version 0\n' > "${sysfs_fixture}/0/properties"
printf 'vendor_id 4098\ndevice_id 5568\ngfx_target_version 110500\n' > "${sysfs_fixture}/1/properties"
assert_eq "gfx1150" "$(detect_gpu_arch_from_kfd_sysfs "$sysfs_fixture")" "KFD sysfs properties map to gfx1150 before ROCm install"
printf 'vendor_id 4098\ndevice_id 5390\n' > "${sysfs_fixture}/1/properties"
assert_eq "gfx1150" "$(detect_gpu_arch_from_kfd_sysfs "$sysfs_fixture")" "KFD sysfs device_id 5390 maps to gfx1150 when gfx_target_version is absent"

GPU_ARCH=gfx1103
assert_eq "amdrocm7.13-gfx110x" "$(get_native_rocm_apt_package 7.13.0)" "gfx1103 selects gfx110x package"

GPU_ARCH=gfx1150
assert_eq "amdrocm7.13-gfx1150" "$(get_native_rocm_apt_package 7.13.0)" "gfx1150 selects gfx1150 package"

GPU_ARCH=gfx1151
assert_eq "amdrocm7.13-gfx1151" "$(get_native_rocm_apt_package 7.13.0)" "gfx1151 selects gfx1151 package"

assert_fails "unknown ROCm 7.13 architecture must not select all-arch package" bash -c "export ROCM_INSTALL_LIBRARY_MODE=1; source '${ROOT_DIR}/rocm-install.sh'; GPU_ARCH=; detect_gpu_architecture() { :; }; get_native_rocm_apt_package 7.13.0"

visible_error_output=$(bash -c "export ROCM_INSTALL_LIBRARY_MODE=1; source '${ROOT_DIR}/rocm-install.sh'; GPU_ARCH=; detect_gpu_architecture() { :; }; if ! rocm_package=\$(get_native_rocm_apt_package 7.13.0); then error \"Unable to determine a ROCm 7.13 GPU-specific package for architecture '\${GPU_ARCH:-unknown}'. Specify --gpu-arch.\"; fi" 2>&1 || true)
if [[ "$visible_error_output" != *"[ERROR]"* ]] || [[ "$visible_error_output" != *"Specify --gpu-arch"* ]]; then
    printf 'FAIL: unknown architecture error was not visible\noutput: %s\n' "$visible_error_output" >&2
    exit 1
fi
pass_count=$((pass_count + 1))

printf 'PASS: %d package selection checks\n' "$pass_count"
