#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034
set -euo pipefail
# shellcheck source=test_helpers.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helpers.sh"

observed_fixture="${ROOT_DIR}/tests/fixtures/aup-395-23"
observed_kfd_root="${observed_fixture}/kfd"
observed_drm_root="${observed_fixture}/drm"
observed_ids="${observed_fixture}/amdgpu.ids"
heterogeneous_fixture="${ROOT_DIR}/tests/fixtures/gfx1151-gfx1201"
heterogeneous_kfd_root="${heterogeneous_fixture}/kfd"
heterogeneous_drm_root="${heterogeneous_fixture}/drm"
heterogeneous_ids="${heterogeneous_fixture}/amdgpu.ids"
rx9060_fixture="${ROOT_DIR}/tests/fixtures/rx-9060-xt"
rx9060_kfd_root="${rx9060_fixture}/kfd"
rx9060_pci_root="${rx9060_fixture}/pci"
missing_pci_root="${TEST_TEMP_ROOT}/missing-pci-root"
r9700_fixture="${ROOT_DIR}/tests/fixtures/r9700-four-gpu"
r9700_kfd_root="${r9700_fixture}/kfd"
r9700_pci_root="${TEST_TEMP_ROOT}/r9700-pci"
r9700_driver_root="${TEST_TEMP_ROOT}/drivers/amdgpu"
cp -a "${r9700_fixture}/pci" "$r9700_pci_root"
mkdir -p "$r9700_driver_root"
for r9700_device_root in "$r9700_pci_root"/*; do
    ln -s "$r9700_driver_root" "${r9700_device_root}/driver"
done

assert_eq "gfx1151" "$(kfd_gfx_target 110501)" "KFD 110501 decodes with AMD's decimal-field algorithm"
assert_eq "gfx90a" "$(kfd_gfx_target 90010)" "KFD stepping is rendered as a hexadecimal gfx digit"
assert_eq "gfx1151" "$(detect_gpu_architectures "$observed_kfd_root")" "observed KFD CPU node is ignored and GPU node resolves gfx1151"
assert_eq "AMD Radeon 8060S Graphics" "$(detect_gpu_product_names "$observed_drm_root" "$observed_ids")" "observed empty sysfs product name falls back to exact libdrm IDs row"
assert_eq $'gfx1151\ngfx1201' "$(detect_gpu_architectures "$heterogeneous_kfd_root")" "heterogeneous KFD nodes normalize all supported targets"
assert_eq 'gfx1200|radeon' "$(lookup_pci_gpu_record 7590 c0)" "RX 9060 XT PCI ID resolves to gfx1200 Radeon"
assert_eq 'gfx1200|radeon' "$(detect_gpu_architectures_from_pci "$rx9060_pci_root")" "PCI fallback recovers RX 9060 XT before KFD exists"
assert_eq gfx1201 "$(detect_gpu_architectures "$r9700_kfd_root")" "four R9700 KFD nodes normalize to gfx1201"
assert_eq 4 "$(count_kfd_gpu_devices "$r9700_kfd_root")" "four R9700 KFD nodes preserve the physical GPU count"
assert_eq $'AMD Radeon 8060S Graphics\nAMD Radeon AI PRO R9700' "$(detect_gpu_product_names "$heterogeneous_drm_root" "$heterogeneous_ids")" "every DRM card contributes its direct or exact-ID product name"
strict_product_names=''
if strict_product_names=$(bash -Eeuo pipefail -c '
    ROCM_INSTALL_LIBRARY_MODE=1
    source "$1/rocm-install.sh"
    detect_gpu_product_names "$2/drm" "$2/amdgpu.ids"
' bash "$ROOT_DIR" "$heterogeneous_fixture"); then
    :
else
    fail "strict-mode DRM product discovery reaches the empty-name PCI-ID fallback"
fi
assert_eq $'AMD Radeon 8060S Graphics\nAMD Radeon AI PRO R9700' "$strict_product_names" "strict-mode DRM product discovery emits both names"

GPU_DETECTION_PCI_ROOT=$missing_pci_root
GPU_DETECTION_KFD_ROOT=$observed_kfd_root
GPU_DETECTION_DRM_ROOT=$observed_drm_root
AMDGPU_IDS_PATH=$observed_ids
GPU_ARCHES=''
assert_success "observed fixture resolves its architecture collection" resolve_gpu_identity
assert_eq "gfx1151" "$GPU_ARCHES" "observed KFD architecture collection is stored"
assert_eq "AMD Radeon 8060S Graphics" "$GPU_PRODUCT_NAMES" "observed product-name collection is informational"
GPU_DETECTION_DRM_ROOT="${TEST_TEMP_ROOT}/missing-drm-root"
GPU_ARCHES=''
assert_success "product-name discovery failure does not block architecture discovery" resolve_gpu_identity
assert_eq "gfx1151" "$GPU_ARCHES" "architecture discovery remains available without product information"
assert_eq "" "$GPU_PRODUCT_NAMES" "missing product information remains empty and informational"

GPU_DETECTION_KFD_ROOT=$heterogeneous_kfd_root
GPU_DETECTION_DRM_ROOT=$heterogeneous_drm_root
AMDGPU_IDS_PATH=$heterogeneous_ids
GPU_ARCHES=''
assert_success "heterogeneous fixture resolves all architectures" resolve_gpu_identity
assert_eq $'gfx1151\ngfx1201' "$GPU_ARCHES" "automatic discovery stores normalized architecture collection"
assert_eq $'AMD Radeon 8060S Graphics\nAMD Radeon AI PRO R9700' "$GPU_PRODUCT_NAMES" "automatic discovery stores normalized product-name collection"

GPU_DETECTION_KFD_ROOT=$rx9060_kfd_root
GPU_DETECTION_PCI_ROOT=$rx9060_pci_root
GPU_DETECTION_DRM_ROOT="${TEST_TEMP_ROOT}/missing-drm-root"
GPU_ARCHES=''
assert_success "matching RX 9060 KFD and PCI records resolve one identity" resolve_gpu_identity
assert_eq gfx1200 "$GPU_ARCHES" "RX 9060 identity stores gfx1200"
assert_eq radeon "$GPU_CLASSES" "RX 9060 identity stores its Radeon class"
assert_eq kfd+pci "$GPU_DETECTION_SOURCE" "matching KFD and PCI records report both sources"

GPU_DETECTION_KFD_ROOT=$r9700_kfd_root
GPU_DETECTION_PCI_ROOT=$r9700_pci_root
GPU_DETECTION_DRM_ROOT="${TEST_TEMP_ROOT}/missing-drm-root"
GPU_ARCHES=''
assert_success "valid R9700 KFD accepts bound unmapped PCI devices" resolve_gpu_identity
assert_eq gfx1201 "$GPU_ARCHES" "four R9700 cards select one gfx1201 artifact architecture"
assert_eq 4 "$GPU_DEVICE_COUNT" "R9700 identity preserves four physical devices"
assert_eq kfd+unmapped-pci "$GPU_DETECTION_SOURCE" "R9700 identity reports unmapped PCI evidence"
assert_contains "$GPU_UNMAPPED_PCI" "1002:7001" "unmapped R9700 evidence includes the first PCI ID"
assert_contains "$GPU_UNMAPPED_PCI" "1002:7004" "unmapped R9700 evidence includes the fourth PCI ID"
rm "${r9700_pci_root}/0000:04:00.0/driver"
GPU_ARCHES=''
assert_fails "one unbound unmapped PCI device fails closed" resolve_gpu_identity
ln -s "$r9700_driver_root" "${r9700_pci_root}/0000:04:00.0/driver"

GPU_DETECTION_PCI_ROOT=$rx9060_pci_root
GPU_DETECTION_KFD_ROOT="${TEST_TEMP_ROOT}/missing-kfd-root"
GPU_ARCHES=''
assert_success "RX 9060 PCI fallback resolves when KFD is unavailable" resolve_gpu_identity
assert_eq gfx1200 "$GPU_ARCHES" "PCI-only recovery stores gfx1200"
assert_eq radeon "$GPU_CLASSES" "PCI-only recovery stores the Radeon class"
assert_eq pci "$GPU_DETECTION_SOURCE" "PCI-only recovery identifies its source"

disagreeing_kfd_root="${TEST_TEMP_ROOT}/kfd-disagreement"
mkdir -p "${disagreeing_kfd_root}/0"
printf 'cpu_cores_count 0\ngfx_target_version 120001\n' > "${disagreeing_kfd_root}/0/properties"
GPU_DETECTION_KFD_ROOT=$disagreeing_kfd_root
GPU_ARCHES=''
assert_fails "KFD and PCI architecture disagreement fails closed" resolve_gpu_identity
assert_eq "" "$GPU_ARCHES" "disagreement clears the architecture collection"
assert_eq "" "$GPU_CLASSES" "disagreement clears the class collection"
GPU_DETECTION_PCI_ROOT=$missing_pci_root

GPU_DETECTION_KFD_ROOT="${TEST_TEMP_ROOT}/missing-kfd-root"
GPU_ARCHES=$'gfx1201\ngfx1151'
assert_success "explicit architectures replace unavailable KFD discovery" resolve_gpu_identity
assert_eq $'gfx1151\ngfx1201' "$GPU_ARCHES" "explicit architectures normalize before storage"
GPU_ARCHES=$'gfx1201\ngfx1151\ngfx1201'
assert_success "duplicate explicit architectures normalize" resolve_gpu_identity
assert_eq $'gfx1151\ngfx1201' "$GPU_ARCHES" "duplicate explicit architectures are removed"
GPU_ARCHES=$'gfx1201\ngfx9999'
GPU_PRODUCT_NAMES='AMD stale product'
assert_fails "an unsupported explicit member rejects the complete architecture collection" resolve_gpu_identity
assert_eq "" "$GPU_ARCHES" "failed explicit architecture resolution clears architecture collection"
assert_eq "" "$GPU_PRODUCT_NAMES" "failed explicit architecture resolution clears product-name collection"

GPU_ARCHES=gfx1151
GPU_PRODUCT_NAMES='AMD stale product'
assert_status 64 "GPU identity rejects unexpected arguments" resolve_gpu_identity gfx1201
assert_eq "" "$GPU_ARCHES" "unexpected identity arguments clear architecture collection"
assert_eq "" "$GPU_PRODUCT_NAMES" "unexpected identity arguments clear product-name collection"

product_root="${TEST_TEMP_ROOT}/drm-product"
mkdir -p "${product_root}/card0/device"
printf 'AMD Radeon Test Graphics\n' > "${product_root}/card0/device/product_name"
assert_eq "AMD Radeon Test Graphics" "$(detect_gpu_product_names "$product_root" "$observed_ids")" "nonempty sysfs product name has precedence"

unsupported_kfd_root="${TEST_TEMP_ROOT}/kfd-unsupported"
mkdir -p "${unsupported_kfd_root}/0" "${unsupported_kfd_root}/1"
printf 'cpu_cores_count 0\ngfx_target_version 110501\n' > "${unsupported_kfd_root}/0/properties"
printf 'cpu_cores_count 0\ngfx_target_version 100001\n' > "${unsupported_kfd_root}/1/properties"
assert_fails "an unsupported automatic target rejects the complete architecture collection" detect_gpu_architectures "$unsupported_kfd_root"

GPU_DETECTION_KFD_ROOT=$unsupported_kfd_root
GPU_DETECTION_PCI_ROOT=$rx9060_pci_root
GPU_ARCHES=''
assert_fails "present but invalid KFD topology cannot fall back to PCI" resolve_gpu_identity
assert_eq "" "$GPU_ARCHES" "invalid KFD evidence clears the architecture collection"

mixed_pci_root="${TEST_TEMP_ROOT}/pci-mixed-known-unknown"
cp -a "$rx9060_pci_root/." "$mixed_pci_root/"
mkdir -p "${mixed_pci_root}/0000:04:00.0"
printf '0x1002\n' > "${mixed_pci_root}/0000:04:00.0/vendor"
printf '0x9999\n' > "${mixed_pci_root}/0000:04:00.0/device"
printf '0x01\n' > "${mixed_pci_root}/0000:04:00.0/revision"
printf '0x030000\n' > "${mixed_pci_root}/0000:04:00.0/class"
unknown_pci_output=''
if unknown_pci_output=$(detect_gpu_architectures_from_pci "$mixed_pci_root" 2>&1); then
    fail "one unknown AMD display device rejects the complete PCI inventory"
fi
assert_contains "$unknown_pci_output" "1002:9999" "unknown PCI failure reports the exact AMD device ID"

GPU_DETECTION_KFD_ROOT=$rx9060_kfd_root
GPU_DETECTION_PCI_ROOT=$mixed_pci_root
GPU_ARCHES=''
identity_unknown_pci_output=''
if identity_unknown_pci_output=$(resolve_gpu_identity 2>&1); then
    fail "valid KFD cannot hide an unknown AMD PCI display device"
fi
assert_contains "$identity_unknown_pci_output" "1002:9999" "identity failure preserves the unknown PCI diagnostic"
assert_eq "" "$GPU_ARCHES" "identity failure leaves no partial KFD architecture set"
GPU_DETECTION_PCI_ROOT=$missing_pci_root

no_gpu_kfd_root="${TEST_TEMP_ROOT}/kfd-no-gpu"
mkdir -p "${no_gpu_kfd_root}/0"
printf 'cpu_cores_count 16\ngfx_target_version 0\n' > "${no_gpu_kfd_root}/0/properties"
assert_fails "zero KFD GPU targets are rejected" detect_gpu_architectures "$no_gpu_kfd_root"
GPU_DETECTION_KFD_ROOT=$no_gpu_kfd_root
GPU_DETECTION_DRM_ROOT=$heterogeneous_drm_root
AMDGPU_IDS_PATH=$heterogeneous_ids
GPU_ARCHES=''
assert_fails "informational product names cannot infer an architecture" resolve_gpu_identity
assert_eq "" "$GPU_ARCHES" "failed automatic detection leaves no architecture collection"
assert_eq "" "$GPU_PRODUCT_NAMES" "product names are not stored when no architecture is detected"

manual_pci_root="${TEST_TEMP_ROOT}/manual-unknown-pci"
mkdir -p "${manual_pci_root}/0000:05:00.0"
printf '0x1002\n' > "${manual_pci_root}/0000:05:00.0/vendor"
printf '0x7999\n' > "${manual_pci_root}/0000:05:00.0/device"
printf '0x01\n' > "${manual_pci_root}/0000:05:00.0/revision"
printf '0x030000\n' > "${manual_pci_root}/0000:05:00.0/class"
MOCK_INTERACTIVE=true
is_interactive_terminal() { [[ "$MOCK_INTERACTIVE" == true ]]; }
NON_INTERACTIVE=false
GPU_DETECTION_KFD_ROOT=$no_gpu_kfd_root
GPU_DETECTION_PCI_ROOT=$manual_pci_root
GPU_DETECTION_DRM_ROOT="${TEST_TEMP_ROOT}/missing-drm-root"
GPU_ARCHES=''
manual_prompt_output="${TEST_TEMP_ROOT}/manual-prompt-output"
if resolve_gpu_identity <<< $'Radeon AI PRO R9700\ngfx1201' 2> "$manual_prompt_output"; then
    PASS_COUNT=$((PASS_COUNT + 1))
else
    fail "interactive unknown GPU accepts a reviewed manual GFX"
fi
assert_eq gfx1201 "$GPU_ARCHES" "manual recovery stores gfx1201"
assert_eq radeon "$GPU_CLASSES" "manual recovery derives the Radeon class only from gfx1201"
assert_eq manual "$GPU_DETECTION_SOURCE" "manual recovery records its source"
assert_eq 'Radeon AI PRO R9700' "$GPU_MODEL_NAME" "manual model text is retained for display"
assert_eq 1 "$GPU_DEVICE_COUNT" "manual PCI inventory records one physical device"
assert_contains "$(<"$manual_prompt_output")" "$ROCM_GPU_LOOKUP_URL" "manual prompt prints the official lookup URL"
assert_contains "$(<"$manual_prompt_output")" "$ROCM_GPU_LOOKUP_ZH_URL" "manual prompt prints the Chinese lookup URL"

NON_INTERACTIVE=true
GPU_ARCHES=''
assert_fails "non-interactive unknown GPU requires --gpu-arch" resolve_gpu_identity

GPU_DETECTION_KFD_ROOT=$r9700_kfd_root
GPU_DETECTION_PCI_ROOT=$r9700_pci_root
GPU_ARCHES=gfx1200
manual_mismatch_output="${TEST_TEMP_ROOT}/manual-mismatch-output"
if resolve_gpu_identity 2> "$manual_mismatch_output"; then
    fail "explicit GFX that disagrees with KFD fails closed"
fi
assert_eq "" "$GPU_ARCHES" "manual mismatch clears the incorrect GFX"
assert_contains "$(<"$manual_mismatch_output")" "--method runfile --gpu-arch all" "manual mismatch prints the explicit Runfile fallback"
unset -f is_interactive_terminal
NON_INTERACTIVE=false

installer_source=$(<"${ROOT_DIR}/rocm-install.sh")
assert_not_contains "$installer_source" "ROCM_714_MODEL_RECORDS" "installer has no model records"
assert_not_contains "$installer_source" "--gpu-model" "installer has no model override"
assert_not_contains "$installer_source" "lspci" "pre-install detection does not use lspci"
assert_not_contains "$installer_source" "cpuinfo" "pre-install detection does not use cpuinfo"
# shellcheck disable=SC2016
assert_contains "$installer_source" 'capture_cmd "${install_root}/bin/rocminfo"' "post-install verification retains rocminfo"

finish_tests "GPU detection"
