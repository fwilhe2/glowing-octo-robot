# System extensions: a Kubernetes node without forking the image

**Status: nothing here is implemented.** systemd is built `-Dsysext=false`
(`packages/systemd/build.sh`), and no extension image exists. This is the design for
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

- **Put them in the image.** kubelet and CRI-O together are tens of MiB *(verify:
  measure)*. That cost would fall on every user of an image whose size budget is checked
  in CI (`test/size-budget.txt`), for an aim that `CLAUDE.md` calls *an* aim, not *the*
  aim.
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

```
kubernetes-<k8s version>-<arch>.raw          EROFS + verity hash tree, like rootfs.erofs
└── usr/
    ├── bin/kubelet, kubeadm, crio, pinns
    ├── libexec/cni/bridge, host-local, loopback, portmap
    ├── lib/systemd/system/kubelet.service, crio.service
    ├── lib/systemd/system/multi-user.target.wants/kubelet.service, crio.service
    ├── share/crio/…, share/kubernetes/…          default configuration (below)
    └── lib/extension-release.d/extension-release.kubernetes
```

- **CRI-O, not containerd.** It shares podman's image and storage libraries, its
  `policy.json` and `registries.conf`, conmon and crun, all of which the base already
  ships. That's why `CLAUDE.md` calls it the natural pairing. containerd would bring a
  second image store and its own shim.
- **kubelet and kubeadm build `CGO_ENABLED=0`** as upstream does, so they have no `NEEDED`
  entries and the glibc coupling doesn't come up. CRI-O uses cgo (seccomp, gpgme or the
  pure-Go signature tag podman already uses) and goes through the same sysroot flags as
  podman. Both are Go, and the builder already has Go and pins it offline.
- **CNI plugins.** CRI-O uses CNI, not netavark. The reference
  `containernetworking/plugins` cover a single node, and the cluster's own CNI DaemonSet
  replaces them on a real one.
- **Enablement ships as `.wants` symlinks in the extension's `/usr/lib`**, the way openssh
  and dbus do it in the base. Presets can't help, because they write to `/etc`.
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

## Where `/etc` has to be writable

This is the hard part, and the reason this is a design note rather than a weekend. The
Kubernetes stack assumes it can write to paths that are read-only here:

| path | written by |
| --- | --- |
| `/etc/kubernetes` | kubeadm: kubeconfigs, PKI, static pod manifests for the control plane |
| `/etc/cni/net.d` | the CNI DaemonSet (flannel, Calico) installs its network config here |
| `/opt/cni/bin` | the same DaemonSet's init container copies its plugin binaries here |
| `/usr/libexec/kubernetes` | kubelet and the controller manager, for FlexVolume plugins; created at start *(demo)* |
| `/var/lib/kubelet`, `/var/lib/containers`, `/var/lib/etcd` | fine, on the `/var` disk |

There are two options, and the first is the one to try:

1. **Mutable extensions.** `systemd-sysext` and `systemd-confext` have a `--mutable=` mode
   (systemd 256 and later; the base has 262) in which the merged overlay gets a writable
   upper directory under `/var/lib/extensions.mutable/` *(verify: semantics, and whether
   `/etc` and `/opt` both work)*. A confext carrying an empty `/etc/kubernetes` and
   `/etc/cni/net.d`, made mutable, gives kubeadm a writable `/etc/kubernetes` whose
   contents live on the `/var` disk. That is where node state belongs anyway: a node
   that reboots must come back as the same node.
2. **Bind mounts from `/var`.** Mount units in the extension bind
   `/var/lib/flfs-k8s/etc-kubernetes` over `/etc/kubernetes`, and so on. The mount points
   have to exist, which a confext can provide. This is more explicit and needs nothing
   new from systemd, but every writable path becomes a unit to maintain.

Either way, **a Kubernetes node requires the `/var` disk.** A tmpfs `/var` would lose the
node's PKI and identity at every reboot. That's a requirement the extension can check
(`ConditionPathIsMountPoint=/var` *and* not tmpfs) rather than discover.

`/opt/cni/bin` can be avoided rather than solved. CRI-O's `plugin_dirs` takes a list, and
both flannel and Calico let the install path be configured, so `/var/lib/cni/bin` on the
disk works without a writable `/opt`. *(verify: which CNIs make this awkward.)*

The demo answers `/etc` the bluntest way, an overlayfs over all of it with the upper
half on `/var`, which works and proves nothing about either option above; it is the one
part of the demo that should not survive into the extension.

`/usr/libexec/kubernetes` is configuration rather than a writable path, which is how
distributions with a read-only `/usr` answer it *(verify: Flatcar's docs)*: kubelet's
`volumePluginDir` and the controller manager's `--flex-volume-plugin-dir` both point under
`/var/lib/kubelet`, as the demo does. Without the second, the controller manager's static
pod has a `DirectoryOrCreate` hostPath on `/usr` and should never start *(verify)*.

More fixes belong in the extension's default configuration, not in the base:

- **kubelet `resolvConf: /run/systemd/resolve/resolv.conf`**, not `/etc/resolv.conf`. That
  is resolved's `127.0.0.53` stub, which can't be reached from a pod's network namespace.
  The symptom is pods with no DNS on a node that resolves fine.
- **`cgroupDriver: systemd`** on both kubelet and CRI-O.
- **kubelet `--node-ip`** whenever a VM has more than one NIC, and qemu's user-mode one
  is always 10.0.2.15: left to choose, every node reports the same InternalIP *(demo)*.
- **CRI-O's runtime is the base's** `/usr/bin/crun` with `/usr/libexec/podman/conmon`;
  the static bundle's own copies are not needed *(demo)*.

## Getting an extension into a VM

`systemd-sysext` merges what it finds in `/etc/extensions`, `/run/extensions`,
`/var/lib/extensions` and `/usr/lib/extensions` *(verify: the list in 262)*. In this image:

- **`/var/lib/extensions` on the `/var` disk** is the natural home, since a node needs that
  disk anyway. The VMM or an operator puts `kubernetes-1.xx.y-amd64.raw` there, and an
  update is a new file and a reboot, the same model as the base.
- **Boot ordering is the thing to verify first.** `/var` is a mount `systemd-sysext.service`
  has to come after, and kubelet's unit has to be loaded after the merge. systemd handles
  this for `/var/lib/extensions` *(verify: by ordering or by a re-exec after the merge)*,
  but this image's `/var` arrives through `systemd.mount-extra=`, which is exactly the
  kind of difference that turns into a unit that silently doesn't exist.
- **A read-only virtio disk** with the extension on it is the alternative for a disk-less
  VM, and the closer match to how the base is attached (`readonly=on`, one file shared by
  many guests). It needs a symlink from a known device into `/run/extensions` before the
  merge *(verify: whether sysext takes a block device directly)*.

### Trust

An extension's verity root hash protects it against corruption, but not against
replacement: whoever can write `/var/lib/extensions` can put any extension there. For a
first version that is the same trust boundary as root on the machine. Signed extensions
need `DM_VERITY_VERIFY_ROOTHASH_SIG` (off today) and a key in the kernel's keyring, and
systemd's image policy can then require a signature. That belongs with the signed-releases
item in `docs/container-host.md`, and should be designed together with it, not twice.

## Building it

The packages are ordinary packages: `packages/kubernetes`, `packages/cri-o` and
`packages/cni-plugins`, built in the same builder with the same matrix entry and SBOM
record, and staged into `rootfs/` like everything else. What differs is assembly. Their
files go into the extension instead of the base image.

That makes it a direct customer of the primitive `docs/image-variants.md` says is
missing: **per-package file manifests**. With them, an extension is a variant whose
"platform" is `sysext`. It is a selection from the staging tree like any other variant,
with the base's files subtracted and an `extension-release` added. Without them, the
first version can take the files by name, as the OCI subtractions do today, and accept
that the list has to be maintained.

Software that isn't in this repository can produce an extension the same way
`examples/nginx` produces a container image. Compile in Debian stable against libraries
no newer than the base's, then add one stage that runs `mkfs.erofs` and `veritysetup`
over `/out` and writes the release file. That's the user-facing half of the same
mechanism, and worth an `examples/` entry once the base supports sysext at all.

## Tests

- **`test/sysext.sh`**: boot with a trivial extension (one binary, one unit), and check
  that `systemd-sysext status` lists it, the unit ran, the boot is `running`, and an
  extension with a wrong `SYSEXT_LEVEL` is refused. It's cheap, needs no Kubernetes, and
  is the test that keeps the mechanism working for everything after it.
- **`test/k8s.sh`** exists already, ahead of the extension: it runs `tools/k8s-demo.sh`
  — three nodes, a Service answered from more than one — in CI's `k8s`
  job, on KVM, per push, gating nothing. Once the extension exists it should boot that
  instead of copying binaries in, and lose the demo's `/etc` overlay.
- **The base without the extension is unchanged**: `test/systemd.sh` still passes, and
  `test/rootfs-size.sh` shows the cost of enabling sysext and nothing more.

## Order of work

1. **`-Dsysext=true`, `SYSEXT_LEVEL=1`, `test/sysext.sh`** with a toy extension. This is
   independently useful (debugging tools such as `strace` and `tcpdump` as an extension,
   rather than in every image) and settles the boot-ordering question before anything
   depends on it.
2. **`k8s.config`**: the kernel symbols above. They cost little and are needed whatever
   the delivery mechanism.
3. **Per-instance hostname** via the kernel command line, and `qemu-lib.sh` passing it.
4. **The packages**: CRI-O (against the base's crun, conmon and containers config),
   kubelet and kubeadm, the CNI plugins.
5. **The extension and confext**, the writable-`/etc` answer, and `test/k8s.sh`.
6. **Signing**, together with signed base releases.

## Open questions

- **Mutable confext vs bind mounts** for `/etc/kubernetes`: settled by trying the first.
- **One extension or two.** CRI-O on its own is useful without kubelet (a CRI for other
  orchestrators), but two extensions means two compatibility promises to keep in step.
- **Where the extension is published.** As an OCI artifact on ghcr next to `flfs`, the way
  `docs/container-host.md` proposes for signed releases, or as a CI artifact beside
  `rootfs.erofs`.
- **Whether the control plane is in scope**, or only `kubeadm join`. A single-node
  `kubeadm init` is the cheapest end-to-end test, which argues for it.
