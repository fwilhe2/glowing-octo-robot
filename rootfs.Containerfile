FROM debian:sid

RUN apt-get update && apt-get -y install e2fsprogs cpio wget

COPY build-rootfs.sh /usr/local/bin/
RUN chmod +X /usr/local/bin/build-rootfs.sh

COPY _files /files

WORKDIR /usr/local/src