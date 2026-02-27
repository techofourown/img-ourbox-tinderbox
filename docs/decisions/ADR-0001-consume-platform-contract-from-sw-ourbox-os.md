# ADR-0001: Consume the OurBox OS Platform Contract from `sw-ourbox-os`


## Context

This repository (`img-ourbox-tinderbox`) produces a flashable OS image for **Jetson Orin NX
(8GB / 16GB)** modules. It is responsible for:

- offline / airgapped provisioning via `flash-jetson.sh`
- first-boot DATA NVMe setup (mounted at `/data`)
- first-boot bootstrap services (k3s bring-up, applying baseline manifests, etc.)

We do not want image repos to become the accidental long-term "home" of the OurBox OS platform
baseline. That causes drift and makes it hard to answer "what baseline did you ship?" with any
precision.

At the org level, TOOO adopted OCI artifacts + digests as the canonical distribution substrate for
apps and platform components:

- Org ADR-0007:
  https://github.com/techofourown/org-techofourown/blob/main/docs/decisions/ADR-0007-adopt-oci-artifacts-for-app-distribution.md

In `sw-ourbox-os`, we allocated that posture into an explicit platform contract artifact concept:

- `sw-ourbox-os` ADR-0009:
  https://github.com/techofourown/sw-ourbox-os/blob/main/docs/decisions/ADR-0009-package-the-platform-contract-as-an-oci-artifact.md
- Integration reference:
  https://github.com/techofourown/sw-ourbox-os/blob/main/docs/architecture/artifact-distribution-and-integration.md

This repo must align with that model:

> `sw-ourbox-os` defines the platform contract. Image repos consume it.

## Decision

### 1) Source of truth

The OurBox OS platform contract consumed by Tinderbox images SHALL be sourced from `sw-ourbox-os`,
not defined ad-hoc in this repo.

### 2) Phase 0 allowance (vendored baseline is permitted, but must be traceable)

Until the platform contract is packaged and consumed as an OCI artifact by digest, this repo MAY
vendor a copy of baseline manifests (e.g., injected into the rootfs via `rootfs-overlay/`).

Vendored baseline content MUST be traceable to a specific `sw-ourbox-os` revision (and ideally a
version).

### 3) Provenance is mandatory

The installed system MUST record platform contract provenance in `/etc/ourbox/release`:

Required keys (Phase 0+):
- `OURBOX_PLATFORM_CONTRACT_SOURCE`
- `OURBOX_PLATFORM_CONTRACT_REVISION`

Optional keys (when available):
- `OURBOX_PLATFORM_CONTRACT_VERSION`
- `OURBOX_PLATFORM_CONTRACT_DIGEST`

### 4) Future intent

When `sw-ourbox-os` publishes the platform contract as an OCI artifact, this repo SHOULD move to
consuming it by digest (build-time embed or first-boot fetch), per the upstream plan.

## Rationale

- Avoids baseline drift across image repos.
- Makes it supportable: "show me the contract revision/digest."
- Keeps hackability intact while keeping the official baseline legible.

## Consequences

### Positive
- Clear producer/consumer boundary.
- Image repos stay mechanical: hardware enablement + bootstrap, not "platform policy."
- Easier future trust layering (signatures / release manifests).

### Negative
- Requires discipline during Phase 0 vendoring.
- Adds a few required release metadata fields.

### Mitigation
- Add a reference doc describing Phase 0 vendoring and the future OCI-by-digest destination
  (`docs/reference/platform-contract.md`).
- Keep the required provenance keys small and stable.

## References

- Org ADR-0007:
  https://github.com/techofourown/org-techofourown/blob/main/docs/decisions/ADR-0007-adopt-oci-artifacts-for-app-distribution.md
- `sw-ourbox-os` ADR-0009:
  https://github.com/techofourown/sw-ourbox-os/blob/main/docs/decisions/ADR-0009-package-the-platform-contract-as-an-oci-artifact.md
- `sw-ourbox-os` integration reference:
  https://github.com/techofourown/sw-ourbox-os/blob/main/docs/architecture/artifact-distribution-and-integration.md
- Reference: `docs/reference/platform-contract.md` (this repo)
