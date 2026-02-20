#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# On-rails Jetson flashing script (NO PROMPTS / NO BOARD CHOICES)
#
# Hardware assumptions (your "stable setup"):
# - Target is Jetson Orin Nano Developer Kit
# - OS lives on the NVMe in your fixed OS M.2 slot and it enumerates as:
#       /dev/nvme0n1  (root partition /dev/nvme0n1p1)
# - Second NVMe (user data) MUST NOT become nvme0n1, or you will wipe it.
#
# Usage:
#   sudo ./tools/flash-orin-nano-nvme-r36.5.sh [--yes]
#
#   --yes   Skip the interactive NVIDIA license confirmation (for CI/automation).
#           By accepting this flag you confirm you have read and agreed to
#           NVIDIA's Jetson Linux software license.
#
# Artifacts:
#   If the NVIDIA tarballs are not yet present in artifacts/nvidia/, this
#   script will offer to download them (internet required for that step only).
#   All subsequent steps run fully offline.
###############################################################################

# Fixed release + fixed board + fixed root device
L4T_RELEASE="R36.5.0"
BOARD="jetson-orin-nano-devkit"
TARGET_NVME_PART="nvme0n1p1"          # OS rootfs partition on the Jetson
EXTERNAL_DEVICE_PART="nvme0n1p1"      # same partition for --external-device

# Orin Nano recovery USB ID
APX_USB_VIDPID="0955:7323"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

SRC_DIR="${REPO_ROOT}/artifacts/nvidia"
JETSON_TARBALL="${SRC_DIR}/Jetson_Linux_${L4T_RELEASE}_aarch64.tbz2"
ROOTFS_TARBALL="${SRC_DIR}/Tegra_Linux_Sample-Root-Filesystem_${L4T_RELEASE}_aarch64.tbz2"

# Workspace: honour an explicit override, otherwise follow XDG cache convention.
# Any user on any machine can set JETSON_FLASH_WORKDIR to redirect this.
WORK_DIR="${JETSON_FLASH_WORKDIR:-${XDG_CACHE_HOME:-$HOME/.cache}/jetson-flash}"
L4T_DIR="${WORK_DIR}/Linux_for_Tegra"
LOG_DIR="${WORK_DIR}/logs"

# Populated by --yes flag or read from defaults.env below.
ASSUME_YES="false"

# Load repo defaults (URLs etc.) if present — never fatal if absent, we have fallbacks.
_DEFAULTS_ENV="${REPO_ROOT}/config/defaults.env"
if [[ -f "$_DEFAULTS_ENV" ]]; then
  # shellcheck disable=SC1090
  source "$_DEFAULTS_ENV"
fi

###############################################################################
# Helpers
###############################################################################

say()  { printf '%s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

safe_rm_rf() {
  local p="$1"
  [[ -n "$p" ]] || die "safe_rm_rf: empty path"
  [[ "$p" != "/" ]] || die "Refusing to delete /"
  # Must be inside the configured work directory — never somewhere unexpected.
  [[ "$p" == "${WORK_DIR}"/* ]] || die "Refusing to delete unexpected path: $p"
  sudo rm -rf "$p"
}

cleanup_stale_exports() {
  # Remove NVIDIA NFS export entries that belong to this workspace only.
  local exports="/etc/exports"
  [[ -f "$exports" ]] || return 0

  sudo cp -a "$exports" "${exports}.backup.$(date +%Y%m%d-%H%M%S)"

  sudo sed -i '\|# Entry added by NVIDIA initrd flash tool|d' "$exports"
  sudo sed -i "\|${L4T_DIR}/rootfs|d" "$exports"
  sudo sed -i "\|${L4T_DIR}/tools/kernel_flash/images|d" "$exports"
  sudo sed -i "\|${L4T_DIR}/tools/kernel_flash/tmp|d" "$exports"

  sudo exportfs -ra >/dev/null 2>&1 || true
}

detect_apx_count() {
  # Try the known VID:PID first; fall back to scanning lsusb output for "APX".
  local c="0"
  c="$(lsusb -d "${APX_USB_VIDPID}" 2>/dev/null | wc -l | tr -d ' ')" || true
  if [[ "$c" -gt 0 ]]; then
    echo "$c"
    return 0
  fi

  local apx_lines
  apx_lines="$(lsusb 2>/dev/null | grep -i 'APX' || true)"
  if [[ -z "$apx_lines" ]]; then
    echo "0"
    return 0
  fi
  echo "$apx_lines" | sed '/^\s*$/d' | wc -l | tr -d ' '
}

# Locate flash_t234_qspi*.xml anywhere under bootloader/.
# Checks common known paths first, then does a broad find as fallback.
resolve_qspi_cfg() {
  local f=""

  local candidates=(
    "${L4T_DIR}/bootloader/generic/cfg/flash_t234_qspi.xml"
    "${L4T_DIR}/bootloader/t186ref/cfg/flash_t234_qspi.xml"
  )
  local c
  for c in "${candidates[@]}"; do
    if [[ -f "$c" ]]; then
      echo "$c"
      return 0
    fi
  done

  f="$(find "${L4T_DIR}/bootloader" -maxdepth 6 -type f -name 'flash_t234_qspi.xml' | head -n 1 || true)"
  if [[ -n "$f" ]]; then echo "$f"; return 0; fi

  f="$(find "${L4T_DIR}/bootloader" -maxdepth 6 -type f -name 'flash_t234_qspi*.xml' | head -n 1 || true)"
  if [[ -n "$f" ]]; then echo "$f"; return 0; fi

  return 1
}

# Locate flash_l4t_t234_nvme*.xml under tools/kernel_flash/.
resolve_nvme_xml() {
  local f=""

  f="$(find "${L4T_DIR}/tools/kernel_flash" -maxdepth 6 -type f -name 'flash_l4t_t234_nvme.xml' | head -n 1 || true)"
  if [[ -n "$f" ]]; then echo "$f"; return 0; fi

  f="$(find "${L4T_DIR}/tools/kernel_flash" -maxdepth 6 -type f -name 'flash_l4t_t234_nvme*.xml' | head -n 1 || true)"
  if [[ -n "$f" ]]; then echo "$f"; return 0; fi

  return 1
}

###############################################################################
# Artifact download (internet required for this step only)
###############################################################################

# Download a single file with resume support.  Uses a .partial temp file so an
# interrupted download can be continued rather than restarted.
_curl_download() {
  local url="$1"
  local dest="$2"
  local label="$3"

  if [[ -f "$dest" ]]; then
    say "  ${label}: already present — skipping."
    return 0
  fi

  local tmp="${dest}.partial"
  say "  ${label}: downloading..."
  say "    -> ${dest}"

  if [[ -f "$tmp" ]]; then
    # Resume an interrupted download.
    curl -fL --retry 3 --retry-delay 2 --retry-connrefused -C - -o "$tmp" "$url"
  else
    curl -fL --retry 3 --retry-delay 2 --retry-connrefused -o "$tmp" "$url"
  fi

  mv "$tmp" "$dest"
  say "  ${label}: done."
}

# Check whether NVIDIA artifacts are present; download them if not.
# Presents the license gate before any bytes are transferred.
fetch_artifacts() {
  if [[ -f "$JETSON_TARBALL" && -f "$ROOTFS_TARBALL" ]]; then
    say "NVIDIA artifacts already present — skipping download."
    return 0
  fi

  # Resolve download URLs: config/defaults.env is already sourced at the top,
  # so NVIDIA_BSP_URL etc. are available if the file existed.  Fall back to
  # the hardcoded R36.5.0 URLs so the script works on a fresh clone with no
  # config edits required.
  local bsp_url="${NVIDIA_BSP_URL:-}"
  local rootfs_url="${NVIDIA_ROOTFS_URL:-}"
  local license_url="${NVIDIA_TEGRA_LICENSE_URL:-}"
  local release_url="${NVIDIA_RELEASE_PAGE_URL:-}"

  if [[ -z "$bsp_url" || -z "$rootfs_url" ]]; then
    if [[ "$L4T_RELEASE" == "R36.5.0" ]]; then
      local base="https://developer.download.nvidia.com/embedded/L4T/r36_Release_v5.0/release"
      bsp_url="${base}/Jetson_Linux_${L4T_RELEASE}_aarch64.tbz2"
      rootfs_url="${base}/Tegra_Linux_Sample-Root-Filesystem_${L4T_RELEASE}_aarch64.tbz2"
      license_url="${license_url:-${base}/Tegra_Software_License_Agreement-Tegra-Linux.txt}"
      release_url="${release_url:-https://developer.nvidia.com/embedded/jetson-linux-r365}"
    else
      die "No download URLs configured for L4T_RELEASE=${L4T_RELEASE}.\nSet NVIDIA_BSP_URL and NVIDIA_ROOTFS_URL in config/defaults.env."
    fi
  fi

  need_cmd curl
  need_cmd sha256sum

  say ""
  say "One or more NVIDIA artifacts are missing and must be downloaded."
  say "  L4T_RELEASE : ${L4T_RELEASE}"
  say "  Destination : ${SRC_DIR}"
  [[ -n "$release_url" ]] && say "  Release page: ${release_url}"
  [[ -n "$license_url" ]] && say "  License     : ${license_url}"
  say ""
  say "You must accept NVIDIA's license terms before using these files."
  say ""

  if [[ "$ASSUME_YES" != "true" ]]; then
    local answer
    printf "Type YES to confirm you accept NVIDIA's license terms and proceed with download: "
    read -r answer
    [[ "$answer" == "YES" ]] || die "Aborted — license not accepted."
  else
    say "(--yes passed: license acceptance assumed)"
  fi

  mkdir -p "$SRC_DIR"

  say ""
  say "Downloading NVIDIA artifacts..."

  # Download the license text for local reference (kept out of git via .gitignore).
  if [[ -n "$license_url" ]]; then
    _curl_download "$license_url" \
      "${SRC_DIR}/NVIDIA_Tegra_Software_License_Agreement.txt" \
      "NVIDIA license text"
  fi

  _curl_download "$bsp_url"    "$JETSON_TARBALL" "Jetson Linux BSP tarball"
  _curl_download "$rootfs_url" "$ROOTFS_TARBALL" "Sample rootfs tarball"

  say ""
  say "Recording SHA256 checksums -> ${SRC_DIR}/SHA256SUMS.txt"
  (
    cd "$SRC_DIR"
    sha256sum "$(basename "$JETSON_TARBALL")" "$(basename "$ROOTFS_TARBALL")" > SHA256SUMS.txt
  )

  say "Artifacts ready."
  say ""
}

###############################################################################
# Main
###############################################################################

main() {
  # Argument parsing
  for arg in "$@"; do
    case "$arg" in
      --yes) ASSUME_YES="true" ;;
      -h|--help)
        sed -n '/^# Usage:/,/^###/p' "$0" | grep '^#' | sed 's/^# \?//'
        exit 0
        ;;
      *) die "Unknown argument: ${arg}\nRun with --help for usage." ;;
    esac
  done

  need_cmd tar
  need_cmd lsusb
  need_cmd tee
  need_cmd grep
  need_cmd sed
  need_cmd wc
  need_cmd tr
  need_cmd find

  # Download NVIDIA artifacts if missing (includes license gate).
  fetch_artifacts

  # Initrd flashing uses IPv6 (fc00:1:1::/48) over usb0; refuse if host disabled IPv6.
  if [[ -f /proc/sys/net/ipv6/conf/all/disable_ipv6 ]]; then
    if [[ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6)" != "0" ]]; then
      die "IPv6 is disabled on this host. Enable IPv6, then re-run."
    fi
  fi

  # Ensure exactly ONE Jetson is in recovery.
  local apx_count
  apx_count="$(detect_apx_count)"
  if [[ "$apx_count" -eq 0 ]]; then
    die "No Jetson detected in recovery (APX) mode over USB. Put the Jetson in Force Recovery Mode and connect USB."
  fi
  if [[ "$apx_count" -ne 1 ]]; then
    die "Found ${apx_count} Jetsons in recovery mode. Unplug all but ONE to avoid flashing the wrong device."
  fi

  # Sudo upfront so we don't get a password prompt mid-flash.
  sudo -v

  mkdir -p "$WORK_DIR" "$LOG_DIR"

  # Clean NFS export entries on entry AND on exit (success or failure).
  cleanup_stale_exports
  trap cleanup_stale_exports EXIT

  # Always start from a clean Linux_for_Tegra tree (prevents stale/half-generated flash states).
  if [[ -d "$L4T_DIR" ]]; then
    say "Removing existing ${L4T_DIR} (clean run)..."
    safe_rm_rf "$L4T_DIR"
  fi

  say "Extracting BSP -> ${WORK_DIR}"
  tar xpf "$JETSON_TARBALL" -C "$WORK_DIR"
  [[ -d "$L4T_DIR" ]] || die "Extraction failed: ${L4T_DIR} not found"

  cd "$L4T_DIR"

  # Discover cfg files now that the BSP is extracted.
  # Doing this early means we fail fast with a clear message if NVIDIA ever moves them again.
  local QSPI_CFG NVME_XML
  QSPI_CFG="$(resolve_qspi_cfg)" \
    || die "Could not find flash_t234_qspi*.xml under ${L4T_DIR}/bootloader — check your BSP tarball."
  NVME_XML="$(resolve_nvme_xml)" \
    || die "Could not find flash_l4t_t234_nvme*.xml under ${L4T_DIR}/tools/kernel_flash — check your BSP tarball."

  say "Using QSPI cfg : ${QSPI_CFG}"
  say "Using NVMe xml : ${NVME_XML}"

  say "Preparing rootfs..."
  sudo rm -rf rootfs
  sudo mkdir -p rootfs
  sudo tar xpf "$ROOTFS_TARBALL" -C rootfs

  say "Applying NVIDIA binaries..."
  sudo ./apply_binaries.sh |& tee "$LOG_DIR/apply_binaries_${L4T_RELEASE}.log"

  # Only run NVIDIA prereq installer if something key is missing (avoids random apt upgrades every run).
  local missing=()
  for c in sshpass exportfs rpcinfo mkfs.vfat gdisk parted cpio zstd xxd; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  if ((${#missing[@]})); then
    say "Host prerequisites missing: ${missing[*]}"
    say "Running NVIDIA prerequisites installer (may require internet the first time)..."
    sudo tools/l4t_flash_prerequisites.sh |& tee "$LOG_DIR/l4t_flash_prerequisites_${L4T_RELEASE}.log"
  else
    say "Host prerequisites look installed (skipping l4t_flash_prerequisites.sh)."
  fi

  say "Flashing using NVIDIA initrd workflow for Orin Nano + NVMe..."
  say "BOARD=${BOARD}"
  say "OS NVMe partition to be ERASED/Flashed: /dev/${TARGET_NVME_PART}"
  say "Logs: ${LOG_DIR}"

  # -p passes extra args to the inner flash.sh call (QSPI config).
  # -c provides the external (NVMe) partition layout for the initrd flash stage.
  sudo ./tools/kernel_flash/l4t_initrd_flash.sh \
    --showlogs \
    --network usb0 \
    --external-device "${EXTERNAL_DEVICE_PART}" \
    -c "${NVME_XML}" \
    -p "-c ${QSPI_CFG}" \
    "${BOARD}" "${TARGET_NVME_PART}" |& tee "$LOG_DIR/flash_${L4T_RELEASE}.log"

  say "Flash complete."
  say "Log file: ${LOG_DIR}/flash_${L4T_RELEASE}.log"
}

main "$@"
