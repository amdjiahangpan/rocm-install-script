# ROCm 10.1.0 Installer

`rocm-install.sh` installs the fixed ROCm 10.1.0 Core SDK on supported AMD GPUs. Earlier implementations are preserved on the [`10.0.0`](https://github.com/amdjiahangpan/rocm-install-script/tree/10.0.0) and [`7.14.0`](https://github.com/amdjiahangpan/rocm-install-script/tree/7.14.0) branches.

The supported host is Ubuntu 24.04.5 or 26.04.1 on `x86_64`. GPU architecture selection is KFD-first and supports repeated identical GPUs. The default method is AMD's multi-architecture APT repository; the official Runfile is available as an explicit all-architecture fallback.

Sources:

- [Install AMD ROCm 10.1.0](https://rocm.docs.amd.com/en/latest/install/rocm.html)
- [ROCm 10.1.0 compatibility matrix](https://rocm.docs.amd.com/en/latest/compatibility/compatibility-matrix.html)

## Quick start

```bash
curl -fsSL https://raw.githubusercontent.com/amdjiahangpan/rocm-install-script/main/rocm-install.sh | sudo bash
```

Or inspect the script first:

```bash
curl -fLO https://raw.githubusercontent.com/amdjiahangpan/rocm-install-script/main/rocm-install.sh
sudo bash ./rocm-install.sh
```

The installer prints an immutable plan and asks for confirmation before changing the system. Use `--non-interactive` only after reviewing the same plan interactively.

> [!WARNING]
> SSH setup is enabled by default. It installs and starts OpenSSH, enables root login and password authentication in `/etc/ssh/sshd_config.d/99-rocm-installer.conf`, and optionally changes the root password. Pass `--skip-ssh` to avoid these changes.

## Installation methods

### APT (default)

APT uses AMD's multi-architecture repository and installs one architecture-specific ROCm 10.1 meta package for each normalized GFX target:

```text
amdrocm-core-sdk10.1-<gfx>
```

For Radeon AI PRO R9700, `gfx1201` selects:

```text
amdrocm-core-sdk10.1-gfx1201
```

The ROCm binaries are exposed from `/opt/rocm/core-10.1`. Existing package-manager ROCm conflicts are handled only through the installer's explicit cleanup policy.
Before installing the SDK, the APT path removes the exact legacy Ubuntu `libamdhip64-dev` package when present because its `/usr/include/hip` headers shadow the ROCm 10 headers. It also ensures the highest installed GCC has matching `g++-<version>` standard-library headers so ROCm Clang does not select an incomplete host toolchain.

DKMS mode (Radeon and Instinct) installs `amdgpu-dkms` from AMDGPU 31.60.

### Runfile

The explicit all-architecture fallback is:

```bash
sudo ./rocm-install.sh --method runfile --gpu-arch all
```

It downloads AMD's pinned `rocm-installer-10.1.0-5.run` from `https://stable.repo.amd.com/rocm/core/linux-installers/` and invokes:

```text
deps=install rocm gfx=all compo=core,core-dev target=/opt
```

Runfile and APT layouts cannot be mixed. The Runfile path uses the vendor uninstaller rather than deleting its installation recursively.

## Kernel policy

The script never installs a kernel, changes GRUB, selects a boot entry, or reboots the host.

- Kernel older than 6.8: the installer stops before driver or ROCm mutation and asks the user to upgrade manually.
- Kernel 6.8 or newer: installation may continue.
- A non-recommended kernel prints the current kernel and AMD's recommended kernel but does not require a switch.
- Radeon GPUs such as Radeon AI PRO R9700 on Ubuntu 24.04.5: ROCm 10.1 recommends the HWE 7.0 generic kernel. Running GA 6.8 or HWE 6.17 kernels receive a warning and are allowed to continue.
- Ryzen AI Max `gfx1151` systems such as Radeon 8060S on Ubuntu 24.04.5: ROCm 10.1 recommends the HWE 7.0 generic kernel. A running 6.14 OEM or 6.17 HWE kernel receives a warning and remains allowed.
- Instinct GPUs on Ubuntu 24.04.5 keep the GA 6.8 recommendation; Ubuntu 26.04.1 recommends GA 7.0 for every class.
- When driver activation requires a reboot, the installer reports the boundary and exits. The user reboots manually and reruns the script.

The removed ROCm 7.14 options `--prepare-kernel`, `--reboot-after-kernel`, and `--allow-unqualified-kernel` are rejected.

## Supported GFX targets

```text
gfx950 gfx942 gfx90a gfx908 gfx1201 gfx1200 gfx1100 gfx1101 gfx1102
gfx1103 gfx1030 gfx1151 gfx1150 gfx1152 gfx1153
```

KFD topology is authoritative when available. Four identical R9700 cards report `gpu_count=4` while selecting one `gfx1201` APT artifact. Product names are informational and never choose packages or kernel policy.

## Common options

| Option | Behavior |
| --- | --- |
| `--method apt` | Install through APT; default. |
| `--method runfile --gpu-arch all` | Install the official all-GPU Runfile payload. |
| `--gpu-arch GFX` | Override automatic GFX detection; repeatable for APT. |
| `--driver-mode auto\|inbox\|dkms` | Select the reviewed driver policy. |
| `--dkms-cleanup auto\|ask\|always\|never` | Control removal of conflicting DKMS state. |
| `--skip-ssh` | Do not install or configure SSH. |
| `--verify-only` | Verify an existing installation without mutation. |
| `--uninstall` | Remove the selected ROCm 10.1.0 installation. |
| `--non-interactive` | Disable prompts. |

`--skip-reboot` and `--reboot-delay` remain accepted for older automation but are inert: the ROCm 10 installer never reboots.

## Verification

After installation and any user-controlled reboot:

```bash
/opt/rocm/core-10.1/bin/rocminfo
/opt/rocm/core-10.1/bin/amd-smi version
/opt/rocm/core-10.1/bin/hipcc --version
```

`rocminfo` must report every requested GFX target, and `amd-smi version` must report exactly ROCm 10.1.0. Re-running the installer against matching package, driver, and GPU state is idempotent.

## Tests

```bash
bash -n rocm-install.sh
bash tests/run_tests.sh
```

The suite covers CLI validation, KFD/PCI detection, ROCm 10.1 artifacts, kernel 6.7/6.8/7.0 advisory behavior, APT and Runfile lifecycle, uninstall safety, and the no-automatic-reboot boundary.

## License

MIT
