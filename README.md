# glowing-octo-robot

glowing-octo-robot builds a small Linux system for virtual machines and containers. Packages
are built from pinned source archives, assembled into a read-only EROFS disk image, and
published as an OCI image. Optional systemd extensions add Podman, Kubernetes, and debugging
tools without changing the base image.

The project targets QEMU, Firecracker, and Apple's Virtualization.framework. It is built
from source but uses a pinned Debian builder toolchain; it is not a self-hosting Linux From
Scratch build. The base includes systemd, glibc, bash, coreutils, networking tools, and the
container runtime components needed by `crun`. It has no package manager and does not target
physical hardware.

## Images and extensions

| Artifact | Contents |
| --- | --- |
| `output/rootfs.erofs` and `output/rootfs.cmdline` | Read-only EROFS root with a dm-verity hash tree; keep the files together. |
| `output/flfs-oci.tar` | OCI image of the userspace, without a kernel or systemd. |
| `output/extensions/*.raw` | Optional system extensions, including Podman, Kubernetes, and debugging tools. |
| `output/confexts/*.raw` | Configuration extensions used with the corresponding system extension. |

The disk root is verified by dm-verity at read time. `/var`, `/tmp`, and `/run` are
temporary filesystems by default. `/home` and `/root` point into `/var`; attach a writable
`/var` disk when state must survive reboot. The `vm.sh` workflow creates and manages one
for each VM.

System extensions are EROFS images merged by systemd-sysext at boot; configuration
extensions use systemd-confext. Extensions attached by the VM tools are read-only and
dm-verity verified. Extensions installed under `/var` are not verified.

## Quick start

Fetch the latest successful CI image, start a persistent QEMU machine, and connect over SSH:

```sh
./tools/vm.sh update
./tools/vm.sh start
./tools/vm.sh ssh
./tools/vm.sh stop
```

`update` runs `tools/fetch-image.sh`, which checks every downloaded file against the
`bundle-<arch>` manifest the same CI run wrote (run, commit, SHA-256 per file) and replaces
`output/boot-image/` only once all of it matches; a failed fetch leaves the previous image.

Attach extensions when starting a machine:

```sh
./tools/vm.sh start dev --ext podman,debug
./tools/vm.sh ssh dev
```

For a disposable interactive QEMU boot, use `./tools/boot-qemu.sh`; set
`SYSEXTS="podman debug"` to attach extensions. `tools/boot-firecracker.sh` and
`tools/boot-vz.sh` boot the same image with Firecracker and vfkit, respectively; vfkit
requires macOS on Apple silicon. To run the OCI image directly:

```sh
podman run --rm -it ghcr.io/fwilhe2/glowing-octo-robot/flfs:latest
```

The OCI image has no package manager. See [`examples/nginx`](examples/nginx/README.md) for
an example image built on top of it.

See [Machines](#machines) for persistent VM commands and [System extensions](#system-extensions)
for attaching or building extensions.

## Host requirements

The project builds and publishes `amd64` and `arm64` images. Building from source requires
Podman; fetching CI artifacts requires the GitHub CLI (`gh`). QEMU boots can run with or
without KVM, though KVM is recommended for performance. Firecracker requires Linux and KVM;
vfkit requires macOS on Apple silicon. The Kubernetes demo requires KVM and about 8 GB of
RAM.

## Build

Build all packages and assemble both image formats:

```sh
./tools/build-image.sh
```

The build requires Podman and runs package builds in the repository's builder image. Each
package is declared in `packages/<name>/env.sh` and built by `packages/<name>/build.sh`.
Package archives are pinned by version and checksum. Package compilation runs without
network access. See [How the build works](docs/guides/how-it-works.md) for the build flow
and [Build inputs](docs/guides/build-container.md) for the builder and source images.

Useful variants:

```sh
./tools/build-image.sh --image-only       # assemble from the existing rootfs/
./tools/build-image.sh --flavour erofs    # assemble only the disk image
./tools/build-image.sh --only strace      # build one package, then assemble
./build.sh strace                         # build one package into staging/
./tools/clean.sh                           # remove rebuildable build output
```

Build products are written under `output/`; package staging is under `staging/`, with the
merged filesystem under `rootfs/`. The default clean removes rebuildable output but keeps
source downloads and VM disks; see `./tools/clean.sh --help` for options. Files placed under
the git-ignored `extra/` directory are copied into each assembled image. Software built
from source should be added as a package instead.

For build details, see the [documentation index](docs/README.md).

## Disk image behavior

- **Immutable root:** EROFS is mounted read-only, and dm-verity checks blocks against the
  root hash in `rootfs.cmdline`. A mismatch causes an I/O error.
- **Ephemeral state by default:** `/var`, `/tmp`, and `/run` are tmpfs. A VM can attach a
  disk for `/var`; systemd formats a blank disk and grows its filesystem when the disk is
  enlarged.
- **SSH keys only:** accounts have no passwords and sshd accepts keys. The VM tools pass a
  public key as a systemd credential at boot. `tools/vm.sh` keeps a key per machine;
  `tools/boot-qemu.sh` generates a key for each boot.
- **Networking:** systemd-networkd and systemd-resolved provide guest networking. The base
  includes `ip`, `ping`, and `curl` for inspection and connectivity checks.

QEMU can pass systemd credentials through fw_cfg. See
[Debugging](docs/guides/debugging.md) for credential and console details.

## Machines

`tools/vm.sh` manages named QEMU machines under `output/vms/<name>/`. Each machine has its
own `/var` disk, machine ID, SSH key, and copy of the image. Image updates are picked up on
the next start, not on a guest reboot.

```sh
./tools/vm.sh start dev --ext podman --mem 4096 --size 20G
./tools/vm.sh ssh dev --root podman pull docker.io/library/nginx
./tools/vm.sh snapshot dev before-change
./tools/vm.sh stop dev
./tools/vm.sh update
./tools/vm.sh restart dev
./tools/vm.sh list
```

Commands default to the machine named `flfs`. `start` runs QEMU in the background; `run`
runs it in the foreground. `console` attaches to the serial console, `stop` shuts down the
guest, `resize` grows its `/var` disk, and `restore` restores a snapshot. Use
`./tools/vm.sh --help` for command syntax. See [Debugging](docs/guides/debugging.md) for
consoles and logs.

## System extensions

Extensions add software to a machine without rebuilding the base. The repository provides
`podman`, `kubernetes`, and `debug` extensions. Attach one or more at boot with
`--ext podman,debug` in `vm.sh`, or set `SYSEXTS="podman debug"` for `boot-qemu.sh`.

Podman includes Quadlet and rootless container support. The Kubernetes extension includes
kubelet, kubeadm, kubectl, CRI-O, crictl, and CNI plugins. A Kubernetes node needs persistent
storage for `/var`. To start the included three-node demo:

```sh
./tools/k8s-demo.sh up
./tools/k8s-demo.sh kubectl get pods -A
./tools/k8s-demo.sh down
```

The demo requires KVM, about 8 GB of RAM, and access to `registry.k8s.io` and `ghcr.io`.
[System extensions](docs/guides/sysext.md) explains how extensions are built, attached,
and verified. The
[documentation index](docs/README.md) links to build guides and design proposals.

## Verification and maintenance

CI builds the images and runs static checks, boots, container and extension checks,
reproducibility checks, and Kubernetes tests. Run an individual test with the image and
kernel paths it requires, for example:

```sh
./test/podman.sh output/rootfs.erofs rootfs/boot/bzImage
```

`./tools/check-updates.sh` checks pinned package versions. `./tools/bump-version.sh
<package> <version>` updates a package pin and checksum. The weekly update workflow opens
pull requests for available updates.

To add a package, create `packages/<name>/env.sh` and `packages/<name>/build.sh`; declare
its version, source URL, checksum, and license in `env.sh`. See `CLAUDE.md` for build-system
constraints and common pitfalls.
