FROM localhost/abstract-lfs-builder:latest

# build-dep needs source package entries, which the debian:sid image ships without.
RUN sed -i 's/^Types: .*/Types: deb deb-src/' /etc/apt/sources.list.d/debian.sources

# BUILD_DEP: Debian source package to take build-dependencies from.
# EXTRA_DEPS: space-separated packages build-dep doesn't pull in.
ARG BUILD_DEP
ARG EXTRA_DEPS=""

RUN apt-get update \
    && apt-get build-dep -y "$BUILD_DEP" \
    && if [ -n "$EXTRA_DEPS" ]; then apt-get install -y $EXTRA_DEPS; fi

COPY lib/build-package.sh /build.sh
RUN chmod +x /build.sh
