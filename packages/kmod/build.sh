# -Dopenssl=disabled: kmod's openssl feature is PKCS#7 module-signature parsing and
# nothing else, but it puts libcrypto.so.3 in libkmod.so.2's NEEDED — and we don't ship
# libcrypto. systemd *dlopens* libkmod.so.2, so the missing dependency surfaces as
# "Failed to initialize kmod context: Operation not supported" from PID 1 and udevd,
# and makes modprobe/kmod unrunnable in the image. Our kernel is monolithic and its
# modules are unsigned, so there is no signature to verify.
meson_install -Dopenssl=disabled
