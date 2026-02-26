# OurBox Tinderbox host contracts

This repo produces an OS image for Jetson Orin NX (8GB / 16GB) that guarantees a small set of
contracts. These contracts are the interface between "image build" and "k8s/apps".

## Contract: Release metadata

### File

- `/etc/ourbox/release`

### Format

Line-oriented `KEY=VALUE` pairs (shell-friendly). Example keys:

- `OURBOX_PRODUCT`
- `OURBOX_DEVICE`
- `OURBOX_TARGET`
- `OURBOX_SKU`
- `OURBOX_VARIANT`
- `OURBOX_VERSION`
- `OURBOX_RECIPE_GIT_HASH` (recommended)
- `OURBOX_PLATFORM_CONTRACT_SOURCE` (required — see below)
- `OURBOX_PLATFORM_CONTRACT_REVISION` (required — see below)
- `OURBOX_PLATFORM_CONTRACT_VERSION` (optional, when known)
- `OURBOX_PLATFORM_CONTRACT_DIGEST` (optional, when OCI packaging exists)

### Platform contract provenance (normative)

Tinderbox images MUST record the upstream OurBox OS platform contract provenance so operators can
answer:

- "Which platform baseline did this image ship?"
- "What upstream revision/digest does it correspond to?"

Minimum requirement (Phase 0+):
- `OURBOX_PLATFORM_CONTRACT_SOURCE`
- `OURBOX_PLATFORM_CONTRACT_REVISION`

When available, prefer also recording:
- `OURBOX_PLATFORM_CONTRACT_VERSION`
- `OURBOX_PLATFORM_CONTRACT_DIGEST`

See `docs/reference/platform-contract.md` for the full provenance model and vendoring workflow.

### Why it exists

- debugging ("what build is on this device?")
- fleet management ("what should this be running?")
- predictable support ("we can reproduce your image")

## Contract: Storage (DATA NVMe)

### Rule

- The DATA drive is auto-detected and mounted at: `/data`
- First-boot setup is handled by `ourbox-firstboot.service` (injected via `rootfs-overlay/`)

### Implementation

`ourbox-firstboot.service` selects the DATA NVMe (default: `nvme1n1`, configurable in
`config/defaults.env`), formats it, and mounts it at `/data`.

Key properties:
- Uses a first-boot service (not a static fstab entry) to set up the data disk
- Override the DATA disk by editing `config/defaults.env` before preparing installer media

### Intended contents of `/data`

This is where higher-level stacks should store persistent state:

- k3s storage / persistent volumes
- application state
- logs (if desired)

(Exact directory layout is owned by the k8s/apps layer.)

## Contract: Platform runtime

- `ourbox-hello.service` exists and prints a boot message (Phase 0 liveness probe)
- `ourbox-firstboot.service` exists and runs on first boot (sets up DATA NVMe)

Additional platform runtime contracts (k3s, bootstrap marker, etc.) will be added here as
Phase 1 brings up the full platform stack.

## Non-contracts (explicitly not guaranteed)

- No guarantee that `/data` is mounted if `ourbox-firstboot.service` hasn't run
- Not trying to support non-Orin-NX modules (Xavier, Nano, Thor, etc.)
- Not trying to support eMMC; NVMe boot is required

## Related ADRs

- ADR-0001: Consume platform contract from `sw-ourbox-os` (provenance + allocation)
