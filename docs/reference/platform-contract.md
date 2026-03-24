# Platform Contract Consumption (Tinderbox)

This document describes how `img-ourbox-tinderbox` consumes the OurBox OS **platform contract**
defined by `sw-ourbox-os`.

It is **Phase 0 / documentation-first**: it explains today's "vendored baseline" reality and the
future OCI-by-digest destination.

If this doc disagrees with reality, update this doc or fix the implementation — do not let drift
persist silently.

---

## Source of truth

The platform contract (baseline manifests + platform components contract) is defined in:

- `sw-ourbox-os` ADR-0009 (platform contract as OCI artifact):
  https://github.com/techofourown/sw-ourbox-os/blob/main/docs/decisions/ADR-0009-package-the-platform-contract-as-an-oci-artifact.md

- `sw-ourbox-os` integration reference:
  https://github.com/techofourown/sw-ourbox-os/blob/main/docs/architecture/artifact-distribution-and-integration.md

This repo is a **consumer**.

---

## Current state (Phase 0): vendored baseline injected into the rootfs

Tinderbox images inject an airgap platform directory into the Jetson rootfs via `rootfs-overlay/`.

In this repo, that content lives under:

- `rootfs-overlay/opt/ourbox/airgap/platform/`

This is allowed during Phase 0, but it must be treated as an **upstream platform contract snapshot**
— not as a freehand "platform policy playground."

This same boundary applies to installer-selection logic:

- `sw-ourbox-os` now owns the shared installer-selection contract and reference resolver for
  catalog/install-defaults-driven installers
- `sw-ourbox-os` also owns the future ourbox-substrate browsing contract and the
  `OURBOX_SUBSTRATE_*` vocabulary reserved for that lane
- Tinderbox is **not yet** a consumer of that shared resolver because its current flow is still an
  offline Jetson flashing pipeline rather than a catalog-driven payload installer
- if Tinderbox later grows an OS-payload/catalog lane, it should adopt that upstream contract
  rather than inventing a fourth local policy

---

## Required provenance recording

Because Phase 0 vendoring can drift, we require an explicit provenance boundary.

The installed system MUST record platform contract provenance in:

- `/etc/ourbox/release`

Required keys:
- `OURBOX_PLATFORM_CONTRACT_SOURCE`
- `OURBOX_PLATFORM_CONTRACT_REVISION`

Optional keys (when available):
- `OURBOX_PLATFORM_CONTRACT_VERSION`
- `OURBOX_PLATFORM_CONTRACT_DIGEST`

See also: `docs/reference/contracts.md`.

---

## Phase 0 update procedure (vendoring workflow)

When you update the embedded baseline manifests:

1. **Choose an upstream `sw-ourbox-os` revision**
   - Prefer a tagged release when available (e.g., `v0.x.y`)
   - Otherwise record the exact git SHA

2. **Update the vendored baseline content**
   - Copy/update the platform baseline manifests and any required airgap assets into
     `rootfs-overlay/opt/ourbox/airgap/platform/`.
   - Treat this as "importing a contract snapshot," not "tweaking whatever."

3. **Update `/etc/ourbox/release` generation**
   - Ensure the build writes:
     - `OURBOX_PLATFORM_CONTRACT_SOURCE`
     - `OURBOX_PLATFORM_CONTRACT_REVISION`
   - If you imported from a release tag, also write:
     - `OURBOX_PLATFORM_CONTRACT_VERSION`

4. **Document the change**
   - Add a short CHANGELOG entry stating the upstream contract revision/version you imported.

5. **Keep image references disciplined**
   - As we move into Phase 1, baseline manifests SHOULD reference app/container images by digest.
   - Do not introduce "latest" tags in baseline manifests.

---

## Future state (Phase 2): consume platform contract as an OCI artifact by digest

Destination model:

- `sw-ourbox-os` publishes a platform contract OCI artifact
- Image repos consume it by digest:
  - build-time embed (airgap), OR
  - first-boot fetch (network-optional, but must support offline export paths)

When OCI packaging exists, `OURBOX_PLATFORM_CONTRACT_DIGEST` becomes the authoritative identity
marker on device.

This repo should then minimize vendored YAML drift: the image consumes the upstream artifact rather
than carrying a forked copy forever.

---

## Related docs

- `docs/decisions/ADR-0001-consume-platform-contract-from-sw-ourbox-os.md`
- `docs/reference/contracts.md`
