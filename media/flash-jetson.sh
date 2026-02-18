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
  bold(){ printf "\033[1m%s\033[0m\n" "$*"; }
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

# Install all packages the NVIDIA flash tool needs upfront so the user
# isn't interrupted mid-flash with a missing-binary error.
ensure_flash_deps() {
  local pkgs=(
    sshpass           # used by l4t_initrd_flash.sh for SSH over USB
    abootimg          # used to pack/unpack Android boot images
    libxml2-utils     # provides xmllint, used to parse flash XMLs
    zstd              # used to decompress initrd payloads
    android-sdk-libsparse-utils  # provides simg2img for sparse images
    nfs-kernel-server # used by the flash tool's NFS network mode
  )

  local missing=()
  local pkg
  for pkg in "${pkgs[@]}"; do
    dpkg -s "${pkg}" >/dev/null 2>&1 || missing+=("${pkg}")
  done

  if [[ "${#missing[@]}" -eq 0 ]]; then
    return 0
  fi

  note "Installing missing flash dependencies: ${missing[*]}"
  if ! command -v apt-get >/dev/null 2>&1; then
    die "apt-get not available. Install these packages manually and retry: ${missing[*]}"
  fi
  apt-get install -y "${missing[@]}" || die "Failed to install flash dependencies."
  note "Flash dependencies installed."
}

# ---------- NVMe selection ----------

# The Jetson's internal NVMe drives are not visible to the host as block
# devices when the Jetson is in Force Recovery mode. Device names like
# nvme0n1/nvme1n1 refer to drives as seen from the Jetson internally.
#
# To identify which is which BEFORE entering recovery mode, boot the
# Jetson normally and run:
#   lsblk -o NAME,SIZE,MODEL,SERIAL /dev/nvme*n1

show_nvme_table() {
  local os_default="$1"
  local -a candidates=("nvme0n1" "nvme1n1")
  local idx dev role

  echo
  echo "  Note: drive sizes/models are not readable from the host while the Jetson"
  echo "  is in Force Recovery mode. To identify drives beforehand, boot normally"
  echo "  and run: lsblk -o NAME,SIZE,MODEL,SERIAL /dev/nvme*n1"
  echo
  printf '  %-4s %-16s %s\n' "#" "Device" "Configured default role"
  printf '  %-4s %-16s %s\n' "---" "---------------" "----------------------"
  for idx in "${!candidates[@]}"; do
    dev="${candidates[$idx]}"
    if [[ "${dev}" == "${os_default}" ]]; then
      role="OS  — will be ERASED and flashed  [default]"
    else
      role="DATA — preserved; formatted on first boot [default]"
    fi
    printf '  %-4s %-16s %s\n' "$((idx + 1))" "/dev/${dev}" "${role}"
  done
  echo
}

select_nvme_interactive() {
  local os_default="$1"
  local -a candidates=("nvme0n1" "nvme1n1")
  local choice idx dev confirm

  while true; do
    show_nvme_table "${os_default}"
    read -r -p "Select OS NVMe number or name [${os_default}]: " choice
    choice="${choice:-${os_default}}"

    # Accept 1/2 (numbered) or a device name directly
    if [[ "${choice}" =~ ^[0-9]+$ ]]; then
      idx="$((choice - 1))"
      (( idx >= 0 && idx < ${#candidates[@]} )) || { warn "out of range: ${choice}"; continue; }
      OS_NVME="${candidates[$idx]}"
    elif [[ "${choice}" =~ ^nvme[0-9]+n1$ ]]; then
      OS_NVME="${choice}"
    else
      warn "invalid: ${choice} — enter 1, 2, or a device name like nvme0n1"
      continue
    fi

    # Auto-derive DATA as the other slot (2-slot Jetson config)
    DATA_NVME=""
    for dev in "${candidates[@]}"; do
      [[ "${dev}" != "${OS_NVME}" ]] && DATA_NVME="${dev}"
    done
    [[ -n "${DATA_NVME}" ]] || die "Could not determine DATA NVMe."

    echo
    echo "  OS   NVMe: /dev/${OS_NVME}  — will be ERASED and flashed"
    echo "  DATA NVMe: /dev/${DATA_NVME} — will NOT be touched; formatted on first boot"
    echo
    read -r -p "Type CONFIRM to accept, or press ENTER to re-select: " confirm
    [[ "${confirm}" == "CONFIRM" ]] || { note "re-selecting..."; continue; }
    return 0
  done
}

# ---------- main ----------

require_root_local
require_cmd_local lsusb awk sed grep cut
ensure_flash_deps

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

# Load defaults
# shellcheck disable=SC1090
if [[ -f "${HERE}/defaults.env" ]]; then
  source "${HERE}/defaults.env"
fi
OS_DEFAULT="${TINDERBOX_OS_NVME_DEFAULT:-nvme0n1}"

echo
note "NVMe selection"
echo "Pick which internal NVMe will be the OS drive. The other becomes DATA (/data on first boot)."

OS_NVME=""
DATA_NVME=""
select_nvme_interactive "${OS_DEFAULT}"
# OS_NVME and DATA_NVME are now set

echo
bold "DANGER ZONE"
echo "  OS   NVMe: /dev/${OS_NVME}  — will be ERASED"
echo "  DATA NVMe: /dev/${DATA_NVME} — will NOT be touched"
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
