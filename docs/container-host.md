# A container host for the Mac: what it would take

Proposal, not description. The idea is to use this image as the Linux VM behind `podman`
(and the `docker` CLI) on a Mac, filling the role of podman machine (Fedora CoreOS) or
Docker Desktop (LinuxKit). It would compete on four things: secure (verity root,
immutable, no shipped passwords), simple (one VM, one disk, one script), small, and fast
to boot.

Unverified claims are marked *(verify)*.

## What already fits

- Read-only, verity-checked root, with updates done by swapping the image file.
- `/var` on a disk the VMM supplies, so container storage survives restarts.
- podman, crun, netavark/aardvark, Quadlet, rootless podman for `user`, and pasta.
- An SSH key handed in as a systemd credential. Nothing is setuid. Builds are reproducible.

## What a Mac host needs that is missing

### VMM: vfkit first, qemu second

On Apple Silicon the guest is arm64. vfkit (Virtualization.framework) is what podman
machine uses today. It provides virtio-fs, vsock, a balloon and a rosetta share natively.
qemu on macOS has no virtiofsd, so host sharing there would be 9p, which is slow. The
plan is vfkit as the Mac path and qemu as the Linux/CI path, with both launched by the
same host tool (below).

For vfkit, boot directly with VZLinuxBootLoader: kernel, empty initrd and a kernel
command line. arm64 needs an uncompressed `Image` here, not `Image.gz` *(verify)*. The
`rootfs.cmdline` approach carries over unchanged.

### Kernel features to add to `container.config` (or a new `host.config`)

| symbol | why |
| --- | --- |
| `VIRTIO_FS`, `FUSE_FS` | bind-mounting the Mac's `$HOME` into containers is the #1 feature of these products |
| `VSOCKETS`, `VIRTIO_VSOCKETS` | SSH and the podman socket over vsock, with no guest network exposure |
| `VIRTIO_BALLOON`, `PAGE_REPORTING` | free-page reporting gives memory back to macOS; without it the VM sits at peak RSS forever |
| `HW_RANDOM_VIRTIO` | entropy at boot (the SSH host keys are generated at every boot) |
| `VIRTIO_CONSOLE` | hvc0 console under vfkit |
| `BINFMT_MISC` | Rosetta (amd64 containers on arm64), and qemu-user if wanted |

All of these are in the kernel now — `guest.config` and `container.config` in
`packages/kernel/build.sh` — and `test/kernel-caps.sh` holds it to them. `test/vmm.sh`
boots the image with Virtualization.framework's devices on qemu: an hvc0 console with no
UART, a virtiofs mount, and ssh over vsock.

### Host integration (the real work)

1. **The podman socket on the host.** Enable `podman.socket` (root and `user`) by preset
   for this flavour only, then forward it:
   - simplest: `podman system connection add flfs ssh://user@127.0.0.1:PORT/run/user/1000/podman/podman.sock`,
     with podman remote doing the SSH itself;
   - Docker CLI: `ssh -nNT -L ~/.flfs/docker.sock:/run/podman/podman.sock`, then
     `DOCKER_HOST=unix://…`. Docker's `ssh://` transport needs a `docker` binary in the
     guest, so it is not an option here.
   - later: vsock. systemd ≥256's `systemd-ssh-generator` binds sshd to `AF_VSOCK`, and
     vfkit maps vsock ports to unix sockets on the host, which removes the TCP port and
     the forwarding entirely.
2. **Published ports reaching `localhost` on the Mac.** qemu `hostfwd` is static. The
   proper answer is gvproxy (gvisor-tap-vsock, as podman machine uses), which forwards
   ports dynamically as containers publish them. It is a host-side Go binary and adds
   nothing to the image.
3. **Clock after host sleep.** VMs on macOS wake with a stale clock, and timesyncd only
   corrects it slowly. Options: a step on resume triggered by the host over ssh/vsock
   (`date -s`), or chrony with `makestep`. podman machine has hit this repeatedly, so
   decide deliberately *(verify the current vfkit answer)*.
4. **File sharing.** virtiofs mount of `/Users` at the same path in the guest (that is
   what makes `-v $PWD:/src` work unchanged). Do it with a mount unit or a
   `systemd.mount-extra=` passed by the host tool, so the image stays generic.
5. **Rosetta (optional).** Mount the rosetta virtiofs share and register binfmt with a
   `binfmt.d` entry given as a credential or a `mount-extra`.

## Credentials: what is left

The fixed `root`/`root` and `user`/`user` passwords are gone. Both accounts are `*` in
`image/files/etc/shadow` and the build fails on any hash. sshd is keys only
(`PasswordAuthentication no`, `KbdInteractiveAuthentication no`, `PermitRootLogin
prohibit-password`), with the root key handed in per machine as the
`ssh.authorized_keys.root` credential. The serial console logs in with no password
through the `login.noauth` credential the qemu harness passes. What a Mac host still
needs on top of that:

- **A key for `user`.** A `ssh.authorized_keys.user` credential, read through a
  `Match User user` block the way root's is. The default login for a container host
  should be `user` (rootless), with root reachable but not the default.
- **Probably not a console password.** systemd's `passwd.hashed-password.<user>`
  credentials looked like the way to set one per machine. But sysusers and firstboot only
  read them when they create an account, and here both accounts exist before the image is
  sealed. `login.noauth` already covers debugging, since whoever writes the kernel command
  line owns the VM anyway.
- **The host's uid for `user`** (501 on macOS), set with `--uid` at machine creation, so
  file ownership through virtiofs looks right. The account would be defined by a
  `userdb` credential rather than `/etc/passwd`. Phase 2.

## Hardening

- Kernel: `SECURITY_LOCKDOWN_LSM` (integrity), `SECURITY_LANDLOCK`, `SECURITY_YAMA`,
  `INIT_ON_ALLOC_DEFAULT_ON`, `RANDOMIZE_KSTACK_OFFSET_DEFAULT`, `STRICT_DEVMEM`/no
  `/dev/mem`, `KEXEC` off, `BPF_UNPRIV_DEFAULT_OFF`, `HARDENED_USERCOPY`,
  `SLAB_FREELIST_*`. Each needs a boot check because some break things (lockdown vs BPF
  LSM: confirm `integrity` mode still allows systemd's programs).
- sysctls: `kernel.kptr_restrict=2`, `kernel.dmesg_restrict=1`,
  `kernel.unprivileged_bpf_disabled=1`, `fs.protected_*`. Keep
  `user.max_user_namespaces` on, since rootless needs it.
- nftables base ruleset: inbound drop except established and sshd. netavark adds its own
  table.
- Unit hardening audit: sshd, podman.service and gvproxy-facing units get
  `ProtectSystem=strict` etc. where they lack them.
- Measured/secure boot: a signed UKI (systemd-stub + `ukify`, a builder-only python
  tool, which is allowed) binds kernel, cmdline and root hash together. It only matters
  once boot is EFI. With direct kernel boot the host supplies the cmdline, and the host
  is trusted in this model anyway. This is phase 3.

## Slimming

General rule: make every removal a build-time `-D…=disabled`/config change, not a trim,
and let `test/size-budget.txt` record the win.

### What to drop for this flavour

- `flfsfetch`.
- `iptables`, if Docker's own engine is not a goal. netavark speaks `nft`. It stays if
  "runs dockerd" remains an aim (#173). Decide this one explicitly.
- `nscd` and its `libselinux` allowlist entry (glibc `--disable-nscd`).
- `kmod`: modules are off. Build systemd `-Dkmod=disabled` and drop the package from the
  disk flavour as well.
- `agetty` on a serial line, if vfkit uses hvc0. Keep one getty on the right console.
- tzdata: keep `UTC` and `posixrules` only. Containers bring their own zoneinfo.
  `test/prebuilt.sh` would then need its zoneinfo check adjusted.
- `curl`/`ping`/`ip` stay. They are the debugging budget (constraint 4).

### systemd components to audit (`packages/systemd/build.sh`)

Probably off for a container host: `machined`/`nss-mymachines`, `portabled`, `importd`,
`homed`, `coredump` (or keep with a small cap), `hibernate`, `vconsole`, `localed`,
`timedated`, `firstboot` (if credentials cover it), `journal-remote`, `pstore`, `quotacheck`,
`randomseed`?, `backlight`/`rfkill`, `hwdb` (the largest single udev artefact at several
MiB; a VM needs almost none of it), `ldconfig`, `tpm2` bits, `libcryptsetup` unless
verity is ever set up from userspace.

Keep: networkd, resolved, timesyncd, logind and PAM (rootless needs
`XDG_RUNTIME_DIR` and linger), userdb (credentials), sysext (a clean way to add tooling
to an immutable host), oomd (useful under container memory pressure), journald, tmpfiles,
sysusers, growfs/makefs.

Before cutting, measure each component's bytes in the staged tree, then cut the big ones
first.

### Kernel

The kernel is defconfig minus `vm.config` today, with what it is *for* written down as
fragments of its own (`container.config`, `k8s.config`, `guest.config`). A second pass of
subtractions took arm64 from 1826 built-in symbols to 1280 (amd64: 1257), most of it board
support outside the `ARCH_*` gates; CLAUDE.md has why `VT` stays and why the base stays
defconfig rather than `tinyconfig`. What follows is the original proposal:

1. Short term: keep subtracting. Candidates are `VT`/`FRAMEBUFFER_CONSOLE`/`INPUT`
   (only with a serial or hvc console), `ACPI` on arm64 if the VMM gives a device tree
   *(verify vfkit: it may need ACPI)*, `NUMA`, `HOTPLUG_PCI`, `KALLSYMS_ALL`,
   `PROFILING`, `PERF_EVENTS`?, and unused filesystems (keep ext4, erofs, overlay, tmpfs,
   virtiofs, fuse, proc/sys/cgroup2), plus SCTP, DCCP, RDS, TIPC, and the 802.x protocols.
2. Medium term, as an experiment: build up from `tinyconfig` with
   `kvm_guest.config` + `container.config` + `host.config`. Five boot tests are the
   regression net. Expect a much smaller kernel and a few days of chasing "it boots but
   X silently fails" bugs. The `kernel-caps.sh` + fragment check is what makes this
   tractable.
3. Re-weigh `DEBUG_INFO_BTF`. It is the most expensive option and only buys systemd's
   BPF LSM features. That is worth keeping on a security-positioned image, but it should
   be a decision, not an accident.

## A better launcher: `tools/flfs` → eventually its own small host tool

`tools/boot-qemu.sh` is a debug harness, not something an end user runs. What podman
machine's UX actually needs is a host-side script (bash is fine; constraint 5 is about
the image) built on `qemu-lib.sh` so CI and users boot the same guest:

```
flfs init   [--cpus N --memory M --disk 50G]   # ~/.flfs/: var disk (sparse), machine-id, ssh key, config
flfs start                                     # backgrounded; pidfile, console → log file
flfs stop                                      # clean poweroff (QMP system_powerdown / ssh poweroff), then kill
flfs ssh [cmd]                                 # as user; --root for root
flfs status | logs                             # running?, serial log tail
flfs upgrade <image-dir>                       # swap rootfs.erofs + kernel + cmdline atomically; /var disk kept
flfs connect                                   # register podman connection (rootless + rootful) and docker socket forward
```

Implementation notes:

- Backend selection: `vfkit` on macOS, `qemu -accel hvf` as the macOS fallback,
  `qemu -accel kvm` on Linux. One function per backend translates the same machine
  description into flags.
- Stable state in `~/.flfs/<name>/`: the per-machine SSH key and machine ID belong to the
  `/var` disk, as `VAR_DISK` already does. Today's per-boot key in `output/ssh` stays
  for the tests.
- A QMP socket for a clean shutdown, so ext4 on `/var` is never yanked.
- Networking: gvproxy when present (dynamic port forwards, the same model as podman
  machine), otherwise qemu user-net with `hostfwd` for SSH only.
- Checksums and signature of a downloaded release (cosign or minisign on the host side),
  since "secure" includes the update path.

## Distribution

- Release artifacts per arch: `Image`/`bzImage`, `rootfs.erofs`, `rootfs.cmdline`,
  SBOM, and a signature over all four. `publish-oci` already shows how to gate on
  `main`. Pushing them to ghcr as an OCI artifact (not an image) reuses the same
  registry.
- Not podman machine compatibility. Its providers expect Ignition and a `core` user,
  which would mean pulling Ignition and its semantics in. Owning the launcher is less
  work and keeps the image generic. Revisit only if users ask for
  `podman machine init --image`.

## Order of work

1. **Credentials**: the shipped passwords are gone and sshd is key only. What remains
   is a key credential for `user` and, later, the host's uid (see above).
2. **Kernel host features** (virtiofs, vsock, balloon, rng, hvc), plus the
   `kernel-caps.sh` list.
3. **`tools/flfs`** with the qemu backend, `init/start/stop/ssh/connect`, tested on Linux
   in CI by reusing `test/podman.sh` through the forwarded socket.
4. **vfkit backend** and virtiofs `/Users`, tested by hand on a Mac (CI has no Apple
   virtualization *(verify macOS runners' nested virt)*).
5. **gvproxy port forwarding** and the clock-after-sleep fix.
6. **Slimming passes**: systemd components, drop list, kernel subtractions, each with
   the size delta in its commit message.
7. **Hardening** options, one at a time behind boot tests, then the tinyconfig
   experiment.
8. **Signed releases** and `flfs upgrade`, and UKI/EFI only if a reason appears.
