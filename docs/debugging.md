# Debugging a running machine

The base image has what it needs to run and nothing beyond that. When something is wrong,
the tools for finding out why come in the **`debug` system extension**: one more read-only
disk that systemd-sysext merges into `/usr` at boot. A machine that is working doesn't
carry them, and a broken one gets them without being rebuilt.

```sh
SYSEXTS=debug ./tools/boot-qemu.sh          # the image, plus the debug tools
SYSEXTS="podman debug" ./tools/boot-qemu.sh # with podman as well, to debug containers
./tools/ssh.sh --root                       # most of these need root
```

| tool | what it answers |
| --- | --- |
| [`strace`](#strace) | what one process asks the kernel for, and what the kernel answers |
| [`perf`](#perf) | where CPU time goes, and every system call across the whole machine |
| [`bpftool`](#bpftool) | which BPF programs are loaded and attached, and where |
| [`tcpdump`](#tcpdump) | which packets actually cross an interface |
| [`gdbserver`](#gdbserver) | a process stopped at a breakpoint, debugged from the host |
| [`socat`](#socat) | what a unix socket, TCP port or vsock says when you talk to it |
| [`jq`](#jq) | one field out of the JSON every other tool here prints |

`test/debug.sh` boots with the extension and checks that each tool works on something real
in the guest. It runs in CI next to the other boot tests.

## Before reaching for a tool: what the base already has

A lot of debugging needs no extension. These are in every image:

- **systemd's view.** `systemctl --failed`, `systemctl status <unit>`,
  `journalctl -b -u <unit>`, `journalctl -b -p warning`, `systemd-analyze blame` and
  `critical-chain` for a slow boot, `systemd-analyze security <unit>` for sandboxing,
  and `busctl` for D-Bus.
- **Processes and files.** `ps`, `top`, `free`, `vmstat` and `pgrep` come from procps.
  `lsfd` from util-linux replaces `lsof`, and understands namespaces, pidfds and eventfds.
  `/proc/<pid>/` holds `status`, `limits`, `cgroup`, `mountinfo`, `fd/`, `ns/` and `stack`.
- **Namespaces and containers.** `lsns` lists namespaces. `nsenter -t <pid> -a` gets you a
  shell in all of a process's namespaces. `crun list` and `crun state`, and with the
  podman extension `podman inspect` and `podman logs`.
- **Networking.** `ip -d addr`/`route`/`link`, `ss -tunap` for sockets and their owners,
  `bridge link`, `nft list ruleset` (`-a` for handles, and `counter` in a rule to see
  whether it matches), `networkctl status`, `resolvectl query`/`status` in place of `dig`,
  `ping` and `curl -v`.
- **The kernel.** `dmesg`, `/proc/pressure/{cpu,memory,io}` for PSI,
  `/sys/fs/cgroup/<path>/` for a unit's limits and usage, and the kernel's own config at
  `/usr/lib/modules/$(uname -r)/config`.

Reach for the extension when these show *that* something fails but not *why*.

## Getting the extension onto a machine

**Attached by the VMM**, which is what `SYSEXTS=debug` does in `test/qemu-lib.sh` and so
in `tools/boot-qemu.sh`. The extension is a read-only virtio disk, verified by dm-verity
the way the root is, and merged before `local-fs.target`. `SYSEXTS` is a space-separated
list, so to debug the engine as well, attach both: `SYSEXTS="podman debug"` or
`SYSEXTS="kubernetes debug"`, quoted so the shell passes them as one variable. Each is its
own disk, and systemd-sysext stacks them all over one `/usr`.

**Copied onto the `/var` disk** of a machine that has one, in which case no reboot is
needed:

```sh
scp output/extensions/debug.raw <guest>:/var/lib/extensions/   # or cat it over tools/ssh.sh
systemd-sysext refresh                                          # in the guest
systemd-sysext status                                           # debug is listed under /usr
systemd-sysext unmerge && rm /var/lib/extensions/debug.raw      # take it off again
```

A file in `/var/lib/extensions` is not verified the way an attached disk is (#191,
`docs/sysext.md`). Firecracker and Virtualization.framework boots (`tools/boot-firecracker.sh`,
`tools/boot-vz.sh`) can't attach extension disks yet, so this is the way in for them too.

`./tools/build-image.sh` builds it into `output/extensions/debug.raw` along with the
others, and `./tools/fetch-image.sh` downloads CI's.

## What the kernel provides

`CONFIG_MODULES` is off, so an extension can add programs but never kernel features. What
these tools attach to is therefore built into every kernel, debug extension or not. It is
listed in the `trace.config` fragment in `packages/kernel/build.sh`, and
`test/kernel-caps.sh` checks that it is there:

- **kprobes and uprobes.** `perf probe` on any kernel function, or on a function in a
  program or library.
- **Syscall tracepoints** (`FTRACE_SYSCALLS`). `syscalls:sys_enter_*` and `sys_exit_*`,
  which `perf trace` is built on.
- **BTF** (`/sys/kernel/btf/vmlinux`). The kernel's type information, which systemd's BPF
  LSM needs anyway and which `bpftool btf` reads.
- **tracefs**, at `/sys/kernel/tracing`, which systemd mounts on first use.

What is *not* there: the function tracer (`FUNCTION_TRACER`), so BPF fentry/fexit programs
and ftrace's `function` and `function_graph` tracers are unavailable. Also missing are
`/proc/kcore` and scheduler statistics (`SCHEDSTATS`). Each would cost every machine
something, and nothing in the extension needs them yet.

## strace

What one process asks the kernel for, and what the kernel answers. Start here when a
program fails with a bare errno, or with no message at all.

```sh
strace -f -e trace=%file -e status=failed some-command   # every file it failed to open, and why
strace -f -p "$(systemctl show -P MainPID foo.service)"   # attach to a running service
strace -c -f some-command                                 # a count and time per syscall
strace -f -e trace=%network -s 256 curl -s https://example.com
strace -e inject=openat:error=ENOSPC:when=3 some-command  # make the third openat fail
```

On this image the common finding is an `EROFS` (read-only file system) for a program
writing to `/etc` or `/usr`, or an `ENOENT` for something it expected under `/var`. `/var`
starts empty on every boot unless the VM has a disk for it.

To strace a service from its very first instruction, put the command in a drop-in in
`/run/systemd/system/foo.service.d/`, since `/etc` is read-only:

```ini
[Service]
ExecStart=
ExecStart=/usr/bin/strace -f -o /run/foo.strace /usr/bin/foo --its-usual-flags
```

For a container, find a process's host PID with `podman inspect -f '{{.State.Pid}}' <name>`
(or `crun state <id>`) and use `strace -p` from the host side. The container's seccomp
profile doesn't apply to a tracer outside it.

Built without `-k` (stack traces): the base doesn't ship the libdw it would need.

## perf

The kernel's own profiler and tracer. It does two different jobs here.

**System-wide syscall tracing, like strace but for every process at once.** It is cheaper
than strace, because nothing is stopped:

```sh
perf trace -a -e openat --failure          # every failed open, machine-wide, with PID and errno
perf trace -p <pid> --duration 10          # one process's syscalls that took over 10 ms
perf trace -s -a -- sleep 5                # a per-process syscall summary for five seconds
perf trace -e 'file,network' -- some-command  # groups of syscalls, by name
```

**Profiling and counting:**

```sh
perf stat -a -- sleep 5                    # context switches, migrations, page faults, cycles
perf top                                   # what is on CPU right now, by symbol
perf record -a -g -- sleep 10 && perf report --stdio
perf sched record -- sleep 5 && perf sched latency   # who waited for a CPU, and how long
```

**Probes**, on a kernel function or on a function in a program:

```sh
perf probe -a do_sys_openat2               # a kprobe, now an event like any other
perf record -e probe:do_sys_openat2 -a -- sleep 5
perf probe -x /usr/lib/libc.so.6 -a malloc # a uprobe
perf probe -d 'probe:*' -d 'probe_libc:*'  # remove them again
perf list tracepoint                       # every static tracepoint the kernel has
```

Limits worth knowing:

- **No DWARF.** perf is built without libdw, as the base doesn't ship it. So
  `perf record --call-graph dwarf` and `perf probe` on source lines or variables are
  unavailable. `-g` (frame pointers) works where the code keeps them, and the kernel's
  own stacks always work.
- **No script engines.** `perf script` prints events, but can't run Python or Perl
  scripts (constraint 5).
- **Few hardware counters in a VM.** Whether `cycles` and `instructions` count depends on
  the VMM exposing a virtual PMU. qemu with KVM does (`-cpu host`), TCG does not, and
  Firecracker hides it by default. Software events, tracepoints and probes work
  regardless. The tables of vendor-specific PMU events are not built in.

## bpftool

Which BPF programs are loaded, what they are attached to, and what their maps hold. Even
an idle machine here has some, because systemd's sandboxing is BPF: `IPAddressDeny=`,
`RestrictFileSystems=`, device policy. crun's device rules for every container are BPF
too.

```sh
bpftool prog show                          # every loaded program: type, name, when, by whom (uid)
bpftool cgroup tree                        # which program is attached to which cgroup, and how
bpftool net show                           # XDP and tc programs on interfaces
bpftool map show && bpftool map dump id <id>
bpftool prog dump xlated id <id>           # the verified instructions of one program
bpftool feature probe kernel               # what this kernel's BPF supports
bpftool btf dump file /sys/kernel/btf/vmlinux format c | less   # the kernel's types, as C
```

`bpftool cgroup tree` is the quickest way to see why a container can't open a device, or
why a unit with `IPAddressDeny=` can't reach the network. The program sits on the cgroup,
not in any configuration file.

This build leaves out JIT disassembly (`prog dump jited` needs LLVM or libbfd), and the BPF
skeletons behind `bpftool prog profile` and the PID column of `prog show`. Those compile
against the build host's kernel BTF, which would make the binary differ from machine to
machine (`test/reproducible.sh`).

## tcpdump

Which packets cross an interface. For containers, compare what happens at each hop.

```sh
tcpdump -ni any                            # everything, every interface
tcpdump -ni podman0 port 53                # DNS from containers, at the bridge
tcpdump -ni ens3 'tcp port 443 and host example.com'   # at the uplink, after NAT
tcpdump -ni any -w /run/cap.pcap && scp ... # capture now, open in Wireshark on the host
nsenter -t <pid> -n tcpdump -ni eth0       # inside a container's network namespace
```

The usual container question is *where does it stop?*. Start at the container's `eth0`,
then its veth peer on the host (`ip link` shows `vethXXXX@ifN`), then `podman0` (or
`cni0`/`flannel.1` on a Kubernetes node), then the uplink. A packet that reaches the bridge
but not the uplink is a forwarding or nftables problem: compare with `nft list ruleset`
and `sysctl net.ipv4.ip_forward`. A packet that leaves with the container's own address
was not masqueraded. Rootless containers have no veth: pasta translates their traffic
into ordinary sockets of the user's, so `ss -tnp` as that user shows it, and tcpdump on
the uplink shows it leaving with the host's address.

libpcap is linked in statically and supports Linux capture only. There is no USB,
Bluetooth or D-Bus capture, since a VM has none of those. tcpdump can't decrypt IPsec
here (`--without-crypto`).

## gdbserver

A process stopped at a breakpoint, inspected from a gdb running on the **host**. The host
has the debug symbols, the source and an editor, and the guest has none of them. Full gdb
in the guest would bring GMP, MPFR and possibly Python, at many times the size.

```sh
# in the guest
gdbserver --attach 127.0.0.1:2345 "$(pidof foo)"    # attach to a running process
gdbserver 127.0.0.1:2345 /usr/bin/foo --args       # or start one under it

# on the host: forward the port over ssh, and connect
ssh -F output/ssh/ssh_config -N -L 2345:127.0.0.1:2345 flfs &
gdb -ex 'set sysroot rootfs' -ex 'target remote :2345' rootfs/usr/bin/foo
```

`set sysroot` points gdb at a copy of the guest's libraries. The `rootfs/` staging tree of
the build that made the image is exactly that, and still has its symbol tables, since the
strip happens at image assembly.

Listen on `127.0.0.1` and forward over ssh, rather than on `0.0.0.0`. gdbserver has no
authentication, and anyone who can reach the port can run code as the process it is
attached to.

## socat

Talk to a socket directly and see what it says. Here that is mostly unix sockets:

```sh
socat - UNIX-CONNECT:/run/podman/podman.sock        # type an HTTP request by hand
socat -v UNIX-LISTEN:/run/proxy.sock,fork UNIX-CONNECT:/run/crio/crio.sock   # log a client's traffic
socat - VSOCK-LISTEN:1234                           # the guest end of a host↔guest vsock channel
socat - OPENSSL:example.com:443,verify=1            # a TLS port, without HTTP on top
socat TCP-LISTEN:8080,fork,reuseaddr TCP:10.88.0.5:80   # a quick forward into a container
```

The `-v` proxy is the useful one for debugging a client: point it at the proxy socket
instead of the real one, and every byte in both directions is printed. For plain HTTP over
a unix socket, `curl --unix-socket` in the base is enough.

## jq

Pulls fields out of JSON. Most tools on this image answer in JSON when asked, and
grep is the wrong tool for a nested document:

```sh
networkctl list --json=short | jq -r '.Interfaces[] | "\(.Name) \(.OperationalState)"'
ip -j addr | jq -r '.[] | .ifname as $i | .addr_info[] | "\($i) \(.local)/\(.prefixlen)"'
nft -j list ruleset | jq '.nftables[] | select(.rule) | .rule | {table, chain, handle}'
podman inspect foo | jq '.[0].NetworkSettings'
bpftool -j prog show | jq -r '.[] | "\(.id) \(.type) \(.name // "-")"'
busctl --json=short call org.freedesktop.systemd1 /org/freedesktop/systemd1 \
  org.freedesktop.DBus.Properties Get ss org.freedesktop.systemd1.Manager Version | jq -r .data[0].data
```

## What is deliberately not here

- **bpftrace.** The most useful tool missing from this list. It links LLVM and Clang at
  runtime, over 100 MiB, so it would be an extension of its own, and it wants
  `FUNCTION_TRACER` for fentry probes. It belongs in a later change, with a size figure.
- **BCC's tools** (`execsnoop`, `opensnoop`, …). They are Python, which ships nowhere in
  this image (constraint 5).
- **Full gdb.** See [gdbserver](#gdbserver).
- **lsof.** `lsfd` in the base does the same job, and knows more about modern file types.
- **dig.** `resolvectl query` asks the resolver the machine actually uses, which is
  usually the question. BIND's `dig` would drag in a DNS library for one command.
- **conntrack-tools.** Its three netfilter libraries would cost more than the occasional
  question it answers. `nft list ruleset` with counters covers most NAT debugging.
- **Core dumps.** systemd is built `-Dcoredump=false`, and no extension can supply a
  systemd component.

## How the extension is built

Each tool is a package whose `env.sh` says `EXTENSION=debug`: `strace`, `tcpdump`,
`gdbserver`, `socat`, `jq` and `linux-tools` (perf and bpftool). They compile against the
base like every other package, install into `extensions/debug/`, and
`tools/build-image.sh` makes that into `output/extensions/debug.raw`. Two things are
particular to this extension:

- **An extension's packages can't link against each other.** Each compiles against the
  base's staging tree, never against another extension package. So a library that only
  one tool uses is that tool's second pinned tarball (`VENDOR_TARBALL`), linked
  statically: libpcap for tcpdump, libtraceevent for perf. Everything else they link
  (OpenSSL, zlib, libelf, libcap, ncurses) comes from the base.
- **`linux-tools` follows the kernel.** perf and bpftool are released with the kernel,
  so the package sources `packages/kernel/env.sh` for its version, tarball and checksum,
  and says `FOLLOWS=kernel`. `tools/check-updates.sh` and `tools/bump-version.sh` then
  leave it alone, and bumping the kernel moves both.
