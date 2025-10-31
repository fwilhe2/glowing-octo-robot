FROM debian:sid

RUN apt-get update && apt-get -y install e2fsprogs cpio

COPY build-rootfs.sh /usr/local/bin/
RUN chmod +X /usr/local/bin/build-rootfs.sh

WORKDIR /usr/local/src