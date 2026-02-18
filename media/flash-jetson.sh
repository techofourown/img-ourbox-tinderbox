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

# ---------- CHANGE 1: full NFS/RPC dependency set ----------

ensure_flash_deps() {
  local pkgs=(
    sshpass           # used by l4t_initrd_flash.sh for SSH over USB
    abootimg          # used to pack/unpack Android boot images
    libxml2-utils     # provides xmllint, used to parse flash XMLs
    zstd              # used to decompress initrd payloads
    android-sdk-libsparse-utils  # provides simg2img for sparse images
    nfs-kernel-server # NFS server for rootfs streaming to Jetson
    nfs-common        # NFS client utilities and RPC plumbing
    rpcbind           # RPC portmapper, required for NFS to function
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

# ---------- udev rule for USB Ethernet gadget ----------

# The NVIDIA initrd flash tool creates a USB Ethernet gadget (RNDIS)
# named "usb0" for the host<->Jetson link.  Ubuntu's Predictable Network
# Interface Names renames it to "enx<mac>", which silently breaks the
# tool's IPv6/NFS setup.  This udev rule keeps the interface as "usb0".
ensure_usb0_udev_rule() {
  local rule_file="/etc/udev/rules.d/99-usb0-jetson.rules"
  local rule='SUBSYSTEM=="net", ACTION=="add", DRIVERS=="rndis_host", NAME="usb0"'

  if [[ -f "${rule_file}" ]] && grep -qF 'rndis_host' "${rule_file}"; then
    return 0
  fi

  note "Installing udev rule to keep USB Ethernet gadget named usb0"
  echo "${rule}" > "${rule_file}"
  udevadm control --reload-rules
  udevadm trigger --subsystem-match=net
  note "udev rule installed: ${rule_file}"
}

# ---------- CHANGE 2: force NFS/RPC into known-good state ----------

preflight_nfs_rpc_or_die() {
  note "Ensuring NFS/RPC services are running"
  systemctl enable --now rpcbind 2>/dev/null || true
  systemctl enable --now nfs-kernel-server 2>/dev/null || true
  systemctl restart rpcbind nfs-kernel-server || die "Failed to restart NFS/RPC services."

  exportfs -ra 2>/dev/null || true
  note "Current NFS exports:"
  exportfs -v 2>/dev/null || echo "  (none — the flash tool will add them dynamically)"
  note "NFS/RPC preflight OK"
}

# ---------- CHANGE 3: hard-block VPN interference ----------

preflight_no_vpn_or_die() {
  local vpn_ifaces=("tun0" "tun1" "wg0" "wg1" "tailscale0" "ppp0")
  local iface

  for iface in "${vpn_ifaces[@]}"; do
    if ip link show "${iface}" 2>/dev/null | grep -q 'state UP'; then
      die "VPN interface ${iface} is UP. Disconnect VPN and retry.\n\nInitrd flash uses NFS over usb0 (IPv6 fc00::). VPN commonly breaks routing/firewalling for this link."
    fi
  done

  # ZeroTier uses randomized interface names — check by driver
  local zt_iface
  zt_iface="$(ip link show 2>/dev/null | grep -oP '(?<=: )zt[a-z0-9]+(?=:)' || true)"
  if [[ -n "${zt_iface}" ]]; then
    if ip link show "${zt_iface}" 2>/dev/null | grep -q 'state UP\|state UNKNOWN'; then
      warn "ZeroTier interface ${zt_iface} is active."
      warn "ZeroTier can interfere with IPv6 routing for the USB flash link."
      warn "Stopping ZeroTier for the duration of the flash..."
      systemctl stop zerotier-one 2>/dev/null || true
      ZT_WAS_STOPPED=1
      note "ZeroTier stopped. Will restart on exit."
    fi
  fi
}

# ---------- CHANGE 4: neutralize host firewall during flash ----------

UFW_WAS_ACTIVE=0
FIREWALLD_WAS_ACTIVE=0
ZT_WAS_STOPPED=0
FLASH_WORK_DIR=""

# ---------- local staging to eliminate USB bus contention ----------

# The Linux_for_Tegra directory lives on the USB installer stick.
# The NFS server must serve system.img from that same USB stick OVER the
# USB Ethernet gadget (RNDIS).  Both paths share the USB host controller,
# causing bus contention that stalls NFS reads indefinitely (hard-mount
# hangs for many hours until killed).
#
# Fix: rsync Linux_for_Tegra to local disk before flashing so the NFS
# server reads from the local NVMe, not the USB stick.
stage_l4t_to_local_disk() {
  local source_l4t="$1"

  # Prefer /var/tmp (main NVMe, survives reboot) over /tmp (tmpfs, small)
  FLASH_WORK_DIR="$(mktemp -d /var/tmp/tinderbox-flash.XXXXXX)"
  local dest="${FLASH_WORK_DIR}/Linux_for_Tegra"

  # Sanity check: enough free space? (L4T + rootfs can be 10-20 GB)
  local avail_kb
  avail_kb="$(df --output=avail /var/tmp | tail -1)"
  local src_kb
  src_kb="$(du -sk "${source_l4t}" 2>/dev/null | cut -f1)"
  if (( src_kb > avail_kb )); then
    die "Not enough space in /var/tmp: need ~$((src_kb/1024))MB, have $((avail_kb/1024))MB.\nFree disk space and retry."
  fi

  bold "Staging Linux_for_Tegra to local disk (eliminates USB bus contention)"
  note "Source : ${source_l4t}"
  note "Dest   : ${dest}"
  note "Size   : ~$((src_kb/1024))MB — this may take a few minutes..."
  rsync -a --info=progress2 "${source_l4t}/" "${dest}/"
  note "Staging complete."
}

temporarily_disable_firewall() {
  # ufw
  if command -v ufw >/dev/null 2>&1; then
    if ufw status 2>/dev/null | grep -q 'Status: active'; then
      warn "Disabling ufw for the duration of the flash (NFS/RPC needs open ports)"
      ufw disable || true
      UFW_WAS_ACTIVE=1
    fi
  fi

  # firewalld
  if command -v firewall-cmd >/dev/null 2>&1; then
    if systemctl is-active --quiet firewalld 2>/dev/null; then
      warn "Stopping firewalld for the duration of the flash"
      systemctl stop firewalld || true
      FIREWALLD_WAS_ACTIVE=1
    fi
  fi
}

restore_env() {
  if [[ "${UFW_WAS_ACTIVE}" -eq 1 ]]; then
    note "Re-enabling ufw"
    ufw --force enable 2>/dev/null || true
  fi
  if [[ "${FIREWALLD_WAS_ACTIVE}" -eq 1 ]]; then
    note "Restarting firewalld"
    systemctl start firewalld 2>/dev/null || true
  fi
  if [[ "${ZT_WAS_STOPPED}" -eq 1 ]]; then
    note "Restarting ZeroTier"
    systemctl start zerotier-one 2>/dev/null || true
  fi
  if [[ -n "${FLASH_WORK_DIR}" && -d "${FLASH_WORK_DIR}" ]]; then
    note "Removing local flash staging dir: ${FLASH_WORK_DIR}"
    rm -rf "${FLASH_WORK_DIR}"
  fi
}

trap restore_env EXIT

# ---------- CHANGE 6: log capture and diagnostics ----------

LOG_DIR="${HERE}/flash-logs"

dump_failure_diagnostics() {
  local log_file="$1"

  bold "FLASH FAILED"
  echo
  echo "Log file: ${log_file}"
  echo
  bold "Last 50 lines of flash log:"
  tail -50 "${log_file}" 2>/dev/null || true
  echo
  bold "Host diagnostic snapshot:"
  echo "--- NFS/RPC status ---"
  systemctl --no-pager -l status rpcbind nfs-kernel-server 2>/dev/null || true
  echo "--- NFS exports ---"
  exportfs -v 2>/dev/null || true
  echo "--- ufw ---"
  ufw status 2>/dev/null || echo "(ufw not installed)"
  echo "--- network interfaces ---"
  ip addr show 2>/dev/null || true
  echo "--- IPv6 routes ---"
  ip -6 route show 2>/dev/null || true
  echo "--- USB devices ---"
  lsusb 2>/dev/null | grep -i nvidia || echo "(no NVIDIA USB devices)"
  echo
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
ensure_usb0_udev_rule
preflight_nfs_rpc_or_die
preflight_no_vpn_or_die
temporarily_disable_firewall

L4T_SOURCE="${HERE}/Linux_for_Tegra"
[[ -d "${L4T_SOURCE}" ]] || die "Missing Linux_for_Tegra directory next to this script. Did you run tools/prepare-installer-media.sh?"

# Stage to local disk — must happen before Jetson detection prompts so the
# user can plug in the Jetson AFTER the (potentially slow) copy is done.
stage_l4t_to_local_disk "${L4T_SOURCE}"
L4T_DIR="${FLASH_WORK_DIR}/Linux_for_Tegra"

FLASH_TOOL="${L4T_DIR}/tools/kernel_flash/l4t_initrd_flash.sh"
[[ -x "${FLASH_TOOL}" ]] || die "Missing initrd flash tool: ${FLASH_TOOL}"

detect_jetson_recovery() {
  local ids=() matches=() id
  mapfile -t ids < <(lsusb | awk '/0955:/{print $6}' | sort -u)
  for id in "${ids[@]}"; do
    case "$id" in
      0955:7323|0955:7423) matches+=("$id") ;;
    esac
  done
  JETSON_MATCHES=("${matches[@]+"${matches[@]}"}")
}

note "Waiting for Jetson in Force Recovery Mode (USB id 0955:7323 or 0955:7423)"
echo "  To enter Force Recovery: hold RECOVERY button, press RESET (or power on), release RECOVERY."
echo

JETSON_MATCHES=()
while true; do
  detect_jetson_recovery

  if [[ "${#JETSON_MATCHES[@]}" -gt 1 ]]; then
    die "More than one supported Jetson detected (${JETSON_MATCHES[*]}). This tool is single-device."
  fi

  if [[ "${#JETSON_MATCHES[@]}" -eq 1 ]]; then
    case "${JETSON_MATCHES[0]}" in
      0955:7323) note "Detected: Jetson Orin NX 16GB (0955:7323)" ;;
      0955:7423) note "Detected: Jetson Orin NX 8GB (0955:7423)" ;;
    esac
    break
  fi

  echo "  No supported Jetson found yet."
  echo "  Current NVIDIA USB devices: $(lsusb | grep '0955:' | awk '{print $6}' | tr '\n' ' ' || echo '(none)')"
  read -r -p "  Press ENTER to rescan, or type q to quit: " _choice
  [[ "${_choice}" == "q" || "${_choice}" == "Q" ]] && die "operator quit"
done

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

mkdir -p "${LOG_DIR}"
FLASH_LOG="${LOG_DIR}/flash-$(date -u +'%Y%m%dT%H%M%SZ').log"
note "Flash log: ${FLASH_LOG}"

pushd "${L4T_DIR}" >/dev/null

# CHANGE 5: inhibit sleep/shutdown on laptops during flash
FLASH_CMD=(
  ./tools/kernel_flash/l4t_initrd_flash.sh
  --external-device "${OS_PART}"
  -c tools/kernel_flash/flash_l4t_t234_nvme.xml
  -p "-c bootloader/generic/cfg/flash_t234_qspi.xml"
  --showlogs --network usb0
  jetson-orin-nano-devkit internal
)

flash_rc=0
if command -v systemd-inhibit >/dev/null 2>&1; then
  systemd-inhibit \
    --what=sleep:shutdown:idle \
    --mode=block \
    --why="Jetson flashing (NFS over USB)" \
    "${FLASH_CMD[@]}" 2>&1 | tee "${FLASH_LOG}" || flash_rc=$?
else
  "${FLASH_CMD[@]}" 2>&1 | tee "${FLASH_LOG}" || flash_rc=$?
fi

popd >/dev/null

if [[ "${flash_rc}" -ne 0 ]]; then
  dump_failure_diagnostics "${FLASH_LOG}"
  die "Flash failed with exit code ${flash_rc}. See diagnostics above and log: ${FLASH_LOG}"
fi

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
