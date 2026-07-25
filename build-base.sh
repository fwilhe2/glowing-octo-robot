#!/bin/bash
# Build the base image every package builder derives from, and create the shared
# staging directories.
set -euo pipefail

podman build -t localhost/abstract-lfs-builder .

mkdir -p rootfs output
