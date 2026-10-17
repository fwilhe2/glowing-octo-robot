#!/usr/bin/env bash
# Run binaries this repository did not build:
#
#     ./test/prebuilt.sh [output/flfs-oci.tar]
#
# Every other check here runs something compiled in builder/, against our sysroot. That
# leaves out the most common way anything gets onto a general-purpose Linux — somebody
# else's toolchain, on somebody else's distribution — and it is a different question,
# because a prebuilt binary asks for whatever *its* toolchain links by default rather
# than whatever our configure lines allowed. Until packages/gcc existed, the answer for
# nearly every Rust binary for a *-linux-gnu target was "libgcc_s.so.1: cannot open
# shared object file", and nothing here said so.
#
# So this compiles a handful of small programs on the host, with the host's stock
# compilers, and runs them inside the OCI image. Each is chosen for what it needs from
# the image, not for what it does:
#
#   c-cancel     pthread_cancel, which makes glibc dlopen libgcc_s — the case
#                check-rootfs-deps.sh cannot see, since nothing has it in NEEDED.
#   cxx          libstdc++ and an exception that has to unwind through it.
#   rust         libgcc_s in NEEDED, and a panic caught with catch_unwind.
#   go-cgo       a dynamically linked Go binary, through glibc's NSS for user lookup,
#                and /usr/share/zoneinfo through time.LoadLocation.
#   go-static    the CGO_ENABLED=0 binary most Go projects publish: zoneinfo, and the
#                CA bundle where crypto/x509 looks for it.
#
# The OCI image rather than a qemu boot because none of this is about the kernel, and it
# takes seconds; both flavours ship the same libraries. A host compiler that is missing
# skips its program with a note locally and fails under CI, where all four are expected.
# The host's glibc has to be no newer than ours for the dynamically linked ones — a
# binary built against a newer glibc than the one it runs on is correctly refused, and
# that would be the host's problem, not the image's.
set -euo pipefail

cd "$(dirname "$0")/.."

ARCHIVE="${1:-output/flfs-oci.tar}"
[ -f "$ARCHIVE" ] || { echo "error: no OCI archive at $ARCHIVE (see test/oci.sh)" >&2; exit 1; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin"

missing=()
have() {
    command -v "$1" >/dev/null && return 0
    echo "  skip  $2: no $1 on this host"
    missing+=("$1")
    return 1
}

echo "compiling on the host:"

cat >"$work/cancel.c" <<'EOF'
#include <pthread.h>
#include <stdio.h>
#include <unistd.h>
static void *spin(void *arg) { (void)arg; for (;;) pause(); return NULL; }
int main(void) {
    pthread_t t;
    void *ret;
    pthread_create(&t, NULL, spin, NULL);
    pthread_cancel(t);
    pthread_join(t, &ret);
    if (ret != PTHREAD_CANCELED) return 1;
    puts("cancelled");
    return 0;
}
EOF
have gcc c-cancel && gcc -O2 -pthread -o "$work/bin/c-cancel" "$work/cancel.c"

cat >"$work/cxx.cc" <<'EOF'
#include <iostream>
#include <stdexcept>
#include <string>
#include <thread>
int main() {
    std::string got;
    std::thread t([&] {
        try { throw std::runtime_error("unwound"); }
        catch (const std::exception &e) { got = e.what(); }
    });
    t.join();
    std::cout << got << std::endl;
    return got == "unwound" ? 0 : 1;
}
EOF
have g++ cxx && g++ -O2 -pthread -o "$work/bin/cxx" "$work/cxx.cc"

cat >"$work/main.rs" <<'EOF'
fn main() {
    std::panic::set_hook(Box::new(|_| {}));
    let r = std::panic::catch_unwind(|| panic!("unwound"));
    assert!(r.is_err());
    println!("caught");
}
EOF
have rustc rust && rustc -O -o "$work/bin/rust" "$work/main.rs"

mkdir -p "$work/go"
cat >"$work/go/main.go" <<'EOF'
package main

import (
	"crypto/x509"
	"fmt"
	"os"
	"os/user"
	"time"
)

func main() {
	loc, err := time.LoadLocation("Europe/Berlin")
	if err != nil {
		fmt.Println("zoneinfo:", err)
		os.Exit(1)
	}
	u, err := user.Current()
	if err != nil {
		fmt.Println("user:", err)
		os.Exit(1)
	}
	pool, err := x509.SystemCertPool()
	if err != nil || len(pool.Subjects()) == 0 { //nolint:staticcheck
		fmt.Println("certificates: none found", err)
		os.Exit(1)
	}
	fmt.Println(loc, u.Username, len(pool.Subjects()), "roots") //nolint:staticcheck
}
EOF
printf 'module prebuilt\n\ngo 1.21\n' >"$work/go/go.mod"
if have go go; then
    # GOFLAGS empty and a private cache, so the host's settings say nothing about it.
    export GOFLAGS= GOCACHE="$work/gocache" GOTOOLCHAIN=local
    (cd "$work/go" && CGO_ENABLED=1 go build -o "$work/bin/go-cgo" .)
    (cd "$work/go" && CGO_ENABLED=0 go build -o "$work/bin/go-static" .)
fi

if [ -n "${CI:-}" ] && [ ${#missing[@]} -gt 0 ]; then
    echo "error: CI is expected to have every host compiler; missing: ${missing[*]}" >&2
    exit 1
fi

loaded=$(podman load --quiet --input "$ARCHIVE" | tail -n1)
ref=${loaded##*: }
echo "running in $ref:"

fail=0
for bin in "$work"/bin/*; do
    name=$(basename "$bin")
    if out=$(podman run --rm --network=none --volume "$work/bin:/prebuilt:ro,Z" \
                 --entrypoint "/prebuilt/$name" "$ref" 2>&1); then
        echo "  ok    $name: $out"
    else
        echo "  FAIL  $name:"
        printf '        %s\n' "$out"
        fail=1
    fi
done
exit $fail
