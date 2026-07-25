# defconfig plus kvm_guest.config is what a qemu guest needs: virtio-blk for the root
# disk and the 8250 serial console, both built in, so the image boots with no initrd.
make defconfig
make kvm_guest.config
make -j"$(nproc)"

# The rootfs image is what CI hands to qemu, so the kernel rides along inside it. It is
# never loaded from there — qemu is passed -kernel — but keeping the two together means
# a build artifact is always bootable on its own.
install -D -m 644 arch/x86/boot/bzImage /usr/local/rootfs/boot/bzImage
