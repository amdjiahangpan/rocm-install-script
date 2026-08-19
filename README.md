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
for each detected target. Before mutation it prints the detected host, GPU
architecture, GPU class, detection source, driver policy, kernel policy, exact
artifacts, and ordered actions, then asks for confirmation.

Kernel changes are strict by default. When the running kernel does not match the
reviewed policy, the installer prints the current kernel, target series/flavor,
metapackage, and next command, then exits without installing a kernel or
rebooting. `--prepare-kernel` explicitly permits metapackage installation.
`--reboot-after-kernel` additionally selects one verified GRUB entry and permits
one reboot attempt; a failed switch is never retried automatically.

A ready kernel proceeds to context-sensitive driver migration before any
prerequisite APT transaction. Clean AMDGPU 31.40 DKMS state is retained
unchanged. Conflicting driver state is removed only under the configured cleanup
policy before prerequisites, ROCm, SSH, and environment setup.

## Supported Systems and GPUs

| Host | CPU architecture | Workload |
| --- | --- | --- |
| Ubuntu 24.04 | `x86_64` | Compute |
| Ubuntu 26.04 | `x86_64` | Compute |

The detected Ubuntu description is preserved exactly in the public plan. The
base release selects the reviewed Ubuntu repository policy; the installer does
not infer or claim a point release from `VERSION_ID=24.04`. Other operating
systems, CPU architectures, and workloads are rejected.

The installer supports these architecture-specific artifacts:

```text
gfx950 gfx942 gfx90a gfx908 gfx1201 gfx1200 gfx1100 gfx1101 gfx1102 gfx1030
gfx1151 gfx1150 gfx1152 gfx1153 gfx1103
```

### Fail-Closed GPU Selection

Automatic detection uses two independent sources. KFD topology is primary: GPU
nodes require `cpu_cores_count == 0` and a nonzero `gfx_target_version`. When the
current driver cannot create KFD topology, the installer scans AMD display-class
PCI sysfs records and resolves only IDs present in its reviewed PCI-to-GFX table.
For example, RX 9060 XT PCI ID `1002:7590` resolves to Radeon `gfx1200`.

When KFD and PCI are both available, their complete normalized GFX sets and
reviewed classes must agree. A disagreement, ambiguity, unsupported GFX, or
unknown PCI ID fails before mutation. Unknown IDs are reported with an exact
`--gpu-arch` recovery command template; marketing names are never used to guess
an architecture.

`--gpu-arch` may be repeated. If present, its complete set replaces automatic
detection. Values are validated, deduplicated, sorted, and mapped to a reviewed
device class. Mixed device classes are rejected unless a host policy explicitly
supports them. Unless a required reboot defers verification, every explicitly
requested target must appear as a `rocminfo` agent.

DRM product names remain informational. Direct sysfs values or exact
`amdgpu.ids` device/revision lookups are displayed independently and never
select a package, SKU, driver, kernel, or PCI-to-GFX mapping. `rocminfo` remains
a post-install verification requirement.

## Kernel and Driver Requirements

The installer resolves one reviewed policy for the complete GFX set and matches
both kernel series and flavor.

| Host and GPU class | Resolved `auto` driver | Kernel target | Metapackage |
| --- | --- | --- | --- |
| Ubuntu 24.04 Ryzen (`gfx1103`, `gfx1150`-`gfx1153`) | Inbox | `6.14.*-oem` | `linux-oem-6.14` |
| Ubuntu 24.04 Radeon or Instinct | AMDGPU 31.40 DKMS | `6.8.*-generic` | `linux-generic` |
| Ubuntu 26.04 Ryzen | Inbox | `7.0.*-generic` | `linux-generic-7.0` |
| Ubuntu 26.04 Radeon or Instinct | AMDGPU 31.40 DKMS | `7.0.*-generic` | `linux-generic-7.0` |

Explicit driver modes are accepted only when the same reviewed policy permits
them. Mixed Ryzen/Radeon/Instinct sets fail closed rather than synthesizing an
unsupported common policy.

The plan reports `kernel_status`, `kernel_target`, and `kernel_package`.
`ready` means the running release matches the exact series and flavor.
`reboot-required` means the target package and a valid boot image exist but are
not running. Otherwise the status is `install-required`.

Neither non-ready status mutates the host by default. `--prepare-kernel` checks
at least 512 MiB free on `/boot`, validates the exact APT candidate, simulates a
`--no-remove --install-recommends` transaction, installs the reviewed
metapackage, and verifies its boot image. It then exits with a distinct
reboot-required status before driver or ROCm work.

`--reboot-after-kernel` requires `--prepare-kernel`. It resolves an exact GRUB
entry, verifies the one-shot selection, writes
`/var/lib/rocm-installer/pending-kernel`, and confirms before reboot. On the next
run, a successful switch clears the state. If the boot ID changed but the
kernel still mismatches, the installer reports manual recovery and never
reboots again.

`auto` is context-sensitive; it is not an alias for inbox. Radeon and Instinct
paths select AMDGPU 31.40 DKMS, while reviewed Ryzen paths select inbox.

### Existing DKMS Installations

The script checks the installed `amdgpu-dkms` and
`amdgpu-dkms-firmware` packages plus every registered AMDGPU DKMS module.

- A clean 31.40 installation is recognized using the real Debian build marker
  (`31400000`), matching firmware build, derived DKMS module version, installed
  status, and a module built for the running kernel.
- Clean DKMS state is idempotent: no purge, reinstall, or reboot request.
- Older, partial, mixed-build, or malformed state is removed before configuring
  the 31.40 repository and installing the driver once.
- Inbox mode removes conflicting DKMS state only when the reviewed GPU/host
  policy permits inbox.
- Any residue after removal or inconsistent state after installation stops the
  lifecycle with a stage-specific error.

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
| `--gpu-arch ARCH` | Replace automatic KFD/PCI detection with a supported architecture. May be repeated; duplicate values are removed. |
| `--driver-mode MODE` | `auto` (default), `inbox`, or `dkms`; explicit modes must match the reviewed host/GPU policy. |
| `--skip-ssh` | Skip OpenSSH setup and any root password update. |
| `--root-password PASS` | Set the root password during SSH setup. |
| `--prepare-kernel` | Explicitly install the reviewed kernel metapackage when the running kernel is not ready. |
| `--reboot-after-kernel` | With `--prepare-kernel`, select and verify one GRUB boot attempt, persist pending state, and reboot once. |
| `--skip-reboot` | Suppress post-driver/group/udev reboot and the final command after explicit kernel boot selection. |
| `--reboot-delay MIN` | Delay an allowed reboot by 0 to 120 minutes. `0` means immediate. |
| `--verify-only` | Verify an existing installation and make no install changes. |
| `--uninstall` | Remove the ROCm 7.14.0 installation. |
| `--non-interactive` | Run without prompts; kernel reboot still requires both explicit kernel flags. |
| `--dkms-cleanup POLICY` | DKMS cleanup policy: `auto`, `ask`, `always`, or `never`. Default: `auto`. |
| `--help`, `-h` | Show command help. |

`--verify-only` and `--uninstall` cannot be combined. Kernel preparation cannot
be combined with either mode, and `--reboot-after-kernel` requires
`--prepare-kernel`. Password values containing a newline or carriage return are
rejected.

## Examples

Install with automatic GPU detection and the default APT method:

```bash
sudo bash ./rocm-install.sh
```

Install for one explicit target instead of using KFD detection:

```bash
sudo bash ./rocm-install.sh --gpu-arch gfx1151
```

RX 9060 XT is Radeon `gfx1200`. With working KFD and the reviewed PCI record, an
Ubuntu 24.04 plan includes:

```text
INSTALL PLAN
gfx=gfx1200
gpu_class=radeon
gpu_source=kfd+pci
os=Ubuntu 24.04.2 LTS
os_policy=ubuntu-24.04.4
method=apt
artifact=amdrocm-core-sdk7.14-gfx1200
driver_mode=dkms
kernel_status=ready
kernel_target=6.8.*-generic
kernel_package=linux-generic
```

The plan's detected OS description is factual; `os_policy` names the internal
reviewed repository/kernel policy. `gpu_source=pci` indicates recovery before a
working KFD driver, while `kfd+pci` means both sources agreed.

Mixed Ryzen, Radeon, and Instinct classes are rejected on every host unless an
explicit reviewed policy is added. Supplying multiple targets does not bypass
that rule.

The public plan labels are `gfx`, `gpu_class`, `gpu_source`, `os`, `os_policy`,
`method`, `artifact`, `driver_mode`, `kernel_status`, `kernel_target`,
`kernel_package`, and optional informational `product_name`. Collection values
are rendered as sorted comma-separated fields; records containing commas are
CSV-quoted.

Inspect a kernel mismatch without changing the host:

```bash
sudo bash ./rocm-install.sh --skip-ssh --skip-reboot
```

Explicitly install the reviewed kernel but leave boot selection to the user:

```bash
sudo bash ./rocm-install.sh --prepare-kernel --skip-ssh --skip-reboot
```

Allow one verified GRUB boot attempt:

```bash
sudo bash ./rocm-install.sh \
  --prepare-kernel \
  --reboot-after-kernel \
  --skip-ssh
```

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

Kernel preparation is separate from post-install reboot handling. A non-ready
kernel never changes the system by default. Explicit preparation stops before
driver or ROCm work and exits nonzero. Explicit one-shot reboot stores the
expected target, GRUB entry, boot ID, and attempt count. A successful next boot
clears the state; a failed switch prints manual recovery instructions and never
reboots automatically again.

Driver, group-membership, or udev changes can still require a post-install
reboot. `--skip-reboot` suppresses that command. Verification reports pending
instead of claiming success when the current run changed state that must be
activated by reboot.

After reboot, verify APT or tarball installations with:

```bash
sudo bash ./rocm-install.sh --method apt --verify-only
sudo bash ./rocm-install.sh --method tarball --verify-only
```

For pip:

```bash
sudo bash ./rocm-install.sh --method pip --verify-only
```

Verification requires both `rocminfo` and `amd-smi version`. Every requested
GFX target must appear as a `rocminfo` agent; extra agents are allowed.
`amd-smi version` must report exactly ROCm 7.14.0. The selected method controls
the absolute verification root: APT uses `/opt/rocm/core-7.14/bin`, tarball uses
`/opt/rocm/bin`, and pip uses `/opt/rocm-7.14.0-venv/bin`.

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
