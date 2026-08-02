FROM localhost/abstract-lfs-builder:latest

# build-dep needs source package entries, which the debian:sid image ships without.
RUN sed -i 's/^Types: .*/Types: deb deb-src/' /etc/apt/sources.list.d/debian.sources

# BUILD_DEP: Debian source package to take build-dependencies from, empty for packages
#            that have no Debian counterpart to borrow from and list everything instead.
# EXTRA_DEPS: space-separated packages build-dep doesn't pull in.
ARG BUILD_DEP
ARG EXTRA_DEPS=""

RUN apt-get update \
    && if [ -n "$BUILD_DEP" ]; then apt-get build-dep -y "$BUILD_DEP"; fi \
    && if [ -n "$EXTRA_DEPS" ]; then apt-get install -y $EXTRA_DEPS; fi

COPY builder/build-package.sh /build.sh
RUN chmod +x /build.sh
