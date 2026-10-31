# Documentation

Guides describe current behavior. Proposals describe work that is not implemented.

## Guides

- [How the build works](guides/how-it-works.md): package builds, assembly, and CI.
- [Build inputs](guides/build-container.md): builder and sources images.
- [Linking](guides/linking.md): runtime library compatibility and ELF checks.
- [System extensions](guides/sysext.md): build and attach extensions.
- [Debugging](guides/debugging.md): tools available in the base and debug extension.

## Proposals

- [Build dependencies](proposals/extension-dependencies.md): compile packages against
  other packages built in this repository.
- [Image variants](proposals/image-variants.md): select package sets at assembly time.
- [macOS container host](proposals/container-host.md): use the image as a Podman VM.
- [Releases](proposals/release.md): versioned VM artifacts and OCI tags.
- [Build reproduction and patches](proposals/reproducing-a-build.md): archive the recipe
  and support downstream source patches.
- [Ideas from other builders](proposals/ideas-from-other-builders.md): checks, hardening
  and SBOM features adapted from Talos, LinuxKit, Flatcar and podman-machine-os.

Host architecture and tool requirements are summarized in the [project README](../README.md#host-requirements).
