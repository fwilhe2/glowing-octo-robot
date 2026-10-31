# Debugging a running machine

The base includes systemd, process, networking, and container inspection tools. The
`debug` system extension adds tracing, profiling, packet capture, and JSON tools without
changing the base image.

Attach it when booting QEMU:

```sh
SYSEXTS=debug ./tools/boot-qemu.sh
SYSEXTS="podman debug" ./tools/boot-qemu.sh
./tools/ssh.sh --root
```

`tools/vm.sh start <name> --ext debug` attaches it to a persistent QEMU machine. Attached
extension images are dm-verity verified. The extension can also be stored under
`/var/lib/extensions`, but that loading path is not verified.

QEMU can pass extra systemd credentials through fw_cfg without placing them on the kernel
command line:

```sh
QEMU_FWCFG_CREDENTIALS="example=value" ./tools/boot-qemu.sh
```

The guest reads the credential at `/run/credentials/@system/example`. This variable applies
to QEMU boots; Firecracker and vfkit do not provide fw_cfg.

## Start with the base tools

```sh
systemctl --failed
journalctl -b -u <unit>
systemd-analyze critical-chain
ps -ef
lsfd
ip -details address
ss -tunap
nft list ruleset
networkctl status
resolvectl query example.com
crun list
podman inspect <container>  # with the podman extension
```

`/proc/<pid>/` exposes process status, limits, cgroups, mounts, file descriptors, and
namespaces. `nsenter -t <pid> -a` enters a process's namespaces.

## Tools in the debug extension

### strace

Trace system calls for one process, including failed file accesses:

```sh
strace -f -e trace=%file -e status=failed <command>
strace -f -p "$(systemctl show -P MainPID <unit>)"
strace -c -f <command>
```

Use a temporary systemd drop-in under `/run/systemd/system/<unit>.service.d/` to trace a
service from startup. The image has a read-only `/etc` and `/usr`; `/var` is temporary
unless a disk is attached.

### perf

`perf trace` traces system calls; `perf record`, `stat`, and `top` profile CPU and events.
Probes are available for kernel functions and user-space functions:

```sh
perf trace -a -e openat --failure
perf stat -a -- sleep 5
perf record -a -g -- sleep 10 && perf report --stdio
perf probe -a <kernel-function>
```

DWARF call graphs and source-level probes are unavailable because the image does not ship
libdw. `perf script` prints events but has no Python or Perl scripting engine. Hardware
counter availability depends on the VMM's virtual PMU.

### bpftool

Inspect loaded BPF programs, attachments, maps, features, and kernel BTF:

```sh
bpftool prog show
bpftool cgroup tree
bpftool net show
bpftool map show
bpftool feature probe kernel
bpftool btf dump file /sys/kernel/btf/vmlinux format c
```

### tcpdump

Capture on an interface or across all interfaces. For container networking, follow traffic
from the container interface to its host bridge and uplink:

```sh
tcpdump -ni any
tcpdump -ni podman0 port 53
tcpdump -ni <uplink> 'tcp port 443'
nsenter -t <pid> -n tcpdump -ni eth0
```

The extension's libpcap is statically linked and supports Linux capture. tcpdump is built
without IPsec decryption support.

### gdbserver

Run gdbserver in the guest and connect from a host with the matching executable, symbols,
and source. Forward the guest port over SSH; gdbserver has no authentication.

```sh
# Guest
gdbserver 127.0.0.1:2345 --attach "$(pidof <program>)"

# Host
ssh -F output/ssh/config -N -L 2345:127.0.0.1:2345 flfs
gdb -ex 'set sysroot rootfs' -ex 'target remote :2345' rootfs/usr/bin/<program>
```

### socat and jq

Use socat to inspect or forward socket traffic; use jq to query JSON output:

```sh
socat - UNIX-CONNECT:/run/podman/podman.sock
socat -v UNIX-LISTEN:/run/proxy.sock,fork UNIX-CONNECT:/run/crio/crio.sock
ip -j addr | jq '.[] | {ifname, addr_info}'
nft -j list ruleset | jq '.nftables[] | select(.rule)'
```

## Kernel requirements and limits

Kernel tracing support is built in because `CONFIG_MODULES` is disabled. The kernel
includes kprobes, uprobes, syscall tracepoints, BTF, and tracefs. Function tracing,
`/proc/kcore`, and scheduler statistics are not enabled.

The extension does not include bpftrace, BCC tools, full gdb, or scripting runtimes. The
base's `lsfd` and `resolvectl` cover common `lsof` and `dig` use cases.

`test/debug.sh` checks the extension in a booted guest. Its packages install into
`extensions/debug/`; `tools/build-image.sh` assembles the verified image.

For an interactive QEMU boot, `Ctrl-a x` exits. `tools/vm.sh console <name>` attaches to a
background VM's console (`Ctrl-]` detaches); its log is
`output/vms/<name>/console.log`.
