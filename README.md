# ROCm 7.14.0 Installer

`rocm-install.sh` installs the ROCm 7.14.0 compute stack on supported AMD GPUs.
The release is fixed at 7.14.0, not 7.1.4. It doesn't select or discover other
ROCm releases.

The supported host is Ubuntu 24.04 or 26.04 on `x86_64`. Package selection is
based only on one or more supported normalized KFD `gfx_target_version` values,
or the complete set supplied through repeatable `--gpu-arch` options. The
complete `gfx` set also selects one official Ubuntu kernel policy. DRM product
names are informational only. OS, kernel, driver, and artifact checks must all
pass before the script changes the system.

> [!WARNING]
> SSH setup is enabled by default. It installs and starts OpenSSH, enables
> `PermitRootLogin yes`, and enables `PasswordAuthentication yes` in
> `/etc/ssh/sshd_config.d/99-rocm-installer.conf`. Use `--skip-ssh` to avoid
> these changes. `--root-password PASS` changes the root password when SSH
> setup runs.

## Quick Start

Run the script directly from the public `unified-installer` branch:

```bash
curl -fsSL https://raw.githubusercontent.com/amdjiahangpan/rocm-install-script/unified-installer/rocm-install.sh | sudo bash
```

Or download it first:

```bash
curl -fLO https://raw.githubusercontent.com/amdjiahangpan/rocm-install-script/unified-installer/rocm-install.sh
sudo bash ./rocm-install.sh
```

Or clone the public branch:

```bash
git clone --branch unified-installer --single-branch https://github.com/amdjiahangpan/rocm-install-script.git
cd rocm-install-script
sudo bash ./rocm-install.sh
```

The default run uses APT and installs one architecture-specific full Core SDK
for each detected target. It prints the resolved plan and asks for confirmation
before installing. It also displays the resolved kernel status, target, and
official Ubuntu metapackage. If kernel preparation, a driver, group, or udev
change requires a reboot, the default reboot policy is immediate.

After confirmation, a non-ready kernel is prepared first and the installer
stops for reboot before any driver, prerequisite, ROCm, SSH, or environment
work. A ready kernel proceeds to driver migration before any prerequisite APT
update or install. The installer removes a conflicting legacy DKMS driver and
rechecks for residue before installing prerequisites, ROCm, SSH, and the system
environment.

## Supported Systems and GPUs

| Host | CPU architecture | Workload |
| --- | --- | --- |
| Ubuntu 24.04 | `x86_64` | Compute |
| Ubuntu 26.04 | `x86_64` | Compute |

Ubuntu 24.04 is normalized to the supported 24.04.4 record. Other operating
systems, CPU architectures, and workloads are rejected.

The installer supports these architecture-specific artifacts:

```text
gfx950 gfx942 gfx90a gfx908 gfx1201 gfx1200 gfx1100 gfx1101 gfx1102 gfx1030
gfx1151 gfx1150 gfx1152 gfx1153 gfx1103
```

### Fail-Closed GPU Selection

Automatic pre-install detection scans KFD topology nodes with
`cpu_cores_count == 0` and a nonzero `gfx_target_version`. The decimal target is
decoded into its conventional `gfx` name. The installer validates every GPU
node, removes duplicates, and sorts the complete set. Zero detected targets or
any unsupported target fails before system mutation. One or more supported
targets, including multiple unique architectures, are accepted automatically.

`--gpu-arch` may be repeated. If present, its complete set replaces automatic
KFD discovery rather than extending it. The installer validates, deduplicates,
and sorts the explicit values. An override may intentionally request supported
artifact coverage for hardware that is currently absent, which supports
recovery and pre-provisioning. Any unsupported member rejects the complete set.
Unless a required reboot defers verification, every explicitly requested target
must then appear as a `rocminfo` agent.

For display only, the installer reads all available
`/sys/class/drm/card*/device/product_name` values. For a card with an empty
value, it performs an exact device/revision lookup in the installed
`/usr/share/libdrm/amdgpu.ids` file and prefixes the resulting marketing name
with `AMD `. The unique nonempty product names are sorted independently and are
not correlated with individual `gfx` targets. They never select a package, SKU,
driver, or kernel. The normalized `gfx` collection selects the kernel policy;
pre-install detection does not use `rocminfo`,
`/proc/cpuinfo`, or `lspci`; `rocminfo` remains a post-install verification
requirement.

## Kernel and Driver Requirements

The installer resolves one policy for the complete supported `gfx` set, matches
both kernel series and flavor, and only uses official Ubuntu metapackages.

| Host and complete GPU set | Resolved driver mode | Kernel target | Metapackage |
| --- | --- | --- | --- |
| Ubuntu 24.04 with only `gfx1103`, `gfx1150`, `gfx1151`, `gfx1152`, or `gfx1153` | Inbox only | `6.14.*-oem` | `linux-oem-6.14` |
| Ubuntu 24.04 with only non-Ryzen supported targets | Inbox or DKMS | `6.8.*-generic` | `linux-generic` |
| Ubuntu 26.04 with any supported set | Inbox or DKMS | `7.0.*-generic` | `linux-generic-7.0` |

On Ubuntu 24.04, a set that combines any Ryzen-scoped target with any other
supported target is rejected before mutation. Ryzen-scoped targets require the
resolved inbox driver; explicit `dkms` is rejected. Ubuntu 26.04 permits every
supported collection under its one 7.0 generic policy.

The plan reports `kernel_status`, `kernel_target`, and `kernel_package`.
`ready` means the running `uname -r` already matches the target series and
flavor. `reboot-required` means the target metapackage is installed, a matching
boot image is a readable nonempty regular file, and the running kernel does not
match. Otherwise the status is `install-required`.

For `install-required`, after confirmation the installer first requires at
least 512 MiB (524288 KiB) free on the filesystem backing `/boot`, then runs
`apt-get update`, confirms a candidate for the exact metapackage, simulates a
`--no-remove --install-recommends` transaction, rejects any simulated `Remv `
line, and installs the one approved metapackage with `--no-remove`. It then
verifies that the metapackage is installed and that a matching `/boot/vmlinuz-*`
image exists. It marks the reboot as required and stops before driver or ROCm
work. `reboot-required` similarly performs no APT work and stops for reboot.
`--skip-reboot` suppresses the reboot command but still stops the run.

`auto` resolves to the inbox AMDGPU driver. Explicit `dkms` installs AMDGPU
31.40 from AMD's Ubuntu repository. `inbox` and `auto` remove conflicting old
DKMS state under the configured cleanup policy.

### Existing DKMS Installations

The script checks the installed `amdgpu-dkms` and `amdgpu-dkms-firmware`
packages and registered AMDGPU DKMS modules.

- Inbox mode purges installed legacy DKMS packages before any prerequisite APT
  update or install, then verifies that no AMDGPU DKMS residue remains.
- DKMS mode keeps a clean 31.40 installation unchanged.
- DKMS mode purges an older, mixed, or malformed AMDGPU DKMS install, verifies
  that no residue remains, then configures the 31.40 repository and installs it.
- Any remaining AMDGPU DKMS package or registration after package removal stops
  the installation.

The cleanup policy applies whenever removal is required:

| Policy | Behavior |
| --- | --- |
| `auto` | Ask for confirmation in an interactive run. Refuse cleanup in a non-interactive run. |
| `ask` | Ask for confirmation in an interactive run. Refuse cleanup in a non-interactive run. |
| `always` | Remove the conflicting installation without asking. |
| `never` | Refuse the migration without changing the driver. |

For unattended migration from an older driver, pass
`--dkms-cleanup always`.

## Installation Methods

### APT, Default

APT configures AMD's `packages-multi-arch` repository for `ubuntu2404` or
`ubuntu2604`, then resolves one full architecture-specific Core SDK package per
requested `gfx` target:

```text
amdrocm-core-sdk7.14-<gfx>
```

For example, `gfx1151` installs `amdrocm-core-sdk7.14-gfx1151`. A
`gfx1151,gfx1201` plan installs `amdrocm-core-sdk7.14-gfx1151` and
`amdrocm-core-sdk7.14-gfx1201` together in one `apt-get install` transaction.
There is no generic all-architecture fallback.

Before that installation, APT checks the installed package database and removes
only exact installed legacy names matching `^rocm($|-)`, such as `rocm` and
`rocm-dev`. It never uses a package glob and never selects `amdrocm*` packages
for this migration. The current package installation owns its own metadata and
alternatives; the installer exposes the APT stack from `/opt/rocm/core-7.14`
instead of relying on a stale `/opt/rocm` link.

### Pip

`--method pip` creates `/opt/rocm-7.14.0-venv` and installs one pinned
requirement from AMD's multi-architecture wheel index. The requirement contains
one `device-<gfx>` extra for every requested target:

```text
rocm[libraries,device-<gfx>]==7.14.0
```

For `gfx1151` plus `gfx1201`, the exact requirement is:

```text
rocm[libraries,device-gfx1151,device-gfx1201]==7.14.0
```

The system profile exposes the virtual environment's `bin` directory but
doesn't activate the environment automatically.

### Tarball

For one requested target, `--method tarball` selects the reviewed artifact
mapped to that target, which may be architecture-specific or family-specific.
For example, `gfx1151` selects
`therock-dist-linux-gfx1151-7.14.0.tar.gz`. Multiple requested targets select
the single reviewed full artifact:

```text
therock-dist-linux-multiarch-7.14.0.tar.gz
```

The installer never overlays architecture-specific or family-specific
tarballs. Every target must still be in the supported list before either form
is selected. The archive extracts into a temporary staging directory, promotes
the result to `/opt/rocm-7.14.0`, then updates `/opt/rocm`. A failed extraction
or activation leaves the previous installation in place when rollback succeeds.

All three methods use the same GPU, OS, kernel-preparation, and driver policy.

## Command-Line Options

| Option | Meaning |
| --- | --- |
| `--method METHOD` | Installation method: `apt`, `pip`, or `tarball`. Default: `apt`. |
| `--gpu-arch ARCH` | Replace automatic KFD detection with a supported architecture. May be repeated to form the complete override set; duplicate values are removed. |
| `--driver-mode MODE` | `auto` (default), `inbox`, or `dkms`. |
| `--skip-ssh` | Skip OpenSSH setup and any root password update. |
| `--root-password PASS` | Set the root password during SSH setup. |
| `--skip-reboot` | Don't reboot after an installation that requires one. |
| `--reboot-delay MIN` | Delay a required reboot by 0 to 120 minutes. `0` means immediate. |
| `--verify-only` | Verify an existing installation and make no install changes. |
| `--uninstall` | Remove the ROCm 7.14.0 installation. |
| `--non-interactive` | Run without confirmation prompts. |
| `--dkms-cleanup POLICY` | DKMS cleanup policy: `auto`, `ask`, `always`, or `never`. Default: `auto`. |
| `--help`, `-h` | Show command help. |

`--verify-only` and `--uninstall` can't be used together. Password values that
contain a newline or carriage return are rejected.

## Examples

Install with automatic GPU detection and the default APT method:

```bash
sudo bash ./rocm-install.sh
```

Install for one explicit target instead of using KFD detection:

```bash
sudo bash ./rocm-install.sh --gpu-arch gfx1151
```

On Ubuntu 26.04, pre-provision a Ryzen AI Max+ 395 system with its `gfx1151`
integrated GPU and a Radeon AI PRO R9700 `gfx1201` discrete GPU by supplying
both targets:

```bash
sudo bash ./rocm-install.sh \
  --gpu-arch gfx1151 \
  --gpu-arch gfx1201
```

On Ubuntu 24.04, do not combine those targets: `gfx1151` requires the
Ryzen-scoped 6.14 OEM inbox policy, while `gfx1201` requires the 6.8 generic
policy. The installer rejects that mixed set rather than synthesizing an
unsupported policy.

On Ubuntu 26.04, the default APT plan includes this excerpt:

```text
INSTALL PLAN
gfx=gfx1151,gfx1201
os=ubuntu-26.04
method=apt
artifact=amdrocm-core-sdk7.14-gfx1151,amdrocm-core-sdk7.14-gfx1201
driver_mode=inbox
kernel_status=ready
kernel_target=7.0.*-generic
kernel_package=linux-generic-7.0
```

The public plan labels are `gfx`, `os`, `method`, `artifact`, `driver_mode`,
`kernel_status`, `kernel_target`, `kernel_package`, and the optional
informational `product_name`. Collection values are rendered as sorted
comma-separated fields. A record that contains a comma is quoted in the CSV
field.

Install the pip package set without changing SSH or rebooting automatically:

```bash
sudo bash ./rocm-install.sh --method pip --skip-ssh --skip-reboot
```

Install from the reviewed tarball in an unattended run:

```bash
sudo bash ./rocm-install.sh --method tarball --gpu-arch gfx942 --driver-mode dkms \
  --non-interactive --dkms-cleanup always --skip-reboot
```

Change the root password while applying the default SSH configuration:

```bash
sudo bash ./rocm-install.sh --root-password 'replace-with-a-strong-password'
```

Verify an installed APT/default installation:

```bash
sudo bash ./rocm-install.sh --method apt --verify-only
```

Remove ROCm without a confirmation prompt:

```bash
sudo bash ./rocm-install.sh --uninstall --non-interactive
```

## Retained System Setup

After successful driver migration, the script installs required download,
signing, GPU detection, and time-sync packages before installing ROCm. It also
attempts to install these optional tools without failing the ROCm installation if
that optional step fails:

```text
build-essential cmake git python3 python3-pip python3-setuptools python3-wheel
vim htop tmux screen net-tools nfs-common rsync usbutils lshw dmidecode
sysstat iotop unzip zip p7zip-full jq libnuma-dev
```

The installation also:

- enables `systemd-timesyncd` and NTP;
- adds the invoking user to `video` and `render` when needed;
- writes GPU access rules to `/etc/udev/rules.d/70-amdgpu.rules`;
- writes APT linker and profile paths from `/opt/rocm/core-7.14`;
- writes tarball linker and profile paths from `/opt/rocm`;
- leaves user shell startup files unchanged.

Log out and back in, or reboot, before relying on new group membership.

## Verification and Reboot

When kernel preparation, a driver, group membership, or udev rule changes, the
script marks the current run as requiring a reboot. Verification then reports
that it is pending instead of claiming success, and the selected reboot policy
runs. Kernel preparation stops before verification because ROCm has not yet
been installed.

After reboot, verify the APT or tarball installation with:

```bash
sudo bash ./rocm-install.sh --method apt --verify-only
sudo bash ./rocm-install.sh --method tarball --verify-only
```

For a pip installation, use:

```bash
sudo bash ./rocm-install.sh --method pip --verify-only
```

Post-install verification requires both `rocminfo` and `amd-smi version`. The
installer requires a `rocminfo` agent for every requested `gfx` target. Extra
visible `gfx` agents are allowed, but a missing requested target fails
verification. `amd-smi version` must still report exactly ROCm 7.14.0. When the
current run requires a reboot, verification remains deferred as described
above. The `--method` value chooses the verification root, so the check invokes
the selected method's absolute binaries rather than depending on a future
profile update: APT uses
`/opt/rocm/core-7.14/bin`, tarball uses `/opt/rocm/bin`, and pip uses
`/opt/rocm-7.14.0-venv/bin`.

## Uninstall

Interactive uninstall asks for confirmation. `--non-interactive` skips that
prompt. The uninstall path:

- purges only installed architecture-specific `amdrocm` ROCm 7.14 full SDK
  package candidates;
- removes `/opt/rocm/core-7.14`, `/opt/rocm-7.14.0`, and
  `/opt/rocm-7.14.0-venv`;
- removes `/opt/rocm` only when it points to `/opt/rocm-7.14.0`;
- removes the ROCm APT source, ROCm package key, profile, linker file, and udev
  rules created by the installer;
- reloads the linker cache and udev rules.

Uninstall deliberately leaves legacy `rocm*` packages, `amdgpu-dkms`, the SSH
drop-in, OpenSSH package, AMDGPU repository configuration, optional tools, NTP
configuration, user group membership, and every kernel package unchanged.
Legacy packages are only removed during the explicit latest APT migration
described above.

## Troubleshooting

If pre-install GPU detection fails, inspect KFD topology:

```bash
cat /sys/class/kfd/kfd/topology/nodes/*/properties
```

Use one or more `--gpu-arch` options when you need to replace automatic
discovery, such as recovery or pre-provisioning for supported hardware that is
not currently visible. Without an override, every automatically detected target
must be supported.

If the driver isn't active after reboot, check:

```bash
lsmod | grep amdgpu
dmesg | grep amdgpu
```

For permission problems, confirm the invoking user has both groups:

```bash
id -nG "$USER"
```

## Resources

- [ROCm installation documentation](https://rocm.docs.amd.com/projects/install-on-linux/en/latest/)
- [AMD GPU driver repository](https://repo.radeon.com/amdgpu/)
- [ROCm on GitHub](https://github.com/ROCm)

## License

MIT License
