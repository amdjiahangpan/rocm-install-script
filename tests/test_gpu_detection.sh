#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helpers.sh"

observed_fixture="${ROOT_DIR}/tests/fixtures/aup-395-23"
observed_kfd_root="${observed_fixture}/kfd"
observed_drm_root="${observed_fixture}/drm"
observed_ids="${observed_fixture}/amdgpu.ids"

assert_eq "gfx1151" "$(kfd_gfx_target 110501)" "KFD 110501 decodes with AMD's decimal-field algorithm"
assert_eq "gfx90a" "$(kfd_gfx_target 90010)" "KFD stepping is rendered as a hexadecimal gfx digit"
assert_eq "gfx1151" "$(detect_gpu_architecture "$observed_kfd_root")" "observed KFD CPU node is ignored and GPU node resolves gfx1151"
assert_eq "AMD Radeon 8060S Graphics" "$(detect_gpu_product_name "$observed_drm_root" "$observed_ids")" "empty sysfs product name falls back to exact libdrm IDs row"

GPU_DETECTION_KFD_ROOT=$observed_kfd_root
GPU_DETECTION_DRM_ROOT=$observed_drm_root
AMDGPU_IDS_PATH=$observed_ids
assert_success "observed fixture resolves the unique architecture" resolve_gpu_identity ''
assert_eq "gfx1151" "$GPU_ARCH" "observed KFD architecture is stored"
assert_eq "AMD Radeon 8060S Graphics" "$GPU_PRODUCT_NAME" "observed product name is informational"

multi_root="${TEST_TEMP_ROOT}/kfd-multiple"
mkdir -p "${multi_root}/0" "${multi_root}/1"
printf 'cpu_cores_count 0\ngfx_target_version 110501\n' > "${multi_root}/0/properties"
printf 'cpu_cores_count 0\ngfx_target_version 120001\n' > "${multi_root}/1/properties"
assert_fails "multiple unique KFD gfx targets require an explicit override" detect_gpu_architecture "$multi_root"
GPU_DETECTION_KFD_ROOT=$multi_root
assert_success "explicit gfx permits a multiple-GPU host" resolve_gpu_identity gfx1151
assert_eq "gfx1151" "$GPU_ARCH" "explicit gfx is retained"
assert_fails "unsupported explicit gfx is rejected" resolve_gpu_identity gfx9999

product_root="${TEST_TEMP_ROOT}/drm-product"
mkdir -p "${product_root}/card0/device"
printf 'AMD Radeon Test Graphics\n' > "${product_root}/card0/device/product_name"
assert_eq "AMD Radeon Test Graphics" "$(detect_gpu_product_name "$product_root" "$observed_ids")" "nonempty sysfs product name has precedence"

installer_source=$(<"${ROOT_DIR}/rocm-install.sh")
assert_not_contains "$installer_source" "ROCM_714_MODEL_RECORDS" "installer has no model records"
assert_not_contains "$installer_source" "--gpu-model" "installer has no model override"
assert_not_contains "$installer_source" "lspci" "pre-install detection does not use lspci"
assert_not_contains "$installer_source" "cpuinfo" "pre-install detection does not use cpuinfo"
assert_contains "$installer_source" 'capture_cmd "${install_root}/bin/rocminfo"' "post-install verification retains rocminfo"

finish_tests "GPU detection"
