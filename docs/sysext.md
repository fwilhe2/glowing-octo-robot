# System extensions: a Kubernetes node without forking the image

**Status: the mechanism is in the base, and the Kubernetes node is an extension of it.**
systemd-sysext and systemd-confext merge extensions at boot, the image declares
`SYSEXT_LEVEL=1` and `CONFEXT_LEVEL=1`, and `test/sysext.sh` boots one (#187).
`packages/kubernetes`, `cri-o`, `cri-tools` and `cni-plugins` build into
`extensions/kubernetes/` (#188), `tools/build-image.sh` assembles that into a sysext and
a confext, and `tools/k8s-demo.sh` forms its cluster on them with nothing copied into a
guest (#189). podman is an extension too (#192), so the base is the container runtime
and the engine is a choice, and the demo's pod network is a stock flannel (#190).
Attached extensions are verified by dm-verity like the root; extensions loaded from
`/var/lib/extensions` are not yet (#191). This is the design for
adding software to the immutable disk image *without changing it*, with a Kubernetes node
as the case that justifies the mechanism.

Unverified claims are marked *(verify)*.

`tools/k8s-demo.sh` is the prototype for the stack this note describes, without the
mechanism: it copies the upstream release binaries (kubeadm, kubelet, kubectl, CRI-O's
static bundle) into each guest's `/var` over ssh, starts them from units in
`/run/systemd/system`, and forms a three-node kubeadm cluster on the unmodified image.
Everything it has to work around is a requirement on the extension, and the findings
below marked *(demo)* come from it.

## The problem

The disk image is one EROFS file behind a dm-verity root hash. That is the design: any
number of guests share it, an update is a new file, and a changed byte is an I/O error.
It also means there is no way to add anything to a machine. There is no package manager,
`/usr` and `/etc` have no write path, and that is deliberate.

Most software doesn't need to be added to the host, because it runs as a container:
podman and Quadlet already turn a `.container` file into a unit. The exceptions are
programs that have to run *on the host*, below the container runtime or beside it.
Kubernetes is the important one. kubelet and a CRI runtime manage the node's containers,
so they can't be one of them.

Today there are two ways to get them onto a machine, and both are bad:

- **Put them in the image.** kubelet and CRI-O together are 117 MiB as upstream ships
  them for 1.37 on amd64, and the whole extension (kubeadm, kubectl, crictl, pinns and
  four CNI plugins with them) is 307 MiB, against 144 MiB for the whole base image tree.
  That cost would fall on every user of an image whose size budget is checked in CI
  (`test/size-budget.txt`), for an aim that `CLAUDE.md` calls *an* aim, not *the* aim.
- **A `k8s-node` image variant** (`docs/image-variants.md`). That keeps other users'
  images small, but makes Kubernetes a second base image. Every base update becomes a
  Kubernetes node image to rebuild, and every Kubernetes update a base image to republish,
  even though the two have nothing to do with each other.

## The idea

A **systemd system extension** (sysext) is a filesystem image that carries a `/usr` tree
(and optionally `/opt`). At boot, `systemd-sysext` stacks every extension it finds over
the host's `/usr` as a read-only overlayfs. A **configuration extension** (confext) does
the same for `/etc`. The base image is never modified, and taking the extension away
gives back exactly the base.

That fits this image unusually well:

- **The format is the same as the root.** An extension can be EROFS with a dm-verity
  hash tree, built with the same `mkfs.erofs` and `veritysetup` calls as
  `output/rootfs.erofs`. The kernel already has every piece: `EROFS_FS`, `DM_VERITY`,
  `OVERLAY_FS` and `BLK_DEV_LOOP` are all `=y`.
- **The two release cycles come apart.** A base update (security fixes, a kernel bump)
  and a Kubernetes update (following the cluster's version skew policy) become separate
  files, swapped independently. Flatcar ships Kubernetes this way *(verify: the
  sysext-bakery's current shape)*.
- **Non-Kubernetes users pay nothing.** The base gains `systemd-sysext` and its units,
  and nothing else.

## The engines, too

Once the mechanism existed, keeping podman in the base was the same mistake as putting
Kubernetes there, made earlier. **The base is the container runtime; an engine is an
extension.** What every engine here runs on stays: the kernel's container features,
`crun`, `conmon` (in `/usr/bin`, where podman and CRI-O both find it), glib and pcre2 for
conmon, nftables, libseccomp, and `/etc/containers` with the containers/image policy and
registries both engines read. That keeps constraint 3 true of the base by itself — `crun
run` on a bundle needs nothing else, and `test/container.sh` boots no extension. What an
engine adds is an extension: `podman` is podman, Quadlet and rootlessport, netavark and
aardvark-dns, passt, and shadow's newuidmap/newgidmap with the file capabilities they
declare; `kubernetes` is kubelet, kubeadm, kubectl, CRI-O, crictl and the CNI plugins. A
machine boots with one, the other, or neither.

How each reaches a machine is the VMM's business. A node with a `/var` disk can carry its
extensions in `/var/lib/extensions`; any VM can be handed them as read-only disks, the
way it is handed the root (`SYSEXTS=` in `test/qemu-lib.sh`): each image is a virtio disk
with a serial, mounted by `systemd.mount-extra=` at `/run/extensions/<name>` before
`systemd-sysext.service` looks, and merged as a directory extension. One file serves any
number of guests, and the base needed nothing new for it.

## What goes where

Kubernetes is three layers here, and only the middle one is an extension:

| layer | what | why there |
| --- | --- | --- |
| **base image** | kernel symbols, `systemd-sysext`, `SYSEXT_LEVEL`, per-instance hostname | the kernel is built `CONFIG_MODULES=n`, so a feature can't arrive later as a module; everything else is small and useful beyond Kubernetes |
| **extension** | kubelet, CRI-O, CNI plugins, their units, default configuration | what has to run on the host, and only for a node |
| **pods** | kube-proxy, the CNI daemon, CoreDNS, the control plane | kubeadm already deploys them as DaemonSets and static pods, so the host needs only the kernel underneath them |

The first row is the one that can't be worked around. **An extension can't carry kernel
code here.** With modules off there is nothing to load, so every kernel feature a node
needs has to be built into the base kernel, even though most machines will never use it.
The cost is small: a few netfilter symbols.

### The base image

What issue #83 listed, checked against the tree as it is now:

| item | state |
| --- | --- |
| `CFS_BANDWIDTH`, cgroup v2, namespaces, overlayfs, veth, bridge, `BRIDGE_NETFILTER` | done |
| `NFT_CT`, `NFT_NAT`, `NFT_MASQ`, `NFT_FIB_INET` | done (netavark needed them) |
| seccomp enforced (`libseccomp`), timesyncd, `/var` on a disk, no shipped passwords | done |
| Go in the builder | done (`golang-go` in `builder/deps.txt`, for podman) |
| `NFT_NUMGEN`, `NFT_REJECT`, `NF_CT_NETLINK` | done (`k8s.config`): kube-proxy's nftables mode |
| `VXLAN`, `NFT_REDIR`, `NF_TABLES_NETDEV` | done (`k8s.config`): CNI overlays and nftables dataplanes |
| `NETFILTER_XT_TARGET_REDIRECT`, `NETFILTER_XT_MATCH_COMMENT` | done (`k8s.config`): kubeadm's preflight requires them *(demo)* |
| `/usr/lib/modules/<release>/config` | done (`packages/kernel`): kubeadm's preflight and kube-proxy's hostPath *(demo)* |
| per-instance hostname | done, by the VMM: `systemd.hostname=` on the kernel command line *(demo)* |
| `SYSEXT_LEVEL` in os-release | **missing**; see below |

kube-proxy should run in **nftables mode** (GA since 1.33 *(verify)*). The iptables mode
wants a much longer list (`XT_MATCH_COMMENT`, `STATISTIC`, `RECENT`, `MULTIPORT` and so
on) for the older mechanism. The symbols are in a `k8s.config` fragment of their own
rather than in `container.config`, which describes what a *container* needs, and the
check after `make vm.config` holds it like the others. Issue #83 named the conntrack one
`NF_CONNTRACK_NETLINK`; the symbol is `NF_CT_NETLINK`, and that check is what said so.

**The hostname** is the one base change that is about identity, not code. A cluster of
nodes all named `flfs` is not a cluster. The VMM passes `systemd.hostname=` on the
kernel command line, which systemd applies over `/etc/hostname` *(demo)*, alongside the
`systemd.machine_id=` `VAR_DISK` already passes. Identity belongs to the VM, not to the
image, the same reasoning that put the machine id beside the `/var` disk. So does a
node's address on a cluster network: the demo hands systemd-networkd a `.network` file as
a `network.network.<name>` credential, which systemd-network-generator writes into
`/run/systemd/network` at boot *(demo)*, and needs nothing from the image.

**`/usr/lib/modules/<release>` exists, though there are no modules** *(demo)*, holding a
link to `/boot/config`. Two things looked for it. kubeadm's preflight reads the kernel
config from a list of conventional paths — `/proc/config.gz`, `/boot/config-<release>`,
`/usr/lib/modules/<release>/config` and a few more, but not plain `/boot/config` — and
fails the node when it finds none. And kube-proxy's DaemonSet bind-mounts the host's
`/lib/modules` (Calico's and Cilium's do too), which a read-only root cannot grow at
runtime, so every kube-proxy pod failed with *mkdir /lib/modules: read-only file system*.
`packages/kernel/build.sh` installs it; the OCI flavour removes it with `/boot`.

Once kubeadm could read the config it had two complaints, and both are in `k8s.config`
now: `NETFILTER_XT_TARGET_REDIRECT` and `NETFILTER_XT_MATCH_COMMENT`. They are x_tables
extensions, which the nftables-mode kube-proxy does not use, but kubeadm's
SystemVerification requires them of every node whatever the mode, and the iptables
dataplanes of flannel and Calico use them through `NFT_COMPAT`. With both changes the
demo needs no workaround for the kernel at all *(demo)*.

### The extension

Two images from one build, with one version, because systemd merges `/usr` and `/etc`
as separate classes. Both are named `kubernetes.raw`, because an image's file name has to
be the name in its `extension-release.<name>`:

```
extensions/kubernetes.raw      sysext: EROFS + verity, like rootfs.erofs
├── usr/
│   ├── bin/kubelet, kubeadm, kubectl, crio, pinns, crictl
│   ├── libexec/cni/bridge, host-local, loopback, portmap
│   ├── libexec/kubernetes/kubelet-plugins/volume/exec/      empty, and staying so
│   ├── lib/systemd/system/kubelet.service, crio.service
│   ├── lib/systemd/system/multi-user.target.d/10-kubernetes.conf   Upholds= both
│   ├── lib/tmpfiles.d/kubernetes.conf               the /var directories below
│   └── lib/extension-release.d/extension-release.kubernetes
└── opt/cni/bin → /var/lib/cni/bin

confexts/kubernetes.raw        confext: the same, for /etc
└── etc/
    ├── kubernetes → /var/lib/kubernetes
    ├── cni/net.d → /var/lib/cni/net.d
    ├── crio/crio.conf.d/10-flfs.conf                crun, plugin_dirs
    ├── crictl.yaml
    └── extension-release.d/extension-release.kubernetes
```

- **CRI-O, not containerd.** It shares podman's image and storage libraries, its
  `policy.json` and `registries.conf`, conmon and crun, all of which the base already
  ships. That's why `CLAUDE.md` calls it the natural pairing. containerd would bring a
  second image store and its own shim.
- **Built as upstream builds them**: kubeadm, kubectl, crictl and the CNI plugins
  static, kubelet and CRI-O with cgo against our glibc through the same sysroot flags as
  podman (kubelet because upstream's `hack/lib/golang.sh` builds it so, CRI-O for
  libseccomp). All are Go, and the builder already has Go and pins it offline.
- **CNI plugins.** CRI-O uses CNI, not netavark. The reference
  `containernetworking/plugins` cover a single node, and the cluster's own CNI DaemonSet
  replaces them on a real one.
- **Enablement is `Upholds=` in a `multi-user.target` drop-in, not `.wants` symlinks.**
  Presets can't help, because they write to `/etc`. And the `.wants` links openssh and
  dbus use in the base arrive too late from an extension: `systemd-sysext.service` merges
  during `sysinit.target`, after PID 1 has already computed the boot transaction, so a
  `.wants` link that appears then is visible after the reload but starts nothing until
  the next boot. `test/sysext.sh` ships one unit of each kind and reports it: the
  `Upholds=` unit runs, the `.wants` one does not.
  `Upholds=` is re-evaluated continuously, so it also starts the units when an extension
  is merged at runtime with `systemd-sysext refresh`. `EXTENSION_RELOAD_MANAGER=1` in the
  extension-release file is what makes the merge reload PID 1 (`get_extension_release_metadata`
  in systemd 262's `sysext.c`).
- **No accounts.** kubelet and CRI-O run as root, so nothing needs sysusers, which an
  extension couldn't use anyway: the accounts are fixed when the base image is sealed.
- **No bundled libraries.** Everything else CRI-O links (glibc, libseccomp,
  libsystemd) is in the base, so the extension adds binaries only. Any library an
  extension does have to bring goes in `/usr/lib/<extension>/` behind a RUNPATH, never in
  `/usr/lib`: the overlay would shadow the base's copy for every program on the system.

#### Compatibility: `SYSEXT_LEVEL`

`systemd-sysext` refuses an extension whose `extension-release` doesn't match the host's
`os-release`. It must match `ID=flfs` and either `SYSEXT_LEVEL` or `VERSION_ID`, and
`ARCHITECTURE` if the extension names one. Matching on `VERSION_ID` would invalidate every
extension at every base release, which is exactly the coupling this design exists to
break.

So the base declares `SYSEXT_LEVEL=1` in `usr/lib/os-release`, and the number is a
**promise about the ABI an extension can rely on**, bumped deliberately. This project can
make that promise because of the rule that already governs every package: the libraries
only ever move forward. glibc is backward compatible, OpenSSL is held to 3.x, and an
extension built against today's base keeps running on next month's. The level changes
when that stops being true: an OpenSSL major version, a libseccomp soname, a crun that
drops an interface CRI-O uses.

`test/check-symbol-versions.sh` is the shape of the check that belongs with it: an
extension's versioned symbols checked against the base it declares itself compatible with.

## What a node writes, and where it goes

The Kubernetes stack assumes it can write to paths that are read-only here:

| path | written by | answer |
| --- | --- | --- |
| `/etc/kubernetes` | kubeadm: kubeconfigs, PKI, static pod manifests | confext symlink → `/var/lib/kubernetes` |
| `/etc/cni/net.d` | the CNI DaemonSet (flannel, Calico) installs its network config here | confext symlink → `/var/lib/cni/net.d` |
| `/opt/cni/bin` | the same DaemonSet's init container copies its plugin binaries here | sysext symlink → `/var/lib/cni/bin` |
| `/usr/libexec/kubernetes` | kubelet and the controller manager look for FlexVolume plugins; created at start *(demo)* | the sysext ships the directory, empty |
| `/var/lib/kubelet`, `/var/lib/containers`, `/var/lib/etcd` | kubelet, CRI-O, etcd | fine, on the `/var` disk |

**Nothing is made writable. Each path a node writes is a symlink into `/var`, and the
symlink is configuration** *(demo: a run with `/etc/kubernetes` and `/etc/cni/net.d` as
links into `/var` formed the cluster unchanged, static pods and PKI included)*. That is the rule the base already follows: `/etc/resolv.conf`
is a link into resolved's `/run`, and sshd's host keys moved to `/var/lib/sshd` rather than
`/etc/ssh` becoming writable. A link in a confext is as immutable and verity-checked as the
rest of `/etc`. What it points to is state, on the disk where state belongs, and a node that
reboots comes back as the same node. Stock manifests work unmodified: flannel's DaemonSet
writes to `hostPath: /etc/cni/net.d` and `/opt/cni/bin` like it does everywhere else, and
never learns that the writes land on `/var`. The directories behind the links are made by
the sysext's `tmpfiles.d` snippet. `systemd-tmpfiles-setup.service` runs after the merge
(`systemd-sysext.service` is `Before=` it), so the snippet is already visible when it runs.

Two alternatives were considered, and both lose:

- **A mutable confext** (`--mutable=yes`) does not make `/etc/kubernetes` writable. It
  makes all of `/etc` writable, with the upper layer in `/var/lib/extensions.mutable/etc`
  (systemd-sysext(8) in 262, "Mutability"). That is the demo's overlay under a systemd
  name. Worse, every file anything writes there shadows the base image's copy from then
  on, so `/etc` stops being "whatever the image says" after the first boot. That breaks
  updating by booting a new image.
- **Bind mounts from `/var`** work, but every path becomes a mount unit with a mount point
  to provide and an ordering against the confext merge to get right. A symlink needs
  neither.

**FlexVolume is answered by providing the directory, not by moving it.** kubelet's
`volumePluginDir` and the controller manager's `DirectoryOrCreate` hostPath both default
to `/usr/libexec/kubernetes/kubelet-plugins/volume/exec`, and both only need it to exist.
The demo redirects both to `/var/lib/kubelet`. With the directory in the sysext, both
settings go away. The directory stays empty, and that is correct: FlexVolume is
deprecated in favour of CSI, whose drivers run as pods, and on an immutable host a node
plugin installed by copying a binary to `/usr` is exactly what is not supposed to happen.
This is the same move as `/usr/lib/modules/<release>` in the base: give the software the
path it looks for rather than configuring it to look elsewhere.

**The node needs no kubelet configuration of its own** *(demo)*. The demo used to set two
kubelet options, and with both removed kubeadm wrote the same values into
`/var/lib/kubelet/config.yaml` on every node:

- **`resolvConf`.** `/etc/resolv.conf` is resolved's `127.0.0.53` stub, which can't be
  reached from a pod's network namespace. kubeadm checks whether systemd-resolved is
  active and, if it is, writes `resolvConf: /run/systemd/resolve/resolv.conf` itself.
- **`cgroupDriver: systemd`** is kubeadm's default, and the same as CRI-O's. kubelet 1.37
  also asks the CRI which driver to use (`KubeletCgroupDriverFromCRI`), so the two cannot
  disagree.

If a node default is ever needed, it goes in a drop-in through kubelet's `--config-dir`.
Those drop-ins override what kubeadm writes, and they ship in the sysext's `/usr/lib`.
Putting it in the cluster's kubeadm configuration would be wrong, because it is a property
of the OS, not of the cluster.

What CRI-O needs is one drop-in in the confext: crun as its runtime, and `plugin_dirs =
["/usr/libexec/cni", "/opt/cni/bin"]`, the extension's plugins first. conmon is in the
base's `/usr/bin` (#192), pinns in the sysext's, so CRI-O finds both on `$PATH`, and the
policy and registries are the base's `/etc/containers`.

CRI-O also refuses to start unless it can create two directories under `/etc/crio`
*(demo)*, and they get the two answers above. `policies/`, for per-namespace signature
policies, is configuration an administrator supplies: it ships, empty, like FlexVolume's
directory. `auth/` is where CRI-O's credential provider writes per-namespace registry
credentials: written state, so a link out of `/etc` like `/etc/kubernetes`, but into
`/run`, because short-lived secrets have no business surviving a reboot on the `/var`
disk.

**`--node-ip` went away with the second NIC** (see "The demo's network" below). kubelet
picks the address of the interface that carries the default route. That address is right
when a node has one NIC, and on a real multi-homed node `--node-ip` is the operator's
decision, not the image's.

**A node needs the `/var` disk**, because a tmpfs `/var` would lose its PKI and identity
at every reboot. Delivery mostly enforces this already: an extension in
`/var/lib/extensions` can only be there if `/var` is a disk. One delivered through
`/run/extensions` is the exception, so `kubelet.service` also refuses to start on a tmpfs
`/var`. That makes the failure a failed unit that names the reason, not a node that
silently forgets who it is.

## The demo's network

The demo used to give every guest two NICs: qemu's user-mode NAT, which is private to
each guest and where every guest is 10.0.2.15, plus a multicast segment with static
addresses for the cluster. That is where `--node-ip` came from, and the hand-written
`.network` credential per node. **Now it is one NIC per node on one segment, with a
router** (#186). That is what a real network looks like, and it is the shape in which
nothing about the network is node configuration: kubelet finds the right InternalIP on
every node with no flag.

**The router is one more VM, booted from the same image, and configured entirely on its
kernel command line** (`boot_router` in `tools/k8s-demo.sh`):

- Its qemu holds a hub (`-netdev hubport`) joined to one `-netdev stream` unix socket per
  node, so it is the segment's switch. Each node's qemu connects its single NIC to its
  socket (`server=off`) once the router is listening, so no `reconnect` option is needed,
  which older qemu spells differently. No multicast, no ports to pick, no root.
- Its second NIC is the user-mode one, with the only port forwards in the demo.
- systemd-networkd does the rest, from one `network.network.10-lan` credential:
  `Address=10.0.0.1/24`, `DHCPServer=yes` with a `[DHCPServerStaticLease]` per node MAC,
  `IPMasquerade=ipv4`, and `EmitDNS=` pointing at qemu's resolver, which the nodes reach
  through the masquerade.
- The API server forward is `systemd-socket-proxyd` in a socket unit handed in as
  `systemd.extra-unit.*` credentials. Both are already in the image.
- The nodes boot the image as it is. The image's own `20-wired.network` asks for DHCP,
  the static lease answers, and the address follows the MAC, like on a real network.
  The only per-node inputs left are the MAC, `systemd.hostname=` and the `/var` disk.
- The host reaches nodes with `ProxyJump` through the router, one forward in total.

Measured in the hand-built prototype that came first: a lease and a default route on every node, 40/40 node-to-node
TCP connections, 200 MB streamed between nodes, about 8 MB/s out to dl.k8s.io, and no
duplicated frames. The router is given 384 MB and uses about 240 of it.

Two cheaper versions were tried first and fail in ways worth recording:

- **Joining node 1's user-mode stack to the segment through a hub**, so slirp is the
  router, resets every connection between nodes: 0 of 40 got through. A hub floods, slirp
  sees every SYN between guests, opens the same connection on the host's network, and
  injects the reset it gets back. slirp cannot be on a segment it does not own.
- **The multicast socket backend** loops a sender's frames back to itself, and with a hub
  on the segment that showed up as duplicate replies.

Two things to know when building it. Unix socket paths are capped at 108 bytes, so the
sockets go at a relative `output/k8s/<node>.sock`, not under an absolute path. And
OpenSSH's `PerSourcePenalties` refuses a burst of connections that never authenticate,
which looks exactly like packet loss to a test that only reads banners.

**The pod network is flannel** (#190), in VXLAN mode with its nftables backend, from
its release manifest pinned by checksum in `tools/k8s-demo.sh` and changed in one line,
`"EnableNFTables": true`. The bridge plugin with static routes and an nft masquerade table
was chosen at first to keep a CNI out of the picture. But once paths are links, a stock
CNI DaemonSet is precisely what the test should exercise, and it does: flannel writes
`10-flannel.conflist` to `/etc/cni/net.d` and its plugin to `/opt/cni/bin`, both landing
on the `/var` disk through the extension's links, and its plugin delegates to the
extension's `bridge` and `host-local` through CRI-O's `plugin_dirs`. Its images are on
ghcr.io, so Docker Hub's rate limits do not come into it, and its `flannel-ipv4` and
`flannel-ipv6` nftables tables need nothing `k8s.config` does not already have *(demo)*.

## Getting an extension into a VM

`systemd-sysext` looks in `/etc/extensions`, `/run/extensions` and `/var/lib/extensions`,
and `systemd-confext` in `/run/confexts`, `/var/lib/confexts`, `/usr/local/lib/confexts`
and `/usr/lib/confexts` (`src/shared/discover-image.c` in 262; sysexts are deliberately
not searched under `/usr`, and `/etc/extensions` is for symlinks only, which here means
not at all).

**The pair goes in `/var/lib/extensions` and `/var/lib/confexts` on the `/var` disk**,
which a node needs anyway. An update is a new pair of files and a reboot, the same model
as the base. The ordering concern this section used to raise is settled by the unit
files: `systemd-sysext.service` and `systemd-confext.service` are `After=local-fs.target`,
and the `var.mount` that `systemd.mount-extra=` generates is part of `local-fs.target`. So
the disk is mounted before either merge looks at it. Both are `Before=sysinit.target`, so
the merge is finished before any ordinary unit starts. PID 1 bind-mounts
`/etc/machine-id` before the confext merge, and the merge does not hide that mount: it
carries the hierarchy's submounts over onto the merged overlay (`move_submounts` in
`sysext.c`).

`test/sysext.sh` puts files there **before the first boot**, rather than copying them in
and running `systemd-sysext refresh`, so that what it tests is the boot path a real node
takes. It builds the `/var` image with `mkfs.ext4 -d` from a seed tree holding
`lib/extensions/` and `lib/confexts/` (`qemu_seed_var_disk` in `test/qemu-lib.sh`), under
`podman unshare` so that every file is owned by root: made as an ordinary user, `/var/lib`
belonged to uid 1000, and systemd-tmpfiles refused to create anything below it, with
*unsafe path transition*. `x-systemd.makefs` only formats a blank device, so a disk that
already has a filesystem is used as it is, and `x-systemd.growfs` still grows it.

**A shared read-only disk** is the other way, and the closer match to how the base is
attached: one file, `readonly=on`, any number of guests. It needed no base feature for
the merge: `systemd.mount-extra=` mounts the disk at `/run/extensions/<name>` before
systemd-sysext looks, and sysext merges a directory there like an image (#192, `SYSEXTS=`
in `test/qemu-lib.sh`). It is what `tools/k8s-demo.sh` uses — one kubernetes image for
every node, where the `/var` way copied 86 MB onto each — and what the podman, rootless
and persistent-`/var` tests use for podman.

**And it is verified, by the same mechanism as the root** (#191). Every extension image
is sealed by `image/build-extension.sh` the way `rootfs.erofs` is: a dm-verity hash tree
appended to the file, and its table written beside it as `<name>.dm-verity`. A VMM that
attaches the image puts that table into the root's `dm-mod.create=`, so the kernel builds
`/dev/mapper/ext-<name>` before userspace starts and that is what gets mounted. A changed
byte is an I/O error, with no libcryptsetup and no initrd involved; `test/sysext.sh`
attaches a tampered image and expects device-mapper's corruption report, as
`test/verity.sh` does for the root. Two details made it work: dm-init runs before udev,
so a table names its disk by position (`/dev/vdc` after the root and the `/var` disk),
and nothing named the devices it makes — lvm2's udev rules would, via dmsetup, and
without a `DM_NAME` systemd's `99-systemd.rules` keeps a dm device not-ready forever — so
`image/files/etc/udev/rules.d/10-dm-init.rules` takes the name from sysfs.

What is not verified is the `/var` way: a file in `/var/lib/extensions` is loop-mounted
by systemd-sysext, and checking it is systemd's userspace verity, which is libcryptsetup
and lvm2's libdevmapper under it. That is the part of #191 left open, and it is a choice
about the image rather than a missing step: the attached way already covers the VMs this
image targets.

### Trust

An extension's verity root hash protects it against corruption, but not against
replacement. For an attached one the hash comes from the VMM, which already owns the
guest, so that is the boundary it should be; for a file in `/var/lib/extensions` it is
whoever can write there, which is root on the machine. Signed extensions
need `DM_VERITY_VERIFY_ROOTHASH_SIG` (off today) and a key in the kernel's keyring, and
systemd's image policy can then require a signature. That belongs with the signed-releases
item in `docs/container-host.md`, and should be designed together with it, not twice.

## Building it

The packages are ordinary packages — `packages/kubernetes`, `packages/cri-o`,
`packages/cri-tools` and `packages/cni-plugins` (#188) — built in the same builder with
the same matrix entry, pins and SBOM record. One line in each `env.sh` is the difference:
**`EXTENSION=kubernetes` makes root `build.sh` install the package into
`extensions/kubernetes/` instead of `rootfs/`.** It still compiles against `rootfs/`,
because the sysroot is a separate mount from the install target, but nothing
`image/build-rootfs.sh` copies ever contains it. That needed neither the per-package file
manifests `docs/image-variants.md` asks for nor a list of subtractions to maintain: the
files never reach the base's tree at all.

Each package installs its own scaffolding there too, as openssh does in the base: units,
`Upholds=` drop-ins, `tmpfiles.d`, and the `/etc` the confext carries. So
`extensions/kubernetes/` is laid out like the merged result, and `tools/build-image.sh`
turns it into the pair with `image/build-extension.sh staged kubernetes`: `usr/` and
`opt/` become the sysext, `etc/` the confext, ELF objects are stripped as in the base's
trim, and anything else is an error. The output is `output/extensions/kubernetes.raw` and
`output/confexts/kubernetes.raw`, next to the image, which is where `tools/k8s-demo.sh`
and `tools/fetch-image.sh` expect them too.

Software that isn't in this repository can produce an extension the same way
`examples/nginx` produces a container image. Compile in Debian stable against libraries
no newer than the base's, then add one stage that runs `mkfs.erofs` and `veritysetup`
over `/out` and writes the release file. That's the user-facing half of the same
mechanism, and worth an `examples/` entry now that the base supports sysext.

## Tests

- **`test/sysext.sh`** (#187): a toy sysext and confext pair, and a sysext built for
  `SYSEXT_LEVEL=0`, seeded on the `/var` disk before boot. It checks that both of the
  pair are merged and the third is not, that the sysext's `Upholds=` unit ran and read
  the confext's file, that `/etc/machine-id` is still PID 1's bind mount under the
  confext overlay, and that the boot is `running`. It needs no Kubernetes, and it keeps
  the mechanism working for everything after it.
- **`test/k8s.sh`** exists already, ahead of the extension: it runs `tools/k8s-demo.sh`
  — three nodes, a Service answered from more than one — in CI's `k8s`
  job, on KVM, per push, gating nothing. Once the extension exists it boots that, seeded on
  each node's `/var` disk, instead of copying binaries in; it loses the `/etc` overlay,
  and with the router VM and flannel it checks a node configured by nothing but its MAC,
  hostname and disk.
- **The base without the extension is unchanged**: `test/systemd.sh` still passes, and
  `test/rootfs-size.sh` shows the cost of enabling sysext and nothing more.

## Order of work

1. ~~**The demo's network**~~: done (#186), the router VM, one NIC per node, no
   `--node-ip`.
2. ~~**`-Dsysext=true`, `SYSEXT_LEVEL=1` and `CONFEXT_LEVEL=1`, `test/sysext.sh`**~~: done
   (#187). Plain EROFS only; verity on extensions needs libcryptsetup (#191).
3. ~~`k8s.config`~~ and ~~per-instance hostname~~: done.
4. ~~**The packages**~~: done (#188).
5. ~~**The extension pair**~~: done (#189), assembled by `image/build-extension.sh staged`
   and booted by the demo seeded on `/var`; `setup-node.sh`, the `/etc` overlay and the
   payload copy are gone. Flannel too (#190).
6. **Signing**, together with signed base releases.

## Open questions

- **One extension or two.** CRI-O on its own is useful without kubelet (a CRI for other
  orchestrators), but two extensions means two compatibility promises to keep in step.
- **Where the extension is published.** As an OCI artifact on ghcr next to `flfs`, the way
  `docs/container-host.md` proposes for signed releases, or as a CI artifact beside
  `rootfs.erofs`.
- **Whether the control plane is in scope**, or only `kubeadm join`. A single-node
  `kubeadm init` is the cheapest end-to-end test, which argues for it.
