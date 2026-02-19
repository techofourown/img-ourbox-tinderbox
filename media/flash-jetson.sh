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
    ethtool           # used to disable offloads on usb0 for stability
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

ensure_usb0_offload_udev_rule() {
  # Must sort AFTER rename rule (99-usb0-jetson.rules), so use zz suffix.
  local rule_file="/etc/udev/rules.d/99-zz-usb0-jetson-offloads.rules"

  # Disable offloads that commonly break NFS over USB gadget NICs.
  # Use a helper script so udev RUN isn't a giant one-liner.
  local helper="/usr/local/sbin/tinderbox-usb0-offloads.sh"

  if [[ ! -x "${helper}" ]]; then
    cat > "${helper}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

IFACE="${1:-usb0}"

# udev can fire before the interface is fully ready; give it a moment.
for _ in {1..20}; do
  ip link show "${IFACE}" >/dev/null 2>&1 && break
  sleep 0.1
done

# Bring link up and make it boring/stable.
ip link set "${IFACE}" up || true
ip link set "${IFACE}" mtu 1500 || true

# Disable problematic offloads (critical).
if command -v ethtool >/dev/null 2>&1; then
  ethtool -K "${IFACE}" tso off gso off gro off lro off tx off rx off sg off 2>/dev/null || true
  ethtool -K "${IFACE}" tx-checksum-ip-generic off rx-checksum off 2>/dev/null || true
fi

# Increase queue length a bit; helps sustained streams.
ip link set "${IFACE}" txqueuelen 1000 2>/dev/null || true

exit 0
EOF
    chmod 0755 "${helper}"
  fi

  # udev rule: run helper when usb0 appears, for multiple possible drivers
  # (Jetson gadget can show as rndis_host, cdc_ether, cdc_ncm depending on host/kernel).
  local rule='SUBSYSTEM=="net", ACTION=="add", NAME=="usb0", RUN+="/usr/local/sbin/tinderbox-usb0-offloads.sh usb0"'

  if [[ -f "${rule_file}" ]] && grep -qF 'tinderbox-usb0-offloads' "${rule_file}"; then
    return 0
  fi

  note "Installing udev rule to disable offloads on usb0 (stabilizes NFS over USB)"
  echo "${rule}" > "${rule_file}"
  udevadm control --reload-rules
  note "udev rule installed: ${rule_file}"
}

find_usb_net_iface() {
  if ip link show usb0 >/dev/null 2>&1; then
    echo "usb0"
    return 0
  fi

  ip -o link show | awk -F': ' '{print $2}' | grep -E '^enx' | head -n1 || true
}

apply_usb_offloads_now() {
  # Safety net: if udev ordering/race skipped RUN action, apply explicitly now.
  local iface
  iface="$(find_usb_net_iface)"
  [[ -n "${iface}" ]] || { warn "No usb0/enx interface found yet; cannot apply offload settings now."; return 0; }

  note "Applying USB NIC stability settings immediately on ${iface}"
  ip link set "${iface}" up 2>/dev/null || true
  ip link set "${iface}" mtu 1500 2>/dev/null || true
  if command -v ethtool >/dev/null 2>&1; then
    ethtool -K "${iface}" tso off gso off gro off lro off tx off rx off sg off 2>/dev/null || true
    ethtool -K "${iface}" tx-checksum-ip-generic off rx-checksum off 2>/dev/null || true
  fi
  ip link set "${iface}" txqueuelen 1000 2>/dev/null || true
}

wait_for_target_ssh() {
  local timeout_s="${1:-180}"
  local i

  for (( i=0; i<timeout_s; i++ )); do
    if sshpass -p root ssh -6 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=2 root@fc00:1:1:0::2 'echo ok' >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done

  return 1
}

nfs_pre_untar_probe_or_die() {
  note "Running pre-untar probe from target: /mnt/external/system.img readability"
  wait_for_target_ssh 180 || die "Target SSH (fc00:1:1:0::2) not reachable before APP untar stage."
  sshpass -p root ssh -6 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    root@fc00:1:1:0::2 "set -e; test -r /mnt/external/system.img; ls -lh /mnt/external/system.img; dd if=/mnt/external/system.img of=/dev/null bs=4M count=4 status=none" \
    || die "Pre-untar probe failed: target could not reliably read /mnt/external/system.img"
  note "Pre-untar probe OK"
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
NM_WAS_ACTIVE=0
TLP_WAS_ACTIVE=0
USB_AUTOSUSPEND_PREV=""
WATCHDOG_PID=""
WATCHDOG_ABORT_REASON_FILE=""

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

temporarily_disable_nm_and_usb_autosuspend() {
  # NetworkManager can reconfigure usb0 mid-flash and kill the fc00:: link.
  if systemctl is-active --quiet NetworkManager 2>/dev/null; then
    warn "Stopping NetworkManager for the duration of the flash (prevents usb0 interference)"
    systemctl stop NetworkManager || true
    NM_WAS_ACTIVE=1
  fi

  # TLP (if present) frequently autosuspends USB devices mid-transfer.
  if systemctl is-active --quiet tlp 2>/dev/null; then
    warn "Stopping tlp for the duration of the flash (prevents USB autosuspend)"
    systemctl stop tlp || true
    TLP_WAS_ACTIVE=1
  fi

  # Disable kernel USB autosuspend globally for the flash run.
  if [[ -w /sys/module/usbcore/parameters/autosuspend ]]; then
    USB_AUTOSUSPEND_PREV="$(cat /sys/module/usbcore/parameters/autosuspend 2>/dev/null || true)"
    echo -1 > /sys/module/usbcore/parameters/autosuspend || true
    note "usbcore.autosuspend set to -1 for the flash run"
  fi
}

restore_env() {
  # Restore USB autosuspend value
  if [[ -n "${USB_AUTOSUSPEND_PREV}" && -w /sys/module/usbcore/parameters/autosuspend ]]; then
    echo "${USB_AUTOSUSPEND_PREV}" > /sys/module/usbcore/parameters/autosuspend || true
  fi

  if [[ "${TLP_WAS_ACTIVE}" -eq 1 ]]; then
    note "Restarting tlp"
    systemctl start tlp 2>/dev/null || true
  fi

  if [[ "${NM_WAS_ACTIVE}" -eq 1 ]]; then
    note "Restarting NetworkManager"
    systemctl start NetworkManager 2>/dev/null || true
  fi

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

  if [[ -n "${WATCHDOG_PID}" ]]; then
    kill "${WATCHDOG_PID}" 2>/dev/null || true
  fi
  if [[ -n "${WATCHDOG_ABORT_REASON_FILE}" && -f "${WATCHDOG_ABORT_REASON_FILE}" ]]; then
    rm -f "${WATCHDOG_ABORT_REASON_FILE}" 2>/dev/null || true
  fi

  # Copy logs back onto the installer USB if it's still present
  if [[ -d "${HERE}" ]]; then
    mkdir -p "${HERE}/flash-logs"
    rsync -a "${LOG_DIR}/" "${HERE}/flash-logs/" 2>/dev/null || true
  fi

  if [[ -n "${FLASH_WORK_DIR}" && -d "${FLASH_WORK_DIR}" ]]; then
    note "Removing local flash staging dir: ${FLASH_WORK_DIR}"
    rm -rf "${FLASH_WORK_DIR}"
  fi
}

trap restore_env EXIT

# ---------- CHANGE 6: log capture and diagnostics ----------

LOG_DIR="/var/tmp/tinderbox-flash-logs"
mkdir -p "${LOG_DIR}"

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
  echo "--- kernel: recent USB events ---"
  dmesg -T 2>/dev/null | tail -200 | grep -iE 'usb|xhci|rndis|cdc_ether|cdc_ncm|disconnect|reset' || true
  echo
}

start_flash_watchdog() {
  local flash_pid="$1"
  local flash_log="$2"
  WATCHDOG_ABORT_REASON_FILE="$(mktemp /tmp/tinderbox-watchdog-reason.XXXXXX)"
  : > "${WATCHDOG_ABORT_REASON_FILE}"

  (
    set +e
    local iface missing_usb=0 missing_net=0 preprobe_done=0
    while kill -0 "${flash_pid}" 2>/dev/null; do
      # 1) Detect transition into APP untar stage, then force a read probe from target.
      if [[ "${preprobe_done}" -eq 0 ]] && grep -q "tar .* -x -I 'zstd -T0' -pf /mnt/external/system.img" "${flash_log}" 2>/dev/null; then
        preprobe_done=1
        if ! nfs_pre_untar_probe_or_die; then
          echo "watchdog: pre-untar probe failed (/mnt/external/system.img unreadable on target)" > "${WATCHDOG_ABORT_REASON_FILE}"
          kill "${flash_pid}" 2>/dev/null || true
          exit 0
        fi
      fi

      # 2) Jetson presence watchdog (APX/recovery USB device should remain visible through flash phases)
      if lsusb | grep -qi '0955:'; then
        missing_usb=0
      else
        missing_usb=$((missing_usb+1))
      fi

      # 3) USB NIC watchdog
      iface="$(find_usb_net_iface)"
      if [[ -n "${iface}" ]]; then
        missing_net=0
      else
        missing_net=$((missing_net+1))
      fi

      # Give brief grace period (3 checks * 2s = ~6s) to avoid false positives on reboot boundary.
      if (( missing_usb >= 3 )); then
        echo "watchdog: Jetson USB device disappeared (no 0955:* in lsusb for ~6s)" > "${WATCHDOG_ABORT_REASON_FILE}"
        kill "${flash_pid}" 2>/dev/null || true
        exit 0
      fi
      if (( missing_net >= 3 )); then
        echo "watchdog: Jetson USB NIC disappeared (no usb0/enx for ~6s)" > "${WATCHDOG_ABORT_REASON_FILE}"
        kill "${flash_pid}" 2>/dev/null || true
        exit 0
      fi

      sleep 2
    done
  ) &
  WATCHDOG_PID="$!"
}

run_flash_with_watchdog() {
  local flash_log="$1"
  shift
  local -a cmd=( "$@" )

  local flash_rc=0
  # Keep tee logging, but make command PID trackable for watchdog.
  (
    "${cmd[@]}"
  ) > >(tee "${flash_log}") 2>&1 &
  local flash_pid=$!

  start_flash_watchdog "${flash_pid}" "${flash_log}"
  wait "${flash_pid}" || flash_rc=$?

  if [[ -n "${WATCHDOG_PID}" ]]; then
    kill "${WATCHDOG_PID}" 2>/dev/null || true
    WATCHDOG_PID=""
  fi

  if [[ -n "${WATCHDOG_ABORT_REASON_FILE}" && -s "${WATCHDOG_ABORT_REASON_FILE}" ]]; then
    warn "$(cat "${WATCHDOG_ABORT_REASON_FILE}")"
    # Preserve original non-zero if already failed; else force failure due to watchdog abort.
    [[ "${flash_rc}" -ne 0 ]] || flash_rc=99
  fi

  return "${flash_rc}"
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
ensure_usb0_offload_udev_rule
preflight_nfs_rpc_or_die

# Explicit safety-net in case udev RUN did not fire after rename.
apply_usb_offloads_now

preflight_no_vpn_or_die
temporarily_disable_firewall
temporarily_disable_nm_and_usb_autosuspend

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
  run_flash_with_watchdog "${FLASH_LOG}" \
    systemd-inhibit \
      --what=sleep:shutdown:idle \
      --mode=block \
      --why="Jetson flashing (NFS over USB)" \
      "${FLASH_CMD[@]}" || flash_rc=$?
else
  run_flash_with_watchdog "${FLASH_LOG}" \
    "${FLASH_CMD[@]}" || flash_rc=$?
fi

popd >/dev/null

if [[ "${flash_rc}" -ne 0 ]]; then
  [[ "${flash_rc}" -eq 99 ]] && warn "Flash aborted by watchdog due to transport/link failure."
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
