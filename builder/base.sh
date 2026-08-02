#!/bin/bash
# Build the base image every package builder derives from, and create the shared
# staging directories. The build context is the repository root, so run it from there
# — ../build.sh does.
set -euo pipefail

podman build -t localhost/abstract-lfs-builder -f builder/base.Containerfile .

mkdir -p rootfs output
