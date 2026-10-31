# glowing-octo-robot

A **pragmatic, automated Linux From Scratch** for virtual machines: source tarballs in, an
immutable, verified disk image and a container image out, rebuilt and version-checked by
CI rather than by hand. On top of it, system extensions: **podman**, a **Kubernetes
node**, and the **tools to debug** either.

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

`CLAUDE.md` has the reasons behind each decision, `docs/how-it-works.md` the mechanics,
`docs/sysext.md` the extension design, and `docs/debugging.md` how to look inside a running
machine.

## What you get

| artifact | what it is | size (amd64) |
| --- | --- | --- |
| `rootfs.erofs` + `rootfs.cmdline` | the disk image: EROFS behind dm-verity, and the kernel arguments carrying its root hash | 39 MiB |
| `flfs-oci.tar` | the same userspace as an OCI image, without kernel and systemd; published as `ghcr.io/fwilhe2/glowing-octo-robot/flfs` | 19 MiB |
| `extensions/podman.raw` | podman, Quadlet, netavark, aardvark-dns, pasta, newuidmap | 23 MiB |
| `extensions/kubernetes.raw` + `confexts/kubernetes.raw` | kubelet, kubeadm, kubectl, CRI-O, crictl, CNI plugins, and the `/etc` that goes with them | 86 MiB + 4 KiB |
| `extensions/debug.raw` | strace, perf, bpftool, tcpdump, gdbserver, socat, jq | 4 MiB |

The base is the **container runtime** (the kernel's namespaces, cgroup v2, overlayfs and
nftables, plus `crun` and `conmon`). The **engine** is whichever extension a machine
boots with: podman, the Kubernetes node, or neither.

## Quick start

```sh
./tools/vm.sh update                 # the latest green CI build into output/boot-image/
./tools/vm.sh start                  # boot a machine that keeps its /var, in the background
./tools/vm.sh ssh                    # a shell as `user` (--root for root)
./tools/vm.sh stop

./tools/vm.sh start dev --ext podman,debug  # another machine, with podman, strace, perf, ...
./tools/vm.sh list                   # what there is, what runs, which image each boots
./tools/k8s-demo.sh up               # a three-node Kubernetes cluster (see below)
```

`tools/vm.sh` is described under [Machines](#machines). For a throwaway boot with nothing
kept, the console in the terminal and a new key each time, there is
`./tools/boot-qemu.sh` (Ctrl-a x to quit) with `./tools/ssh.sh` in a second terminal;
`SYSEXTS="podman debug" ./tools/boot-qemu.sh` attaches extensions to it.
`./tools/boot-firecracker.sh` and `./tools/boot-vz.sh` (macOS, through vfkit) boot the same
image in the other two VMMs. The OCI image needs no VM:
`podman run --rm -it ghcr.io/fwilhe2/glowing-octo-robot/flfs:latest`. It has no package
manager; [`examples/nginx`](examples/nginx/README.md) is the template for building an
image on top of it.

## Building

```sh
./tools/build-image.sh               # glibc, kernel, every package, then all images and extensions
./build.sh <package>                 # or one package into staging/<package>/, re-merged into rootfs/
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
* **State is RAM by default.** `/var`, `/tmp` and `/run` are tmpfs, and `/home` and
  `/root` are symlinks into `/var` (`var/home`, `var/roothome`, as on ostree systems), so
  every boot starts from the same bytes. To update a machine, boot it from a newer image.
* **Or a disk for `/var`.** `systemd.mount-extra=/dev/vdb:/var:ext4:x-systemd.makefs,x-systemd.growfs`
  on the kernel command line makes systemd format a blank disk on the first boot and keep
  it from then on, growing the filesystem when the disk grows. `tools/vm.sh` gives every
  machine one ([Machines](#machines)); for a one-off boot,
  `VAR_DISK=output/var.img VAR_SIZE=20G ./tools/boot-qemu.sh` creates the file sparse if
  it is missing (4G by default) and keeps the VM's machine ID beside it. The homes are
  on that disk too, so dotfiles, shell history and rootless podman's images are kept as
  well as root's in `/var/lib/containers`.
* **No passwords anywhere.** `root` and `user` have none, ssh takes keys only, and the
  host hands the guest a public key as a systemd credential at every boot, so ssh logs in
  with nothing baked into the image: a new key per boot for `tools/boot-qemu.sh`, one per
  machine for `tools/vm.sh`. sshd reads that key from `/run`, never from a home, so a key
  from an earlier boot cannot linger on a `/var` disk; `~/.ssh/authorized_keys` is yours
  to add keys to, and kept with the home. At the console a username is enough.
* **Credentials through fw_cfg.** On qemu and libvirt, systemd also imports credentials
  from fw_cfg (`opt/io.systemd.credentials/`), the channel for anything too big for the
  kernel command line or too secret for `/proc/cmdline`, which every user can read:
  `-fw_cfg name=opt/io.systemd.credentials/<name>,string=<value>`, or libvirt's
  `<sysinfo type="fwcfg">`. It needs no firmware, so it works on arm64 too; inside the
  guest the credential is `/run/credentials/@system/<name>`.
  `QEMU_FWCFG_CREDENTIALS="name=value ..." ./tools/boot-qemu.sh` passes some. Firecracker
  and Virtualization.framework have no fw_cfg, and take credentials on the command line.
* **Networking** is systemd-networkd and systemd-resolved, with `ip`, `ping` and `curl`
  (OpenSSL, Mozilla's roots) in the image for using and debugging it.

## Machines

`./tools/vm.sh` keeps named qemu machines in `output/vms/<name>/`. Each has a `/var` disk
of its own, a machine ID and an ssh key; the root is the image, read-only as always. So
what is installed, pulled or configured under `/var`, and the homes, which live there,
survives a reboot, a stop and start, and an image update:

```sh
./tools/vm.sh start dev --ext podman --mem 4096 --size 20G   # create and boot it
./tools/vm.sh ssh dev --root podman pull docker.io/library/nginx
./tools/vm.sh ssh dev --root systemctl reboot   # back in seconds: same disk, key and image
./tools/vm.sh update && ./tools/vm.sh restart dev   # a new image under the same /var
./tools/vm.sh info dev                          # where it is, what it boots, what waits
```

* **Names.** Every command takes the machine's name first, and leaves it out for the
  default machine, `flfs`. The name is also the guest's hostname.
* **Options stick.** `--image`, `--ext`, `--mem` and `--cpus` on `start` (or `run`) are
  remembered, so a plain `start dev` boots it the way it last booted. `--ext a,b`
  replaces the extension list and `--no-ext` clears it.
* **The image.** `--image local` boots this checkout's build (`./tools/build-image.sh`),
  `--image ci` the one `./tools/vm.sh update` fetched, and `--image <dir>` any directory
  laid out like that one. A new machine takes `local` if there is a build. Every start
  copies the image into the machine's directory if its source changed, and says so with
  both root hashes. So a rebuild or a fetch never changes a disk under a running guest,
  and the update takes effect at the next start, not at a reboot.
* **Background or foreground.** `start` daemonizes qemu and waits until ssh answers.
  Closing the terminal does not stop the machine. `console` attaches to its serial
  console (Ctrl-] detaches; it needs `socat`), and `stop` powers it off cleanly.
  `run` is the same machine in the foreground, with the console in the terminal
  (Ctrl-a x). Either way the console is logged to `console.log`, and the previous boot's
  to `console.log.1`.
* **The disk.** `snapshot dev [name]` and `restore dev name` copy the `/var` disk while
  the machine is stopped (reflinks where the filesystem has them). `resize dev 40G` grows
  it, and the guest grows its filesystem at the next boot. `rm dev` deletes the machine.
  `./tools/clean.sh` leaves machines alone; only `--vms` deletes them.
* **ssh from anything.** `ssh -F output/vms/<name>/ssh/config flfs` is what `vm.sh ssh`
  runs, so `scp`, `sftp` and `rsync -e` take the same `-F`.

## System extensions

Software is added to a machine without changing its image: an extension is an EROFS
image that systemd-sysext (for `/usr`) or systemd-confext (for `/etc`) overlays at boot.
Extensions match the base by `SYSEXT_LEVEL` in os-release, not by version, so a base update
does not orphan them. A machine gets them in one of two ways:

* **Attached by the VMM**, the way the root is: a read-only disk per image, verified by
  dm-verity from a table on the kernel command line and mounted where systemd-sysext
  looks. One file serves any number of VMs. `./tools/vm.sh start --ext podman` does this,
  as does `SYSEXTS=podman` (or `kubernetes`, or `debug`) for `test/qemu-lib.sh` and
  `tools/boot-qemu.sh`.
* **Installed on the `/var` disk**, in `/var/lib/extensions` and `/var/lib/confexts`.
  This way is not verified yet: it would need libcryptsetup (#191).

A machine can have any number of extensions at once, and systemd-sysext stacks them all
over one `/usr`. With the VMM, list them in `SYSEXTS`, separated by spaces and quoted:
`SYSEXTS="podman debug"` or `SYSEXTS="kubernetes debug"`. On the `/var` disk, put each
`.raw` file in `/var/lib/extensions`. `systemd-sysext status` in the guest shows what is
merged. Two extensions must not ship the same file, and none here do.

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

Images and build layers live in RAM by default. Root's are in `/var/lib/containers`, and
rootless ones in `~/.local/share/containers`, which is under `/var` too. That tmpfs is
capped at half the VM's memory, and `tools/boot-qemu.sh` gives a VM 1 GiB. That is enough
to run small images, but not to pull a distribution image and apt-install a compiler into
it, which fails partway with *No space left on device*. To build images in the guest, give
it memory and a `/var` disk:

```sh
MEM=4096 VAR_DISK=output/var.img VAR_SIZE=20G SYSEXTS=podman ./tools/boot-qemu.sh
./tools/ssh.sh          # then podman build, pull, run as usual; --root for root's
```

Both storages are then on the disk, and survive reboots too.

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

`test/node-conformance.sh` holds a single node to Kubernetes' node conformance tests: the
`[NodeConformance]` specs of upstream's node e2e suite, built for the shipped kubelet's
version by `tools/build-node-e2e.sh` and run in the guest against the extension's kubelet
and CRI-O. It runs in CI beside `k8s.sh`, and locally on a build of your own or on CI's
(`./test/node-conformance.sh output/boot-image/rootfs.erofs output/boot-image/bzImage`
after `tools/fetch-image.sh`). `FOCUS=` narrows it to a few specs, and `KEEP=1` leaves the
node running afterwards.

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
| `test/check-rootfs-deps.sh`, `check-symbol-versions.sh`, `check-symbol-resolution.sh` | every library a binary needs is shipped, in a version it defines, and defines every function the binary calls |
| `test/kernel-caps.sh` | the kernel config has what containers and Kubernetes need |
| `test/selftest.sh` | each of the checks above fails on a tree broken in the way it exists to catch |
| `test/boot.sh`, `systemd.sh`, `verity.sh` | it boots, no unit fails, a credential arrives through fw_cfg, a tampered image is refused |
| `test/network.sh`, `ssh.sh` | DHCP, DNS, TLS; sshd, from the guest and from the host |
| `test/container.sh`, `podman.sh`, `rootless.sh` | crun on the base; podman with seccomp, networking and Quadlet; rootless |
| `test/sysext.sh` | extensions merge from both places, a wrong level and a tampered image are refused |
| `test/persistent-var.sh`, `vmm.sh`, `k8s.sh` | state and homes survive on a `/var` disk, and a new boot key logs in; Firecracker- and VZ-shaped boots; a cluster |
| `test/node-conformance.sh` | a node passes Kubernetes' node conformance tests |
| `test/check-image-files.sh` | each image ships what `test/image-files/` requires, and nothing it rules out |
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
