#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034
set -euo pipefail
# shellcheck source=test_helpers.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helpers.sh"

r9700_pci_signature=$'0000:03:00.0|1002:7551|00C0\n0000:23:00.0|1002:7551|00C0\n0000:d3:00.0|1002:7551|00C0\n0000:f3:00.0|1002:7551|00C0'

assert_eq 'install-required|qualified' "$(resolve_kernel_support_record dkms ubuntu-24.04.5 radeon gfx1201 4 "$r9700_pci_signature" 6.7.12-generic '7.0.*-generic' linux-generic-hwe-24.04)" "kernel below 6.8 is blocked"
assert_eq '7.0.*-generic|linux-generic-hwe-24.04' "$(kernel_policy_for dkms ubuntu-24.04.5 gfx1201)" "ROCm 10.1 recommends Ubuntu 24.04.5 HWE 7.0 for R9700 gfx1201"
assert_eq 'ready|qualified' "$(resolve_kernel_support_record dkms ubuntu-24.04.5 radeon gfx1201 4 "$r9700_pci_signature" 7.0.0-28-generic '7.0.*-generic' linux-generic-hwe-24.04)" "recommended HWE 7.0 kernel is qualified"
assert_eq 'ready-unqualified|unqualified' "$(resolve_kernel_support_record dkms ubuntu-24.04.5 radeon gfx1201 4 "$r9700_pci_signature" 6.8.0-138-generic '7.0.*-generic' linux-generic-hwe-24.04)" "GA 6.8 is advisory and allowed for R9700"
assert_eq 'ready-unqualified|unqualified' "$(resolve_kernel_support_record dkms ubuntu-24.04.5 radeon gfx1201 4 "$r9700_pci_signature" 6.17.0-23-generic '7.0.*-generic' linux-generic-hwe-24.04)" "HWE 6.17 is advisory and allowed for R9700"
assert_eq '6.8.*-generic|linux-generic' "$(kernel_policy_for dkms ubuntu-24.04.5 gfx942)" "Instinct keeps the Ubuntu 24.04.5 GA 6.8 recommendation"
assert_eq '7.0.*-generic|linux-generic-hwe-24.04' "$(kernel_policy_for inbox ubuntu-24.04.5 gfx1151)" "ROCm 10.1 recommends Ubuntu 24.04.5 HWE 7.0 for Ryzen gfx1151"
assert_eq 'ready-unqualified|unqualified' "$(resolve_kernel_support_record inbox ubuntu-24.04.5 ryzen gfx1151 1 '' 6.14.0-1020-oem '7.0.*-generic' linux-generic-hwe-24.04)" "Ryzen OEM 6.14 is advisory and allowed"
assert_eq 'ready-unqualified|unqualified' "$(resolve_kernel_support_record inbox ubuntu-24.04.5 ryzen gfx1151 1 '' 6.17.0-23-generic '7.0.*-generic' linux-generic-hwe-24.04)" "Ryzen HWE 6.17 is advisory and allowed"
assert_eq 'ready|qualified' "$(resolve_kernel_support_record inbox ubuntu-24.04.5 ryzen gfx1151 1 '' 7.0.0-28-generic '7.0.*-generic' linux-generic-hwe-24.04)" "Ryzen HWE 7.0 matches the ROCm 10.1 recommendation"
assert_fails "mixed Radeon and Instinct targets have no single Ubuntu 24.04.5 kernel recommendation" kernel_policy_for dkms ubuntu-24.04.5 $'gfx1201\ngfx942'
assert_fails "malformed kernel version is rejected" resolve_kernel_support_record dkms ubuntu-24.04.5 radeon gfx1201 4 "$r9700_pci_signature" bad-kernel '6.8.*-generic' linux-generic

assert_fails "removed kernel preparation option is rejected" parse_args --prepare-kernel
reset_defaults
assert_fails "removed kernel reboot option is rejected" parse_args --reboot-after-kernel
reset_defaults
assert_fails "removed unqualified override is rejected" parse_args --allow-unqualified-kernel

assert_eq '' "$(grep -E 'run_cmd (reboot|shutdown|grub-reboot|grub-editenv)|apt-get .*linux-(generic|oem)' "${ROOT_DIR}/rocm-install.sh" || true)" "installer contains no kernel, GRUB, or reboot mutation command"

finish_tests "kernel advisory"
