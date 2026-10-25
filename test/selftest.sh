#!/bin/bash
# Prove the static checks can fail:
#
#     ./test/selftest.sh
#
# Every check in test/ that reads a tree reports success when it finds nothing wrong — and
# a check that is broken finds nothing wrong too. That is not hypothetical here. The first
# version of check-symbol-resolution.sh resolved NEEDED by SONAME only, decided bash's
# libtinfo.so.6 was missing, skipped bash and seventy other programs, and still printed
# its success line. CLAUDE.md's grep -a story is the same shape: a sweep that matched
# nothing and said so with exit 0.
#
# So each check gets small trees built to be wrong in exactly one way, and has to fail on
# each — and say *what* is wrong, by name, so that a check that crashes or fails for an
# unrelated reason does not count. Each also gets a tree that is right in every way, and
# has to pass on it: a fixture that fails for the wrong reason proves nothing either.
#
# The ELF trees are compiled here, from a few lines of C, with the host's gcc and against
# the host's libc, rather than committed: a binary fixture is opaque in review and only
# runs on one architecture. Nothing here needs the image, the builder or podman, so it
# runs in seconds in its own workflow (.github/workflows/selftest.yml).
set -euo pipefail

cd "$(dirname "$0")/.."

for tool in gcc readelf; do
    command -v "$tool" >/dev/null || { echo "error: $tool is needed to build the fixtures" >&2; exit 1; }
done

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

# expect pass|fail <description> <pattern> <command...>
#
# For "fail", the command must exit non-zero AND print the pattern (stdout or stderr):
# the name of the thing the fixture broke. For "pass", it must exit zero.
expect() {
    local want=$1 what=$2 pattern=$3 out rc=0
    shift 3
    out=$("$@" 2>&1) || rc=$?
    if [ "$want" = pass ] && [ "$rc" -eq 0 ]; then
        echo "ok    $what"
    elif [ "$want" = fail ] && [ "$rc" -ne 0 ] && grep -q -- "$pattern" <<< "$out"; then
        echo "ok    $what"
    else
        echo "FAIL  $what (expected the check to $want${pattern:+ naming '$pattern'}, exit $rc)"
        sed 's/^/        /' <<< "$out" | head -20
        failures=$((failures + 1))
    fi
}

# ---------------------------------------------------------------------------------
# ELF fixtures
#
# libfoo comes in two builds with one SONAME, the way a library and the newer header
# someone compiled against do:
#
#   new  foo_old, foo_new (unversioned), foo_v1 @FOO_1, foo_v2 @FOO_2
#   old  foo_old, foo_v1 @FOO_1 — the release before foo_new and FOO_2 existed
#
# and app is linked against new. A tree with new is correct; a tree with old is each of
# the failures this repository's coupling to the builder's headers can produce
# (docs/linking.md, section 4). app also references a weak foo_maybe that no build
# defines, which is legitimate and must not be reported.

src=$work/src
mkdir -p "$src"

cat > "$src/new.c" <<'EOF'
int foo_old(void) { return 1; }
int foo_new(void) { return 2; }
int foo_v1(void) { return 3; }
int foo_v2(void) { return 4; }
EOF
cat > "$src/new.map" <<'EOF'
FOO_1 { global: foo_v1; };
FOO_2 { global: foo_v2; } FOO_1;
EOF
cat > "$src/old.c" <<'EOF'
int foo_old(void) { return 1; }
int foo_v1(void) { return 3; }
EOF
cat > "$src/old.map" <<'EOF'
FOO_1 { global: foo_v1; };
EOF
# foo_old and foo_new stay unversioned: a version script only tags what it names, and
# the rest of the exports stay as they are, which is what a library without symbol
# versions looks like from the outside.
cat > "$src/app.c" <<'EOF'
int foo_old(void); int foo_new(void); int foo_v1(void); int foo_v2(void);
__attribute__((weak)) int foo_maybe(void);
int main(void) {
    return foo_old() + foo_new() + foo_v1() + foo_v2() + (foo_maybe ? foo_maybe() : 0);
}
EOF

so() { # <out> <c> <map>
    gcc -shared -fPIC -Wl,-soname,libfoo.so.1 -Wl,--version-script="$3" "$2" -o "$1"
}
mkdir -p "$src/new" "$src/old"
so "$src/new/libfoo.so.1" "$src/new.c" "$src/new.map"
so "$src/old/libfoo.so.1" "$src/old.c" "$src/old.map"
gcc "$src/app.c" -L"$src/new" -l:libfoo.so.1 -o "$src/app"

# The host's libc and loader, under the names the binaries ask for, so a tree is complete
# without anything from this repository's build. The loader is whatever app's PT_INTERP
# names: ld-linux-x86-64.so.2 or ld-linux-aarch64.so.1.
interp=$(readelf -lW "$src/app" | sed -n 's/.*Requesting program interpreter: \(.*\)]/\1/p')
libc=$(gcc -print-file-name=libc.so.6)

tree() { # <name> <libfoo build> — a minimal merged-/usr tree
    local t=$work/$1
    mkdir -p "$t/usr/bin" "$t/usr/lib"
    ln -s usr/lib "$t/lib"
    ln -s usr/lib "$t/lib64"
    cp "$src/app" "$t/usr/bin/app"
    cp -L "$libc" "$t/usr/lib/libc.so.6"
    cp -L "$interp" "$t/usr/lib/$(basename "$interp")"
    [ -z "$2" ] || cp "$src/$2/libfoo.so.1" "$t/usr/lib/libfoo.so.1"
    echo "$t"
}

empty=$work/empty-allowlist
: > "$empty"

good=$(tree good new)
expect pass "rootfs-deps: a complete tree passes"            "" ./test/check-rootfs-deps.sh "$good" "$empty"
expect pass "symbol-versions: a complete tree passes"        "" ./test/check-symbol-versions.sh "$good"
expect pass "symbol-resolution: a complete tree passes"      "" ./test/check-symbol-resolution.sh "$good"

nolib=$(tree nolib "")
expect fail "rootfs-deps: a missing library is reported"     libfoo.so.1 ./test/check-rootfs-deps.sh "$nolib" "$empty"
allow=$work/allow-libfoo
echo libfoo.so.1 > "$allow"
expect pass "rootfs-deps: an allowlisted library is accepted" "" ./test/check-rootfs-deps.sh "$nolib" "$allow"

old=$(tree old old)
expect fail "symbol-versions: a missing version is reported" FOO_2 ./test/check-symbol-versions.sh "$old"
expect fail "symbol-resolution: a missing symbol is reported" foo_new ./test/check-symbol-resolution.sh "$old"

# The loader matches NEEDED against file names, and a symlink is one: here libfoo.so.1
# exists only as a link to a file whose name and SONAME are something else. This is the
# libtinfo.so.6 -> libtinfow.so.6 arrangement that check-symbol-resolution.sh once got
# wrong, and both checks that resolve NEEDED have to accept it.
alias=$(tree alias "")
gcc -shared -fPIC -Wl,-soname,libfoo-real.so.1 -Wl,--version-script="$src/new.map" \
    "$src/new.c" -o "$alias/usr/lib/libfoo-real.so.1"
ln -s libfoo-real.so.1 "$alias/usr/lib/libfoo.so.1"
expect pass "rootfs-deps: a library found through a symlink name passes" \
    "" ./test/check-rootfs-deps.sh "$alias" "$empty"
expect pass "symbol-resolution: a library found through a symlink name passes" \
    "" ./test/check-symbol-resolution.sh "$alias"

# And the same arrangement with the *old* library behind the link, which has to fail.
# The pass above cannot tell a check that followed the link from one that gave up on
# app — an object whose library cannot be found is skipped, and a skipped object reports
# nothing, which is exactly the success the pass asked for. That is how the symlink bug
# went unnoticed the first time, and with only the pass, this file did not catch it
# either when the bug was put back on purpose. A finding cannot be produced by skipping.
alias_old=$(tree alias-old "")
gcc -shared -fPIC -Wl,-soname,libfoo-real.so.1 -Wl,--version-script="$src/old.map" \
    "$src/old.c" -o "$alias_old/usr/lib/libfoo-real.so.1"
ln -s libfoo-real.so.1 "$alias_old/usr/lib/libfoo.so.1"
expect fail "symbol-resolution: a missing symbol behind a symlink name is reported" \
    foo_new ./test/check-symbol-resolution.sh "$alias_old"

# ---------------------------------------------------------------------------------
# Kernel config
#
# A config that has every symbol kernel-caps.sh requires, generated from the script's own
# list so that adding a requirement there does not break this — and then the same config
# with one removed. The list is every line of its heredocs that starts with a symbol;
# both architectures' extras are included, which is harmless, since extra =y lines are
# never an error.

kernel=$work/kernel
mkdir -p "$kernel/boot"
{
    echo "# Linux/x86 0.0.0 Kernel Configuration"
    awk '/<<.EOF/ { on = 1; next } /^EOF/ { on = 0 } on && /^[A-Z0-9_]+ / { print "CONFIG_" $1 "=y" }' \
        test/kernel-caps.sh
} > "$kernel/boot/config"
expect pass "kernel-caps: a config with every requirement passes" "" ./test/kernel-caps.sh "$kernel"

sed -i '/^CONFIG_USER_NS=y$/d' "$kernel/boot/config"
expect fail "kernel-caps: a missing requirement is reported" CONFIG_USER_NS ./test/kernel-caps.sh "$kernel"

echo
if [ "$failures" -gt 0 ]; then
    echo "$failures self-test(s) failed: a check above can no longer tell right from wrong."
    exit 1
fi
echo "Every check fails on what it exists to catch, and passes on a correct tree."
