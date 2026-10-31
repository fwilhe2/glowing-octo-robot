#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

state_dir="${VM_STATE_DIR:-output/vms}"
default_size="${VAR_SIZE:-4G}"

usage() {
    cat <<'EOF'
Usage:
    ./boot.sh [--vm NAME] [--vmm auto|qemu|firecracker|vz] [--image DIR]
    ./boot.sh   [--size SIZE] [--extension NAME ...] [--update] [--no-ssh]
  ./boot.sh list
  ./boot.sh create NAME [SIZE]
  ./boot.sh snapshot NAME [SNAPSHOT]
  ./boot.sh restore NAME SNAPSHOT
    ./boot.sh delete NAME

Use --extension NAME more than once, or --extensions "NAME NAME", to attach system
extensions. Extension disks are currently supported through QEMU. A complete local
build is preferred by default; --update downloads the latest successful GitHub CI image.

Boot defaults to VM "default". State lives in output/vms/<name>/ and is kept
separate from rootfs/kernel images, so rebuilding or fetching a newer image does
not replace the VM's /var disk or machine ID. Snapshots are offline copies.
EOF
}

fail() {
    echo "error: $*" >&2
    exit 1
}

valid_name() {
    [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && "$1" != . && "$1" != .. ]]
}

vm_dir() {
    valid_name "$1" || fail "invalid name '$1' (use letters, digits, dot, underscore or hyphen)"
    printf '%s/%s\n' "$state_dir" "$1"
}

make_machine_id() {
    local path="$1"
    if [ ! -s "$path" ]; then
        od -An -tx1 -N16 /dev/urandom | tr -d ' \n' > "$path"
    fi
}

copy_disk() {
    local source="$1" destination="$2"
    if [ "$(uname -s)" = Darwin ]; then
        cp -c "$source" "$destination" 2>/dev/null || {
            rm -f "$destination"
            cp -p "$source" "$destination"
        }
    else
        cp --reflink=auto --sparse=always --preserve=mode,timestamps "$source" "$destination"
    fi
}

hash_file() {
    if command -v sha256sum >/dev/null; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

hash_stdin() {
    if command -v sha256sum >/dev/null; then
        sha256sum | awk '{print $1}'
    else
        shasum -a 256 | awk '{print $1}'
    fi
}

extension_hash() {
    local directory="$1" names="$2" name class file
    for name in $names; do
        for class in extensions confexts; do
            file="$class/$name.raw"
            [ -f "$directory/$file" ] || continue
            printf '%s ' "$file"
            hash_file "$directory/$file"
            printf '%s ' "${file%.raw}.dm-verity"
            hash_file "$directory/${file%.raw}.dm-verity"
        done
    done | hash_stdin
}

bundle_hash() {
    printf '%s\n' "$(hash_file "$1")" "$(hash_file "$2")" "$(hash_file "$3")" \
        "$(extension_hash "$4" "$5")" | hash_stdin
}

validate_extensions() {
    local directory="$1" names="$2" name file
    for name in $names; do
        valid_name "$name" || fail "invalid extension name '$name'"
        file="$directory/extensions/$name.raw"
        [ -f "$file" ] || fail "missing extension image: $file"
        [ -f "${file%.raw}.dm-verity" ] || fail "missing verity table: ${file%.raw}.dm-verity"
        file="$directory/confexts/$name.raw"
        if [ -f "$file" ] && [ ! -f "${file%.raw}.dm-verity" ]; then
            fail "missing verity table: ${file%.raw}.dm-verity"
        fi
    done
}

stage_images() {
    local source_rootfs="$1" source_cmdline="$2" source_kernel="$3"
    local source_extensions="$4" extension_names="$5"
    local identifier destination temporary before after copied name class file
    [ -f "$source_rootfs" ] || fail "missing rootfs image: $source_rootfs"
    [ -f "$source_cmdline" ] || fail "missing rootfs command line: $source_cmdline"
    [ -f "$source_kernel" ] || fail "missing kernel image: $source_kernel"
    validate_extensions "$source_extensions" "$extension_names"
    identifier=$(bundle_hash "$source_rootfs" "$source_cmdline" "$source_kernel" "$source_extensions" "$extension_names")
    destination="$directory/images/$identifier"
    if [ ! -d "$destination" ]; then
        mkdir -p "$directory/images"
        temporary="$directory/images/.${identifier}.tmp.$$"
        mkdir "$temporary"
        before="$identifier"
        cp -p "$source_rootfs" "$temporary/rootfs.erofs"
        cp -p "$source_cmdline" "$temporary/rootfs.cmdline"
        cp -p "$source_kernel" "$temporary/bzImage"
        for name in $extension_names; do
            for class in extensions confexts; do
                file="$source_extensions/$class/$name.raw"
                [ -f "$file" ] || continue
                mkdir -p "$temporary/$class"
                cp -p "$file" "$temporary/$class/$name.raw"
                cp -p "${file%.raw}.dm-verity" "$temporary/$class/$name.dm-verity"
            done
        done
        after=$(bundle_hash "$source_rootfs" "$source_cmdline" "$source_kernel" "$source_extensions" "$extension_names")
        copied=$(bundle_hash "$temporary/rootfs.erofs" "$temporary/rootfs.cmdline" "$temporary/bzImage" "$temporary" "$extension_names")
        if [ "$before" != "$after" ] || [ "$before" != "$copied" ]; then
            rm -rf "$temporary"
            fail "boot artifacts changed while being staged; retry after the rebuild finishes"
        fi
        mv "$temporary" "$destination"
    fi
    local old
    for old in "$directory/images"/*; do
        [ -d "$old" ] || continue
        [ "$old" = "$destination" ] || rm -rf "$old"
    done
    ROOTFS="$destination/rootfs.erofs"
    ROOT_CMDLINE="$destination/rootfs.cmdline"
    KERNEL="$destination/bzImage"
    OUT="$destination"
    EXTENSIONS="$destination"
    export ROOTFS ROOT_CMDLINE KERNEL OUT EXTENSIONS
}

assert_stopped() {
    local directory="$1/lock" pid=""
    [ -d "$directory" ] || return 0
    if [ -f "$directory/pid" ]; then
        pid=$(<"$directory/pid")
        if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
            fail "VM '$2' is running (PID $pid); stop it before changing its /var disk"
        fi
        rm -rf "$directory"
    else
        fail "VM '$2' is starting; retry shortly"
    fi
}

create_vm() {
    local name="$1" size="$2" directory disk
    directory=$(vm_dir "$name")
    disk="$directory/var.img"
    [ ! -e "$directory" ] || fail "VM '$name' already exists"
    [[ "$size" =~ ^[0-9]+[KkMmGgTtPp]?$ ]] || fail "invalid disk size '$size' (examples: 4G, 512M)"
    mkdir -p "$directory"
    if command -v truncate >/dev/null; then
        truncate -s "$size" "$disk"
    elif command -v mkfile >/dev/null; then
        mkfile -n "$(printf '%s' "$size" | tr '[:upper:]' '[:lower:]')" "$disk"
    else
        rm -rf "$directory"
        fail "need truncate or mkfile to create a sparse /var disk"
    fi
    make_machine_id "$disk.machine-id"
    echo "created VM '$name' ($size /var disk)"
}

snapshot_vm() {
    local name="$1" snapshot="$2" directory snapshots temporary
    directory=$(vm_dir "$name")
    assert_stopped "$directory" "$name"
    [ -s "$directory/var.img" ] || fail "VM '$name' has no /var disk; create it first"
    valid_name "$snapshot" || fail "invalid snapshot name '$snapshot'"
    snapshots="$directory/snapshots"
    mkdir -p "$snapshots"
    [ ! -e "$snapshots/$snapshot" ] || fail "snapshot '$snapshot' already exists"
    temporary="$snapshots/.${snapshot}.tmp.$$"
    mkdir "$temporary"
    if ! copy_disk "$directory/var.img" "$temporary/var.img"; then
        rm -rf "$temporary"
        fail "could not copy /var disk"
    fi
    cp "$directory/var.img.machine-id" "$temporary/machine-id"
    mv "$temporary" "$snapshots/$snapshot"
    echo "created snapshot '$snapshot' for VM '$name'"
}

restore_vm() {
    local name="$1" snapshot="$2" directory source temporary
    directory=$(vm_dir "$name")
    assert_stopped "$directory" "$name"
    valid_name "$snapshot" || fail "invalid snapshot name '$snapshot'"
    source="$directory/snapshots/$snapshot"
    [ -s "$source/var.img" ] || fail "snapshot '$snapshot' does not exist for VM '$name'"
    temporary="$directory/.var.img.restore.$$"
    copy_disk "$source/var.img" "$temporary" || fail "could not restore /var disk"
    mv -f "$temporary" "$directory/var.img"
    cp "$source/machine-id" "$directory/var.img.machine-id"
    echo "restored snapshot '$snapshot' for VM '$name'"
}

list_vms() {
    local directory name snapshots
    printf '%-20s %-12s %s\n' VM /var SNAPSHOTS
    for directory in "$state_dir"/*/; do
        [ -d "$directory" ] || continue
        name=$(basename "$directory")
        [ -f "$directory/var.img" ] || continue
        if [ -d "$directory/snapshots" ]; then
            snapshots=$(find "$directory/snapshots" -mindepth 1 -maxdepth 1 -type d -print | wc -l | tr -d ' ')
        else
            snapshots=0
        fi
        printf '%-20s %-12s %s\n' "$name" "$(ls -lh "$directory/var.img" | awk '{print $5}')" "${snapshots:-0}"
    done
}

command_name="${1:-boot}"
case "$command_name" in
    list) [ "$#" -eq 1 ] || fail "usage: ./boot.sh list"; list_vms; exit 0 ;;
    create)
        [ "$#" -ge 2 ] && [ "$#" -le 3 ] || fail "usage: ./boot.sh create NAME [SIZE]"
        create_vm "$2" "${3:-$default_size}"; exit 0 ;;
    snapshot)
        [ "$#" -ge 2 ] && [ "$#" -le 3 ] || fail "usage: ./boot.sh snapshot NAME [SNAPSHOT]"
        snapshot_vm "$2" "${3:-$(date -u +%Y%m%dT%H%M%SZ)}"; exit 0 ;;
    restore)
        [ "$#" -eq 3 ] || fail "usage: ./boot.sh restore NAME SNAPSHOT"
        restore_vm "$2" "$3"; exit 0 ;;
    delete)
        [ "$#" -eq 2 ] || fail "usage: ./boot.sh delete NAME"
        directory=$(vm_dir "$2")
        [ -d "$directory" ] || fail "VM '$2' does not exist"
        assert_stopped "$directory" "$2"
        rm -rf "$directory"
        echo "deleted VM '$2' and its snapshots"
        exit 0 ;;
    help|-h|--help) usage; exit 0 ;;
    boot) [ "$#" -eq 0 ] || shift ;;
    *) ;;
esac

vm=default
vmm=auto
image_dir="${OUT:-}"
size="$default_size"
ssh=1
local_image=0
extensions="${SYSEXTS:-}"
update=0
explicit_image=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --vm) [ "$#" -ge 2 ] || fail "--vm needs a name"; vm="$2"; shift 2 ;;
        --vmm) [ "$#" -ge 2 ] || fail "--vmm needs a value"; vmm="$2"; shift 2 ;;
        --image) [ "$#" -ge 2 ] || fail "--image needs a directory"; image_dir="$2"; explicit_image=1; shift 2 ;;
        --size) [ "$#" -ge 2 ] || fail "--size needs a value"; size="$2"; shift 2 ;;
        --extension) [ "$#" -ge 2 ] || fail "--extension needs a name"; extensions="${extensions:+$extensions }$2"; shift 2 ;;
        --extensions) [ "$#" -ge 2 ] || fail "--extensions needs a space-separated list"; extensions="${extensions:+$extensions }$2"; shift 2 ;;
        --update) update=1; shift ;;
        --no-ssh) ssh=0; shift ;;
        -h|--help) usage; exit 0 ;;
        *) fail "unknown boot option '$1'" ;;
    esac
done
SYSEXTS="$extensions"
export SYSEXTS

case "$(uname -m)" in
    x86_64|amd64) host_arch=amd64 ;;
    aarch64|arm64) host_arch=arm64 ;;
    *) fail "unsupported host architecture: $(uname -m)" ;;
esac
case "${ARCH:-$host_arch}" in
    x86_64|amd64) target_arch=amd64 ;;
    aarch64|arm64) target_arch=arm64 ;;
    *) fail "unsupported ARCH=${ARCH}" ;;
esac
if [ "$target_arch" = "$host_arch" ]; then
    fetched_dir=output/boot-image
else
    fetched_dir="output/boot-image-$target_arch"
fi

if [ "$update" -eq 1 ]; then
    [ "$explicit_image" -eq 0 ] || fail "--update cannot be combined with --image"
    image_dir="${image_dir:-$fetched_dir}"
    OUT="$image_dir"
    export OUT
    ./tools/fetch-image.sh
    image_dir="$OUT"
fi

directory=$(vm_dir "$vm")
disk="$directory/var.img"

case "$vmm" in
    auto)
        if [ "$(uname -s)" = Darwin ]; then
            if [ -n "$extensions" ] && command -v qemu-system-aarch64 >/dev/null; then vmm=qemu
            else vmm=vz
            fi
           elif { [[ "$(uname -m)" = x86_64 || "$(uname -m)" = amd64 ]] && command -v qemu-system-x86_64 >/dev/null; } ||
               { [[ "$(uname -m)" = aarch64 || "$(uname -m)" = arm64 ]] && command -v qemu-system-aarch64 >/dev/null; }; then vmm=qemu
        else vmm=firecracker
        fi ;;
    qemu|firecracker|vz) ;;
    *) fail "unknown VMM '$vmm' (expected auto, qemu, firecracker or vz)" ;;
esac
[ -z "$extensions" ] || [ "$vmm" = qemu ] ||
    fail "system extensions currently require QEMU; rerun with --vmm qemu"

if [ -z "$image_dir" ]; then
    if [ "$target_arch" = "$host_arch" ] &&
       [ -f output/rootfs.erofs ] && [ -f output/rootfs.cmdline ] && [ -f rootfs/boot/bzImage ]; then
        image_dir=output
        source_rootfs="${ROOTFS:-output/rootfs.erofs}"
        source_cmdline="${ROOT_CMDLINE:-output/rootfs.cmdline}"
        source_kernel="${KERNEL:-rootfs/boot/bzImage}"
        local_image=1
    elif [ -f "$fetched_dir/rootfs.erofs" ] && [ -f "$fetched_dir/rootfs.cmdline" ] && [ -f "$fetched_dir/bzImage" ]; then
        image_dir="$fetched_dir"
    else
        fail "no complete image found; run ./tools/build-image.sh or ./boot.sh --update"
    fi
fi
if [ -n "$image_dir" ]; then
    [ -d "$image_dir" ] || fail "image directory '$image_dir' does not exist"
    image_dir=$(cd "$image_dir" && pwd)
    if [ "$local_image" -eq 0 ]; then
        source_rootfs="${ROOTFS:-$image_dir/rootfs.erofs}"
        source_cmdline="${ROOT_CMDLINE:-$image_dir/rootfs.cmdline}"
        source_kernel="${KERNEL:-$image_dir/bzImage}"
    fi
fi
source_extensions="${EXTENSIONS:-$image_dir}"

if [ ! -e "$disk" ]; then
    if [ -e "$directory" ]; then
        fail "VM '$vm' exists without a /var disk; inspect $directory before repairing it"
    fi
    create_vm "$vm" "$size"
fi
make_machine_id "$disk.machine-id"

assert_stopped "$directory" "$vm"
mkdir "$directory/lock" || fail "VM '$vm' is already starting"
printf '%s\n' "$$" > "$directory/lock/pid"
trap 'rm -rf "$directory/lock"' EXIT
stage_images "$source_rootfs" "$source_cmdline" "$source_kernel" "$source_extensions" "$extensions"

echo ">> VM: $vm  VMM: $vmm  /var: $disk"
echo ">> rootfs/kernel: ${ROOTFS:-$OUT/rootfs.erofs}  ${KERNEL:-$OUT/bzImage}"
if [ "$ssh" -eq 0 ]; then
    SSH=0 VAR_DISK="$disk" VAR_SIZE="$size" "./tools/boot-$vmm.sh"
else
    VAR_DISK="$disk" VAR_SIZE="$size" "./tools/boot-$vmm.sh"
fi