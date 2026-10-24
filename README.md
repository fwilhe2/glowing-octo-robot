# glowing-octo-robot

A **pragmatic, automated Linux From Scratch** for virtual machines: source tarballs in, an
immutable, verified disk image and a container image out, rebuilt and version-checked by
CI rather than by hand. On top of it, two system extensions: **podman**, and a
**Kubernetes node**.

## What this is

A minimal but genuinely useful general-purpose Linux, built from source and kept current.
The image is small because nothing unnecessary was added, not because something useful was
taken away.

* **systemd, glibc, GNU coreutils and bash** are fixed choices. `bash` is the only
  interpreter in the image.
* **No self-hosted toolchain.** The Debian builder image is the compiler, deliberately and
  permanently. glibc is the one exception, built here and compiled against, because a skew
  there produces binaries that cannot start.
* **Modern and established, both.** Every choice should be one a competent engineer would
  defend today: neither the inertia option nor last month's GitHub project.
* **Everything is DFSG-free**, and each package declares its license (`LICENSE=` in
  `env.sh`, checked by `test/check-licenses.sh`).
* **Virtual machines only**: qemu, Firecracker and Apple's Virtualization.framework. Real
  hardware is a non-goal.

`CLAUDE.md` has the reasons behind each decision, `docs/how-it-works.md` the mechanics, and
`docs/sysext.md` the extension design.

## What you get

| artifact | what it is | size (amd64) |
| --- | --- | --- |
| `rootfs.erofs` + `rootfs.cmdline` | the disk image: EROFS behind dm-verity, and the kernel arguments carrying its root hash | 39 MiB |
| `flfs-oci.tar` | the same userspace as an OCI image, without kernel and systemd; published as `ghcr.io/fwilhe2/glowing-octo-robot/flfs` | 19 MiB |
| `extensions/podman.raw` | podman, Quadlet, netavark, aardvark-dns, pasta, newuidmap | 23 MiB |
| `extensions/kubernetes.raw` + `confexts/kubernetes.raw` | kubelet, kubeadm, kubectl, CRI-O, crictl, CNI plugins, and the `/etc` that goes with them | 86 MiB + 4 KiB |

The base is the **container runtime** (the kernel's namespaces, cgroup v2, overlayfs and
nftables, plus `crun` and `conmon`). The **engine** is whichever extension a machine
boots with: podman, the Kubernetes node, or neither.

## Quick start

```sh
./tools/fetch-image.sh               # the latest green CI build into output/boot-image/
./tools/boot-qemu.sh                 # boot it; Ctrl-a x to quit
./tools/ssh.sh                       # in a second terminal: a shell as `user` (--root for root)

SYSEXTS=podman ./tools/boot-qemu.sh  # the same machine, with podman
./tools/k8s-demo.sh up               # a three-node Kubernetes cluster (see below)
```

`./tools/boot-firecracker.sh` and `./tools/boot-vz.sh` (macOS, through vfkit) boot the same
image in the other two VMMs. The OCI image needs no VM:
`podman run --rm -it ghcr.io/fwilhe2/glowing-octo-robot/flfs:latest`.

## Building

```sh
./tools/build-image.sh               # glibc, kernel, every package, then all images and extensions
./build.sh <package>                 # or one package into the rootfs/ staging tree
./tools/build-image.sh --image-only  # re-assemble images and extensions from what is staged
```

Each package is two files, `packages/<pkg>/env.sh` (version, URL, SHA256, license) and
`build.sh` (configure, compile, install), built in one builder image with `--network=none`
against our own glibc. Packages whose `env.sh` says `EXTENSION=<name>` install into
`extensions/<name>/` instead of `rootfs/`, and become that extension. Builds are
reproducible to the byte, and CI checks it. `./tools/clean.sh` gives the disk space back.

## The disk image

* **Immutable and verified.** The root is EROFS, attached read-only, and a dm-verity hash
  tree appended to it is checked against the root hash in `rootfs.cmdline` on every read.
  A changed byte is an I/O error and a tampered image does not boot. Keep the image and its
  `.cmdline` together.
* **State is RAM by default.** `/var`, `/home`, `/root`, `/tmp` and `/run` are tmpfs, so
  every boot starts from the same bytes. To update a machine, boot it from a newer image.
* **Or a disk for `/var`.** `systemd.mount-extra=/dev/vdb:/var:ext4:x-systemd.makefs,x-systemd.growfs`
  on the kernel command line makes systemd format a blank disk on the first boot and keep
  it from then on. `VAR_DISK=output/var.img ./tools/boot-qemu.sh` does this for qemu.
* **No passwords anywhere.** `root` and `user` have none, ssh takes keys only, and
  `tools/boot-qemu.sh` hands the guest an ephemeral key as a systemd credential, so
  `tools/ssh.sh` logs in with nothing baked into the image.
* **Networking** is systemd-networkd and systemd-resolved, with `ip`, `ping` and `curl`
  (OpenSSL, Mozilla's roots) in the image for using and debugging it.

## System extensions

Software is added to a machine without changing its image: an extension is an EROFS
image that systemd-sysext (for `/usr`) or systemd-confext (for `/etc`) overlays at boot.
Extensions match the base by `SYSEXT_LEVEL` in os-release, not by version, so a base update
does not orphan them. A machine gets them in one of two ways:

* **Attached by the VMM**, the way the root is: a read-only disk per image, verified by
  dm-verity from a table on the kernel command line and mounted where systemd-sysext
  looks. One file serves any number of VMs. `SYSEXTS=podman` or `SYSEXTS=kubernetes`
  does this in `test/qemu-lib.sh`, and with it `tools/boot-qemu.sh`.
* **Installed on the `/var` disk**, in `/var/lib/extensions` and `/var/lib/confexts`.
  This way is not verified yet: it would need libcryptsetup (#191).

`./tools/build-extension.sh sysext|confext <name> <dir>` makes one of your own from a
directory tree.

## Containers

With the podman extension, containers work as you would expect, rootless included (for
`user`, through pasta and newuidmap/newgidmap, which hold file capabilities rather than
being setuid):

```sh
podman run --rm -it docker.io/library/alpine sh
podman run -d -p 8080:80 docker.io/library/nginx
```

To have a container start at boot, describe it as a Quadlet `.container` file. Give it
`UpheldBy=multi-user.target` next to `WantedBy=`: the extension is merged during early
boot, and a unit generated then misses the boot transaction with `WantedBy=` alone.
`systemctl enable --runtime --now podman.socket` serves the Docker-compatible API.

The base alone runs containers too, with `crun` on a bundle from `crun spec`.

## Kubernetes

A Kubernetes node is the base image plus the `kubernetes` extension pair. Nothing else is
installed, and nothing is configured on the node itself.

**What the extension is.** kubelet, kubeadm and kubectl 1.37, CRI-O 1.37 with pinns,
crictl, and the bridge, host-local, loopback and portmap CNI plugins, all built from
source here (`packages/kubernetes`, `cri-o`, `cri-tools`, `cni-plugins`). CRI-O runs on the
base's crun and conmon and reads the base's `/etc/containers`. Its minor version follows
Kubernetes'. CRI-O and kubelet start through `Upholds=`, which works for units merged
during early boot.

**How it copes with a read-only root.** Nothing is made writable. Each path the stack
writes is a link into `/var` or `/run`, shipped in the confext:

| path | becomes |
| --- | --- |
| `/etc/kubernetes` | `/var/lib/kubernetes` (kubeadm's PKI, kubeconfigs and static pod manifests) |
| `/etc/cni/net.d` | `/var/lib/cni/net.d` |
| `/opt/cni/bin` | `/var/lib/cni/bin` (in the sysext) |
| `/etc/crio/auth` | `/run/crio/auth` (short-lived registry credentials) |

So stock manifests work unmodified. kubeadm detects systemd-resolved and the cgroup
driver by itself, so a node needs no kubelet configuration of its own. A node does need a
disk for `/var`, because its identity lives there, and kubelet refuses to start on a
tmpfs.

The kernel carries what a node needs, built in: kube-proxy's nftables mode, VXLAN, the
`xt_*` matches kubeadm's preflight insists on, and `/usr/lib/modules/<release>/config`
for that preflight to read.

**The demo** forms a cluster from the image and the extension:

```sh
./tools/k8s-demo.sh up          # router + 3 nodes, kubeadm init/join, flannel, a demo Service
./tools/k8s-demo.sh kubectl get pods -A
./tools/k8s-demo.sh ssh 2       # root on k8s-2
./tools/k8s-demo.sh ps          # the VMs, their memory, and the nodes' status
./tools/k8s-demo.sh down
```

* **The VMs.** Every VM boots the unmodified image. The extension is attached to each
  node as one shared, verified read-only file, and each node gets a `/var` disk of its own.
* **The network.** The nodes share one segment behind a fourth, small VM, booted from the
  same image, that acts as switch, DHCP server and NAT. It is configured entirely by
  systemd credentials on its kernel command line. Each node has one NIC and gets its
  address by static lease, so kubelet needs no `--node-ip`.
* **The pod network** is flannel's stock manifest (VXLAN, nftables backend), pinned by
  checksum.
* **The demo itself** deploys four replicas behind a Service and checks that answers come
  from pods on more than one node.
* **kubectl** runs on the control plane over ssh. `output/k8s/kubeconfig` points a kubectl
  of your own at the API server's forward on `127.0.0.1:6443`.
* **What it needs:** KVM, about 8 GB of RAM, and access to registry.k8s.io and ghcr.io for
  the images.

`test/k8s.sh` runs the demo in CI on amd64. arm64 runners have no KVM, so it skips there.

**Current limits:**
* kubeadm is the only way a node joins.
* The control plane runs as static pods from registry.k8s.io, as kubeadm deploys it.
* Upgrading a node means a new extension file and a reboot.
* Extensions installed on `/var` rather than attached are not verified yet (#191).

## Tests

There is no unit-test suite. The checks below plus a real boot are the verification, and
CI runs all of them but the last:

| check | what it asks |
| --- | --- |
| `test/check-rootfs-deps.sh`, `check-symbol-versions.sh` | every library a binary needs is shipped, in a version it defines |
| `test/kernel-caps.sh` | the kernel config has what containers and Kubernetes need |
| `test/boot.sh`, `systemd.sh`, `verity.sh` | it boots, no unit fails, a tampered image is refused |
| `test/network.sh`, `ssh.sh` | DHCP, DNS, TLS; sshd, from the guest and from the host |
| `test/container.sh`, `podman.sh`, `rootless.sh` | crun on the base; podman with seccomp, networking and Quadlet; rootless |
| `test/sysext.sh` | extensions merge from both places, a wrong level and a tampered image are refused |
| `test/persistent-var.sh`, `vmm.sh`, `k8s.sh` | state survives on a `/var` disk; Firecracker- and VZ-shaped boots; a cluster |
| `test/oci.sh`, `rootfs-size.sh`, `vs-debian-slim.sh` | the OCI image runs; its size against the budget and against debian-slim |
| `test/reproducible.sh <pkg>` | a package builds to the same bytes twice (CI checks the images that way itself) |

Each takes the image and kernel as arguments, e.g.
`./test/podman.sh output/rootfs.erofs rootfs/boot/bzImage`.

## Adding a package

Packaging is the easy part. Choosing is where the mistakes are, so answer these in the
pull request:

* Is it maintained or just old?
* Is it established (Debian, Fedora and Alpine ship it)?
* Is there an equally established, more modern option?
* What does it drag in?
* Does it need an interpreter at runtime?

Then add `packages/<pkg>/env.sh` and `build.sh`. CI's build matrix picks the directory
up, and `./tools/bump-version.sh <pkg> <version>` keeps `VERSION` and `SHA256` in step.
Prefer configuring an optional dependency out over adding it to `builder/deps.txt`.
CLAUDE.md lists the traps that break silently.

## Keeping packages up to date

`./tools/check-updates.sh` reports what upstream has released since each pin.
`.github/workflows/update-packages.yml` runs it weekly and opens one pull request per
package, which CI builds and boots before it can merge. It needs the repository setting
*Settings → Actions → General → Workflow permissions → Allow GitHub Actions to create and
approve pull requests*.
