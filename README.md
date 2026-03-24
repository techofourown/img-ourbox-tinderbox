# img-ourbox-tinderbox

Offline, command-line provisioning for **Jetson Orin NX (8GB / 16GB)** modules (“tinderbox”).

Goal for this repo (phase 0):
- Flash **Jetson Linux / JetPack base** onto the **OS NVMe** (boot-from-NVMe).
- On first boot, automatically set up the **DATA NVMe** and mount it at `/data`.
- Print a loud **Hello World** on the serial/console logs so you can prove it’s alive.

## What this is (and is not)

- ✅ **CLI-only**, no SDK Manager GUI.
- ✅ Designed for **airgapped / offline** use *after* you run `./tools/prepare-installer-media.sh`.
- ✅ **Fail-fast**: refuses to flash anything except **Jetson Orin NX 8GB/16GB** in Force Recovery.
- ❌ Not trying to support Xavier, Nano, Thor, emmc, etc. Not in scope.

## Supported hardware (locked down)

- Jetson **Orin NX 16GB** (Force Recovery `lsusb` id `0955:7323`)
- Jetson **Orin NX 8GB**  (Force Recovery `lsusb` id `0955:7423`)

This repo targets the NVIDIA reference configuration used by the Jetson Linux docs:
`jetson-orin-nano-devkit` board config (works for Orin NX modules on the reference Orin Nano / Orin NX carrier).

## Quickstart

### 0) Clone

```bash
git clone --recurse-submodules https://github.com/techofourown/img-ourbox-tinderbox.git
cd img-ourbox-tinderbox
```

### 1) Fetch NVIDIA artifacts (one-time, online step)

The NVIDIA Jetson Linux artifacts are **not stored in git**.

This is the **only** step that requires internet access.

```bash
./tools/fetch-nvidia-artifacts.sh
```

That script will:
- show the NVIDIA release + license URLs
- ask you to confirm you accept NVIDIA’s terms
- download the tarballs into `artifacts/nvidia/`

If you prefer to place files manually, the required filenames are:

```
artifacts/nvidia/
  Jetson_Linux_R36.5.0_aarch64.tbz2
  Tegra_Linux_Sample-Root-Filesystem_R36.5.0_aarch64.tbz2
```

### 2) Prepare installer USB (on a Linux x86_64 host)

This will **erase** the selected USB drive and write a self-contained offline flasher onto it.

```bash
sudo ./tools/prepare-installer-media.sh
```

If the NVIDIA artifacts are missing, `prepare-installer-media.sh` will offer to download them for you.

When it finishes, you’ll have a USB drive labeled `TINDERBOX_INSTALLER`.

### 3) Flash a Jetson (offline / airgapped)

On your *airgapped* flashing host:

1) Put the Jetson into **Force Recovery Mode**
2) Connect Jetson to the host over USB
3) Plug in the prepared `TINDERBOX_INSTALLER` USB drive
4) Run:

```bash
cd /media/$USER/TINDERBOX_INSTALLER/tinderbox
sudo ./flash-jetson.sh
```

The script will prompt you for which NVMe should be the OS drive (`nvme0n1` vs `nvme1n1`) and will refuse to run if the Jetson is not an Orin NX 8GB/16GB.

### 4) Boot from NVMe

After flashing completes:
- power-cycle the Jetson
- it should boot from the OS NVMe
- you should see a **Hello Tinderbox** message in the console/journal
- the second NVMe should be mounted at `/data` (auto-created on first boot)

## Configuration knobs

Edit `config/defaults.env` before preparing the installer USB if you want to change:
- default username/password/hostname
- which NVMe is assumed to be OS vs DATA (defaults: OS=nvme0n1, DATA=nvme1n1)

## Shared selection seam

Tinderbox is intentionally **not** part of the first Matchbox/Woodbox shared installer-selection
resolver migration.

Why:

- today it is a host-side Jetson flasher, not a catalog-driven registry installer
- its hard parts are NVIDIA Force Recovery, initrd diagnostics, BSP/rootfs staging, and offline USB media

What still applies:

- `sw-ourbox-os` remains the upstream owner of install-defaults and the installer-selection contract
- `sw-ourbox-os` also owns the future ourbox-substrate selection lane and its shared vocabulary
- `install-defaults/defaults/tinderbox.env` exists upstream as the future control-plane profile for
  a Tinderbox payload-selection lane

Reserved future installer control names:

- `OURBOX_SUBSTRATE_REPO`
- `OURBOX_SUBSTRATE_ARCH`
- `OURBOX_SUBSTRATE_CHANNEL`
- `OURBOX_SUBSTRATE_CATALOG_ENABLED`
- `OURBOX_SUBSTRATE_CATALOG_TAG`

Reserved future installed provenance names:

- `OURBOX_SUBSTRATE_SOURCE`
- `OURBOX_SUBSTRATE_REVISION`
- `OURBOX_SUBSTRATE_VERSION`
- `OURBOX_SUBSTRATE_CREATED`
- `OURBOX_SUBSTRATE_ARCH`
- `OURBOX_SUBSTRATE_PROFILE`
- `OURBOX_SUBSTRATE_K3S_VERSION`
- `OURBOX_SUBSTRATE_IMAGES_LOCK_SHA256`
- `OURBOX_SUBSTRATE_REF`
- `OURBOX_SUBSTRATE_DIGEST`

When Tinderbox grows that lane, it should adopt the upstream shared installer-selection contract and
reference resolver rather than inventing a fourth vocabulary. Until then, its
flashing flow remains hardware-specific by design.

## Repo layout

- `tools/fetch-nvidia-artifacts.sh` — downloads NVIDIA artifacts (online step; requires license acceptance)
- `tools/prepare-installer-media.sh` — builds the offline installer USB
- `media/flash-jetson.sh` — copied onto the USB; flashes the Jetson via Linux_for_Tegra initrd flash
- `rootfs-overlay/` — files injected into the Jetson rootfs
  - `ourbox-hello.service` prints hello world every boot
  - `ourbox-firstboot.service` sets up the DATA NVMe on first boot
