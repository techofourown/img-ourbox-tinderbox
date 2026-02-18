#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${HERE}/../tools/_common.sh" 2>/dev/null || true

# If run from the USB drive, tools/_common.sh won't exist at ../tools
# (because prepare-installer-media copies only media/ + Linux_for_Tegra).
# So provide tiny local fallbacks.
if ! command -v die >/dev/null 2>&1; then
  die(){ echo "[error] $*" >&2; exit 1; }
  note(){ echo "==> $*"; }
  warn(){ echo "[warn] $*" >&2; }
fi

require_root_local() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "Run as root: sudo $0"
  fi
}

require_cmd_local() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "Missing required command: $c"
  done
}

require_root_local
require_cmd_local lsusb awk sed grep cut

L4T_DIR="${HERE}/Linux_for_Tegra"
[[ -d "${L4T_DIR}" ]] || die "Missing Linux_for_Tegra directory next to this script. Did you run tools/prepare-installer-media.sh?"

FLASH_TOOL="${L4T_DIR}/tools/kernel_flash/l4t_initrd_flash.sh"
[[ -x "${FLASH_TOOL}" ]] || die "Missing initrd flash tool: ${FLASH_TOOL}"

note "Checking for Jetson in Force Recovery Mode (USB id 0955:XXXX)"
mapfile -t ids < <(lsusb | awk '/0955:/{print $6}' | sort -u)

# Keep only the ones we care about
matches=()
for id in "${ids[@]}"; do
  case "$id" in
    0955:7323|0955:7423) matches+=("$id") ;;
    0955:*) ;;
  esac
done

if [[ "${#matches[@]}" -eq 0 ]]; then
  die "No supported Jetson Orin NX detected in Force Recovery.\nExpected lsusb to show 0955:7323 (NX16) or 0955:7423 (NX8)."
fi
if [[ "${#matches[@]}" -gt 1 ]]; then
  die "More than one supported Jetson detected (${matches[*]}). This tool is single-device on purpose."
fi

case "${matches[0]}" in
  0955:7323) note "Detected: Jetson Orin NX 16GB (0955:7323)" ;;
  0955:7423) note "Detected: Jetson Orin NX 8GB (0955:7423)" ;;
esac

# Defaults
# shellcheck disable=SC1090
if [[ -f "${HERE}/defaults.env" ]]; then
  source "${HERE}/defaults.env"
fi
OS_DEFAULT="${TINDERBOX_OS_NVME_DEFAULT:-nvme0n1}"
DATA_DEFAULT="${TINDERBOX_DATA_NVME_DEFAULT:-nvme1n1}"

echo
note "NVMe selection"
echo "You have two NVMe devices installed."
echo "Pick which one is the OS drive. The other becomes DATA at /data on first boot."
echo

read -r -p "OS NVMe device [${OS_DEFAULT}] (nvme0n1 or nvme1n1): " OS_NVME
OS_NVME="${OS_NVME:-${OS_DEFAULT}}"
[[ "${OS_NVME}" =~ ^nvme[0-9]+n1$ ]] || die "Invalid OS NVMe name: ${OS_NVME}"

read -r -p "DATA NVMe device [${DATA_DEFAULT}] (nvme0n1 or nvme1n1): " DATA_NVME
DATA_NVME="${DATA_NVME:-${DATA_DEFAULT}}"
[[ "${DATA_NVME}" =~ ^nvme[0-9]+n1$ ]] || die "Invalid DATA NVMe name: ${DATA_NVME}"

if [[ "${OS_NVME}" == "${DATA_NVME}" ]]; then
  die "OS NVMe and DATA NVMe cannot be the same device."
fi

echo
echo "Summary:"
echo "  OS NVMe:   /dev/${OS_NVME} (will be erased)"
echo "  DATA NVMe: /dev/${DATA_NVME} (will NOT be touched by flashing; formatted on first boot)"
echo
read -r -p "Type YES to flash the OS NVMe now: " ans
[[ "${ans}" == "YES" ]] || die "Aborted."

OS_PART="${OS_NVME}p1"

note "Flashing QSPI + OS NVMe using initrd flash (no GUI)."
note "This can take a while. Do not unplug until it completes."
echo

pushd "${L4T_DIR}" >/dev/null

# Based on NVIDIA Quick Start for Jetson Linux R36.5 (Orin Nano Dev Kit config).
# We intentionally DO NOT use the '-super' configuration.
./tools/kernel_flash/l4t_initrd_flash.sh \
  --external-device "${OS_PART}" \
  -c tools/kernel_flash/flash_l4t_t234_nvme.xml \
  -p "-c bootloader/generic/cfg/flash_t234_qspi.xml" \
  --showlogs --network usb0 \
  jetson-orin-nano-devkit internal

popd >/dev/null

echo
note "Flash complete."
echo "Next:"
echo "  1) Take the Jetson out of Force Recovery mode"
echo "  2) Power-cycle it"
echo "  3) Remove any temporary media/cables you don't want"
echo "  4) Boot from the OS NVMe"
echo
echo "On first boot:"
echo "  - 'ourbox-hello' prints Hello World to console/journal"
echo "  - 'ourbox-firstboot' will format & mount the DATA NVMe at /data"
