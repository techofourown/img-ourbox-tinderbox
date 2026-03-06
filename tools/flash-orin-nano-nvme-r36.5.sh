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
#   sudo ./tools/flash-orin-nano-nvme-r36.5.sh [--yes] [--diagnose]
#
#   --yes       Skip the interactive NVIDIA license confirmation (for CI/automation).
#               By accepting this flag you confirm you have read and agreed to
#               NVIDIA's Jetson Linux software license.
#
#   --diagnose  Boot the Jetson into initrd (no flash) and run a diagnostic suite
#               over SSH.  Use this to inspect watchdog state, thermals, memory,
#               NVMe health, and dmesg BEFORE committing to a full flash.
#               In normal flash mode, telemetry is also injected automatically.
#
#   --no-cache  Force re-extraction of the BSP and rootfs even if they are
#               already cached from a previous run.  Use this if you suspect
#               the workspace is stale or if you've replaced the tarballs.
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

# Cache stamp files — live in $WORK_DIR (outside $L4T_DIR) so they survive
# safe_rm_rf "$L4T_DIR" between runs.
STAMP_BSP="${WORK_DIR}/.stamp-bsp"
STAMP_ROOTFS="${WORK_DIR}/.stamp-rootfs"
NO_CACHE="false"

# Populated by --yes flag or read from defaults.env below.
ASSUME_YES="false"

# State saved by harden_usb_for_flash / restored by restore_flash_env.
_NM_WAS_ACTIVE=0
_TLP_WAS_ACTIVE=0
_USB_AUTOSUSPEND_PREV=""

# Load repo defaults (URLs etc.) if present — never fatal if absent, we have fallbacks.
_DEFAULTS_ENV="${REPO_ROOT}/config/defaults.env"
if [[ -f "$_DEFAULTS_ENV" ]]; then
  # shellcheck disable=SC1090
  source "$_DEFAULTS_ENV"
fi

DEFAULT_INSTALLER_SSH_PASSWORD_HASH='$6$ourboxinstall$GgJGorVZ2X.yl0cQk8yIqYDawhEuB47d9m.k9t9HP1afvwC3ALmMxTDtKT2NjDBMqkUOVzvm7LK2ZHxBt2KxH1'
if [[ -z "${OURBOX_INSTALLER_SSH_MODE:-}" ]]; then
  case "$(printf '%s' "${OURBOX_VARIANT:-prod}" | tr '[:upper:]' '[:lower:]')" in
    dev|support|debug|diag|diagnostic|lab|labs) OURBOX_INSTALLER_SSH_MODE="both" ;;
    *) OURBOX_INSTALLER_SSH_MODE="key" ;;
  esac
fi
OURBOX_INSTALLER_SSH_USER="${OURBOX_INSTALLER_SSH_USER:-ourbox-installer}"
OURBOX_INSTALLER_SSH_PASSWORD_HASH="${OURBOX_INSTALLER_SSH_PASSWORD_HASH:-${DEFAULT_INSTALLER_SSH_PASSWORD_HASH}}"
OURBOX_INSTALLER_SSH_AUTHORIZED_KEYS="${OURBOX_INSTALLER_SSH_AUTHORIZED_KEYS:-}"
# Keep root/root automation available in initrd diagnose mode.
OURBOX_INSTALLER_SSH_ALLOW_ROOT="${OURBOX_INSTALLER_SSH_ALLOW_ROOT:-1}"
if [[ "${OURBOX_INSTALLER_SSH_ALLOW_ROOT}" != "1" ]]; then
  printf '%s\n' "WARNING: OURBOX_INSTALLER_SSH_ALLOW_ROOT=${OURBOX_INSTALLER_SSH_ALLOW_ROOT} is ignored in diagnose mode." >&2
  printf '%s\n' "         Root login remains required for machine automation on initrd." >&2
fi

###############################################################################
# Helpers
###############################################################################

say()  { printf '%s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

# Returns the SHA-256 hex digest of a file (first field only).
_sha256_of() { sha256sum "$1" | cut -d' ' -f1; }

# True if the BSP extraction is already valid for the current tarball.
_bsp_cache_valid() {
  [[ "$NO_CACHE" == "false" ]] || return 1
  [[ -f "$STAMP_BSP" ]]        || return 1
  [[ -d "$L4T_DIR" ]]          || return 1
  local expected; expected="$(_sha256_of "$JETSON_TARBALL")"
  [[ "$(cat "$STAMP_BSP")" == "$expected" ]]
}

_write_bsp_stamp()         { _sha256_of "$JETSON_TARBALL" > "$STAMP_BSP"; }
_invalidate_rootfs_stamp() { rm -f "$STAMP_ROOTFS"; }

# True if the rootfs overlay (apply_binaries.sh) is already valid for both tarballs.
_rootfs_cache_valid() {
  [[ "$NO_CACHE" == "false" ]]  || return 1
  [[ -f "$STAMP_ROOTFS" ]]      || return 1
  [[ -d "${L4T_DIR}/rootfs" ]]  || return 1
  local bsp_hash rootfs_hash expected
  bsp_hash="$(_sha256_of "$JETSON_TARBALL")"
  rootfs_hash="$(_sha256_of "$ROOTFS_TARBALL")"
  expected="${bsp_hash}:${rootfs_hash}"
  [[ "$(cat "$STAMP_ROOTFS")" == "$expected" ]]
}

_write_rootfs_stamp() {
  local bsp_hash rootfs_hash
  bsp_hash="$(_sha256_of "$JETSON_TARBALL")"
  rootfs_hash="$(_sha256_of "$ROOTFS_TARBALL")"
  printf '%s:%s\n' "$bsp_hash" "$rootfs_hash" > "$STAMP_ROOTFS"
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
# USB link stability
###############################################################################
#
# The NVIDIA initrd flash tool streams system.img (the rootfs) to the Jetson
# over NFS on a USB Ethernet gadget (RNDIS "usb0").  Several common host-side
# services silently kill this link mid-transfer:
#
#   - USB autosuspend: kernel suspends the USB device after idle timeout
#   - NetworkManager: reconfigures usb0, breaking the fc00:: IPv6 link
#   - TLP (laptops):  aggressively autosuspends USB devices
#   - NIC offloads:   TSO/GSO/GRO on USB gadget NICs corrupt NFS streams
#
# We disable all of these before flashing and restore them on exit.

harden_usb_for_flash() {
  say "USB stability: hardening host for sustained USB gadget transfer..."

  # 1. Disable kernel USB autosuspend globally.
  if [[ -w /sys/module/usbcore/parameters/autosuspend ]]; then
    _USB_AUTOSUSPEND_PREV="$(cat /sys/module/usbcore/parameters/autosuspend 2>/dev/null || true)"
    echo -1 | sudo tee /sys/module/usbcore/parameters/autosuspend >/dev/null
    say "  usbcore.autosuspend: disabled (was ${_USB_AUTOSUSPEND_PREV})"
  fi

  # 2. Stop NetworkManager — it reconfigures usb0 mid-flash and kills the link.
  if sudo systemctl is-active --quiet NetworkManager 2>/dev/null; then
    say "  NetworkManager: stopping for duration of flash..."
    sudo systemctl stop NetworkManager || true
    _NM_WAS_ACTIVE=1
  fi

  # 3. Stop TLP — it autosuspends USB devices on laptops.
  if sudo systemctl is-active --quiet tlp 2>/dev/null; then
    say "  TLP: stopping for duration of flash..."
    sudo systemctl stop tlp || true
    _TLP_WAS_ACTIVE=1
  fi

  # 4. Install udev rules so the gadget NIC stays named "usb0" and gets
  #    offloads disabled automatically when it appears.
  _install_usb0_udev_rules

  say "  USB hardening applied."
}

_install_usb0_udev_rules() {
  # Keep the USB gadget NIC named "usb0" (Ubuntu Predictable Names renames
  # it to "enx<mac>" which breaks NVIDIA's tool).
  local rename_rule="/etc/udev/rules.d/99-usb0-jetson.rules"
  if ! [[ -f "$rename_rule" ]] || ! grep -qF 'rndis_host' "$rename_rule" 2>/dev/null; then
    echo 'SUBSYSTEM=="net", ACTION=="add", DRIVERS=="rndis_host", NAME="usb0"' \
      | sudo tee "$rename_rule" >/dev/null
    sudo udevadm control --reload-rules
    say "  udev: installed usb0 rename rule"
  fi

  # Disable offloads that corrupt NFS over USB gadget NICs.
  local offload_helper="/usr/local/sbin/tinderbox-usb0-offloads.sh"
  if ! [[ -x "$offload_helper" ]]; then
    sudo tee "$offload_helper" >/dev/null <<'OFFLOAD_EOF'
#!/usr/bin/env bash
set -euo pipefail
IFACE="${1:-usb0}"
for _ in {1..20}; do
  ip link show "${IFACE}" >/dev/null 2>&1 && break
  sleep 0.1
done
ip link set "${IFACE}" up 2>/dev/null || true
ip link set "${IFACE}" mtu 1500 2>/dev/null || true
if command -v ethtool >/dev/null 2>&1; then
  ethtool -K "${IFACE}" tso off gso off gro off lro off tx off rx off sg off 2>/dev/null || true
  ethtool -K "${IFACE}" tx-checksum-ip-generic off rx-checksum off 2>/dev/null || true
fi
ip link set "${IFACE}" txqueuelen 1000 2>/dev/null || true
OFFLOAD_EOF
    sudo chmod 0755 "$offload_helper"
    say "  installed: ${offload_helper}"
  fi

  local offload_rule="/etc/udev/rules.d/99-zz-usb0-jetson-offloads.rules"
  if ! [[ -f "$offload_rule" ]] || ! grep -qF 'tinderbox-usb0-offloads' "$offload_rule" 2>/dev/null; then
    echo 'SUBSYSTEM=="net", ACTION=="add", NAME=="usb0", RUN+="/usr/local/sbin/tinderbox-usb0-offloads.sh usb0"' \
      | sudo tee "$offload_rule" >/dev/null
    sudo udevadm control --reload-rules
    say "  udev: installed usb0 offload rule"
  fi
}

# Apply USB NIC offload settings immediately (safety net if udev rule hasn't
# fired yet or if the interface was renamed before the rule was installed).
apply_usb_offloads_now() {
  local iface=""
  if ip link show usb0 >/dev/null 2>&1; then
    iface="usb0"
  else
    iface="$(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -E '^enx' | head -n1 || true)"
  fi
  [[ -n "$iface" ]] || return 0

  say "  Applying USB NIC offloads on ${iface} now..."
  sudo ip link set "$iface" up 2>/dev/null || true
  sudo ip link set "$iface" mtu 1500 2>/dev/null || true
  if command -v ethtool >/dev/null 2>&1; then
    sudo ethtool -K "$iface" tso off gso off gro off lro off tx off rx off sg off 2>/dev/null || true
    sudo ethtool -K "$iface" tx-checksum-ip-generic off rx-checksum off 2>/dev/null || true
  fi
  sudo ip link set "$iface" txqueuelen 1000 2>/dev/null || true
}

# Restore everything we touched.  Called via EXIT trap.
restore_flash_env() {
  # Restore USB autosuspend.
  if [[ -n "${_USB_AUTOSUSPEND_PREV}" && -w /sys/module/usbcore/parameters/autosuspend ]]; then
    echo "${_USB_AUTOSUSPEND_PREV}" | sudo tee /sys/module/usbcore/parameters/autosuspend >/dev/null 2>&1 || true
  fi

  # Restart NetworkManager if we stopped it.
  if [[ "${_NM_WAS_ACTIVE}" -eq 1 ]]; then
    say "Restarting NetworkManager..."
    sudo systemctl start NetworkManager 2>/dev/null || true
  fi

  # Restart TLP if we stopped it.
  if [[ "${_TLP_WAS_ACTIVE}" -eq 1 ]]; then
    say "Restarting TLP..."
    sudo systemctl start tlp 2>/dev/null || true
  fi

  # Clean NFS exports.
  cleanup_stale_exports
}

###############################################################################
# NFS preflight
###############################################################################

# Restart rpcbind + NFS server into a known-good state.
preflight_nfs() {
  say "NFS preflight: ensuring host NFS stack is in a clean state..."

  local restarted_any="false"

  # rpcbind must come up before nfs-kernel-server.
  if sudo systemctl cat rpcbind &>/dev/null; then
    sudo systemctl restart rpcbind
    say "  rpcbind: restarted."
    restarted_any="true"
  else
    say "  rpcbind: not managed by systemd — ensure portmapper is running manually."
  fi

  # nfs-kernel-server (Debian/Ubuntu name; nfs-server on Fedora/RHEL)
  local nfs_unit=""
  if sudo systemctl cat nfs-kernel-server &>/dev/null; then
    nfs_unit="nfs-kernel-server"
  elif sudo systemctl cat nfs-server &>/dev/null; then
    nfs_unit="nfs-server"
  fi

  if [[ -n "$nfs_unit" ]]; then
    sudo systemctl restart "$nfs_unit"
    say "  ${nfs_unit}: restarted."
    restarted_any="true"
  else
    say "  nfs-kernel-server: not managed by systemd — ensure NFS server is running manually."
  fi

  [[ "$restarted_any" == "true" ]] || \
    say "  WARNING: Could not restart NFS services. Flash may fail at the APP rootfs step."

  # Warn if UFW is active — NFS ports (111 portmapper, 2049 nfs) must be reachable
  # from the Jetson on the usb0 interface.
  if command -v ufw &>/dev/null && sudo ufw status 2>/dev/null | grep -q "^Status: active"; then
    say "  WARNING: UFW firewall is active. If flash fails at the APP partition step,"
    say "           NFS ports may be blocked. To open them on usb0 for this session:"
    say "             sudo ufw allow in on usb0"
  fi
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
# Jetson-side observability
###############################################################################
#
# The Jetson is a black box during flash — when it powers off or the SSH
# session drops, we have no idea why.  These functions crack it open:
#
# 1. patch_bsp_for_telemetry: modifies the *extracted* BSP's
#    nv_flash_from_network.sh to start a background telemetry daemon that
#    streams diagnostics (dmesg, temp, memory, watchdog) over the SSH pipe
#    so the host can see exactly what's happening on the Jetson in real time.
#
# 2. run_diagnose_mode: boots the Jetson into initrd (--initrd flag, no
#    flash) then SSHes in and runs a diagnostic suite so we can inspect the
#    board state before committing to a full flash.

# IPv6 address the Jetson uses in initrd flash mode.
# NVIDIA assigns fc00:1:1:<instance>::2 for the device and ::1 for the host.
# For a single device (instance 0), the device address is fc00:1:1:0::2.
# Note: fc00:: is a unique-local address, no %usb0 scope suffix needed.
JETSON_INITRD_IPV6="fc00:1:1:0::2"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5)

# Best-effort bootstrap of a human diagnostics account inside initrd.
# This intentionally does NOT disable root login in diagnose mode so existing
# machine automation (root/root over sshpass) remains stable.
bootstrap_initrd_installer_ssh_user() {
  local ssh_mode="${OURBOX_INSTALLER_SSH_MODE:-key}"
  local ssh_user="${OURBOX_INSTALLER_SSH_USER:-ourbox-installer}"
  local ssh_hash="${OURBOX_INSTALLER_SSH_PASSWORD_HASH:-${DEFAULT_INSTALLER_SSH_PASSWORD_HASH}}"
  local ssh_keys="${OURBOX_INSTALLER_SSH_AUTHORIZED_KEYS:-}"

  case "${ssh_mode}" in
    off|key|password|both) ;;
    *) ssh_mode="key" ;;
  esac

  if [[ "${ssh_mode}" == "off" ]]; then
    say "Initrd diagnostics user bootstrap disabled (OURBOX_INSTALLER_SSH_MODE=off)."
    return 0
  fi

  say "Configuring initrd diagnostics user '${ssh_user}' (mode=${ssh_mode})..."
  if sshpass -p root ssh "${SSH_OPTS[@]}" "root@${JETSON_INITRD_IPV6}" \
    sh -s -- "${ssh_mode}" "${ssh_user}" "${ssh_hash}" "${ssh_keys}" <<'BOOTSTRAP_EOF'
set -eu
mode="$1"
user="$2"
pass_hash="$3"
auth_keys="$4"

case "$mode" in
  off|key|password|both) ;;
  *) mode="key" ;;
esac

if [ "$mode" = "off" ]; then
  exit 0
fi

if ! id "$user" >/dev/null 2>&1; then
  if command -v useradd >/dev/null 2>&1; then
    useradd -m -s /bin/sh "$user" >/dev/null 2>&1 || useradd -m "$user" >/dev/null 2>&1 || true
  fi
  if ! id "$user" >/dev/null 2>&1 && command -v adduser >/dev/null 2>&1; then
    adduser -D -h "/home/$user" "$user" >/dev/null 2>&1 \
      || adduser --disabled-password --gecos "" "$user" >/dev/null 2>&1 \
      || true
  fi
fi

if ! id "$user" >/dev/null 2>&1; then
  echo "could-not-create-user"
  exit 1
fi

home_dir="$(awk -F: -v u="$user" '$1==u {print $6; exit}' /etc/passwd 2>/dev/null || true)"
[ -n "$home_dir" ] || home_dir="/home/$user"

if [ "$mode" = "password" ] || [ "$mode" = "both" ]; then
  if [ -n "$pass_hash" ]; then
    if command -v chpasswd >/dev/null 2>&1; then
      printf '%s:%s\n' "$user" "$pass_hash" | chpasswd -e >/dev/null 2>&1 || true
    elif command -v usermod >/dev/null 2>&1; then
      usermod -p "$pass_hash" "$user" >/dev/null 2>&1 || true
    fi
  fi
else
  if command -v passwd >/dev/null 2>&1; then
    passwd -l "$user" >/dev/null 2>&1 || true
  fi
fi

mkdir -p "$home_dir/.ssh"
chmod 0700 "$home_dir/.ssh" >/dev/null 2>&1 || true
if [ "$mode" = "key" ] || [ "$mode" = "both" ]; then
  if [ -n "$auth_keys" ]; then
    printf '%s\n' "$auth_keys" > "$home_dir/.ssh/authorized_keys"
    chmod 0600 "$home_dir/.ssh/authorized_keys" >/dev/null 2>&1 || true
  else
    rm -f "$home_dir/.ssh/authorized_keys" >/dev/null 2>&1 || true
  fi
else
  rm -f "$home_dir/.ssh/authorized_keys" >/dev/null 2>&1 || true
fi
chown -R "$user:$user" "$home_dir/.ssh" >/dev/null 2>&1 || true
echo "ready user=${user} mode=${mode}"
BOOTSTRAP_EOF
  then
    say "Initrd diagnostics user ready: ssh ${ssh_user}@${JETSON_INITRD_IPV6}"
  else
    say "WARNING: Failed to configure initrd diagnostics user '${ssh_user}'."
    say "         Root automation remains available via sshpass root@${JETSON_INITRD_IPV6}."
  fi
}

# Patch the extracted BSP's nv_flash_from_network.sh to inject a background
# telemetry daemon that runs alongside the flash.  This writes to stdout,
# which the host sees through the SSH pipe.
patch_bsp_for_telemetry() {
  local target="${L4T_DIR}/tools/kernel_flash/initrd_flash/nv_flash_from_network.sh"
  [[ -f "$target" ]] || { say "WARNING: Cannot patch telemetry — ${target} not found."; return 0; }

  # Idempotent — skip if already patched.
  if grep -qF 'TINDERBOX_TELEMETRY' "$target" 2>/dev/null; then
    say "  BSP telemetry patch: already applied."
    return 0
  fi

  say "  Patching nv_flash_from_network.sh for Jetson-side telemetry..."

  # We inject a telemetry function and a background invocation just before
  # the chroot line.  The monitor runs outside the chroot (in the initrd)
  # so it has access to raw hardware: /dev/watchdog*, thermal zones, etc.
  local patch_marker='chroot /mnt "/mnt/${kernel_flash_script}" --no-reboot "${@}"'

  # Build the telemetry block.  It runs in the background, printing to
  # fd 1 (the SSH session's stdout → host terminal).
  local telemetry_block
  read -r -d '' telemetry_block <<'TELEM_EOF' || true
# --- TINDERBOX_TELEMETRY: injected by flash-orin-nano-nvme-r36.5.sh ---

# Force the PWM fan to full speed.  The initrd has no nvfancontrol daemon so
# the fan is either stopped or at a low hardware default.  Starting from ~80°C
# idle with zstd -T0 running on all CPUs will hit 104.5°C critical shutdown
# in ~215 seconds without active cooling.
_tinderbox_fan_on() {
  local found=0
  # Orin Nano devkit: fan is on pwm-fan, exposed under hwmon as pwm1
  for pwm in /sys/class/hwmon/hwmon*/pwm1; do
    [ -f "$pwm" ] || continue
    # Enable manual mode if enable knob exists
    local enable="${pwm%pwm1}pwm1_enable"
    [ -f "$enable" ] && echo 1 > "$enable" 2>/dev/null || true
    echo 255 > "$pwm" 2>/dev/null && found=1 && \
      echo "[tinderbox-telemetry] fan: set ${pwm} -> 255 (full speed)"
  done
  # Fallback: raw sysfs PWM chip
  for chip in /sys/class/pwm/pwmchip*; do
    [ -d "$chip" ] || continue
    for pwm_dir in "${chip}"/pwm*; do
      [ -d "$pwm_dir" ] || continue
      echo 255 > "${pwm_dir}/duty_cycle" 2>/dev/null && found=1 && \
        echo "[tinderbox-telemetry] fan: set ${pwm_dir}/duty_cycle -> 255"
    done
  done
  [ "$found" -eq 1 ] || echo "[tinderbox-telemetry] fan: no PWM fan sysfs found (check cooling!)"
}
_tinderbox_fan_on

_tinderbox_telemetry() {
  echo "[tinderbox-telemetry] starting Jetson-side monitor (PID $$)"
  echo "[tinderbox-telemetry] kernel: $(uname -r)"
  echo "[tinderbox-telemetry] uptime at start: $(cat /proc/uptime)"

  # Watchdog detection
  for wd in /dev/watchdog*; do
    if [ -e "$wd" ]; then
      echo "[tinderbox-telemetry] watchdog device found: $wd"
    fi
  done
  if [ -f /proc/sys/kernel/watchdog ]; then
    echo "[tinderbox-telemetry] kernel watchdog: $(cat /proc/sys/kernel/watchdog)"
  fi

  # Initial snapshot
  echo "[tinderbox-telemetry] memory: $(awk 'NR<=5' /proc/meminfo | tr '\n' ' ')"
  for tz in /sys/class/thermal/thermal_zone*/temp; do
    [ -f "$tz" ] || continue
    # Use shell expansion instead of basename (not available in all initrd builds)
    local tzdir="${tz%/temp}"
    local tzname="${tzdir##*/}"
    echo "[tinderbox-telemetry] temp ${tzname}: $(cat "$tz")"
  done

  local i=0
  while true; do
    sleep 10
    i=$((i + 1))
    local ts
    ts="$(date +%T 2>/dev/null || cat /proc/uptime)"
    local mem_avail="n/a"
    [ -f /proc/meminfo ] && mem_avail="$(awk '/MemAvailable/{print $2" "$3}' /proc/meminfo)"
    local temps=""
    for tz in /sys/class/thermal/thermal_zone*/temp; do
      [ -f "$tz" ] || continue
      local tzdir="${tz%/temp}"
      local tzname="${tzdir##*/}"
      temps="${temps} ${tzname}=$(cat "$tz")"
    done
    local up=""
    [ -f /proc/uptime ] && up="$(cut -d' ' -f1 /proc/uptime)"

    echo "[tinderbox-telemetry] tick=${i} time=${ts} uptime=${up}s mem_avail=${mem_avail} temps=[${temps}]"

    # Re-assert fan speed every minute in case it gets reset
    [ $((i % 6)) -eq 0 ] && _tinderbox_fan_on

    # Check for OOM events
    if dmesg 2>/dev/null | tail -20 | grep -qiE 'oom|out of memory|killed process'; then
      echo "[tinderbox-telemetry] WARNING: OOM detected in dmesg!"
      dmesg 2>/dev/null | grep -iE 'oom|out of memory|killed process' | tail -5
    fi

    # Warn on high temperature
    for tz in /sys/class/thermal/thermal_zone*/temp; do
      [ -f "$tz" ] || continue
      local t; t="$(cat "$tz" 2>/dev/null || echo 0)"
      if [ "$t" -gt 95000 ]; then
        local tzdir="${tz%/temp}"; local tzname="${tzdir##*/}"
        echo "[tinderbox-telemetry] CRITICAL TEMP: ${tzname}=${t} mC — shutdown imminent!"
      elif [ "$t" -gt 85000 ]; then
        local tzdir="${tz%/temp}"; local tzname="${tzdir##*/}"
        echo "[tinderbox-telemetry] HIGH TEMP WARNING: ${tzname}=${t} mC"
      fi
    done
  done
}
_tinderbox_telemetry &
_TELEM_PID=$!
echo "[tinderbox-telemetry] background monitor started as PID ${_TELEM_PID}"
# --- end TINDERBOX_TELEMETRY ---
TELEM_EOF

  # Insert the telemetry block just before the chroot line.
  # Use a temp file to avoid sed issues with multi-line replacement.
  local tmp
  tmp="$(mktemp)"
  awk -v block="$telemetry_block" '
    /chroot \/mnt.*kernel_flash_script.*--no-reboot/ {
      print block
    }
    { print }
  ' "$target" > "$tmp"

  sudo cp "$tmp" "$target"
  sudo chmod +x "$target"
  rm -f "$tmp"

  say "  BSP telemetry patch: applied."

  # Patch l4t_flash_from_kernel.sh to limit zstd CPU threads.
  # The default 'zstd -T0' uses ALL CPU cores — on Orin Nano that's 6 cores at
  # 100%, which pushes the SoC from its ~80°C idle baseline to the 104.5°C
  # critical shutdown threshold in ~215 seconds.  Capping at 4 threads cuts
  # thermal load ~30% while still decompressing in reasonable time.
  local flash_kernel="${L4T_DIR}/tools/kernel_flash/l4t_flash_from_kernel.sh"
  if [[ -f "$flash_kernel" ]]; then
    if grep -qF 'zstd -T0' "$flash_kernel" 2>/dev/null; then
      say "  Patching l4t_flash_from_kernel.sh: limiting zstd to 4 threads (thermal safety)..."
      local tmp2
      tmp2="$(mktemp)"
      sed "s/zstd -T0/zstd -T4/g" "$flash_kernel" > "$tmp2"
      sudo cp "$tmp2" "$flash_kernel"
      sudo chmod +x "$flash_kernel"
      rm -f "$tmp2"
      say "  zstd thread-limit patch: applied (zstd -T0 → zstd -T4)."
    else
      say "  zstd thread-limit patch: 'zstd -T0' not found in ${flash_kernel} — skipping."
    fi
  else
    say "  WARNING: ${flash_kernel} not found — zstd thread-limit patch skipped."
  fi
}

# Run diagnostic mode: boot into initrd, SSH in, inspect the board.
run_diagnose_mode() {
  say ""
  say "=== DIAGNOSE MODE ==="
  say "Booting Jetson into initrd (no flash) for inspection..."
  say ""

  # We need the BSP extracted and prepped first.
  _prepare_bsp

  cd "$L4T_DIR"

  local QSPI_CFG NVME_XML
  QSPI_CFG="$(resolve_qspi_cfg)" \
    || die "Could not find flash_t234_qspi*.xml — check your BSP tarball."
  NVME_XML="$(resolve_nvme_xml)" \
    || die "Could not find flash_l4t_t234_nvme*.xml — check your BSP tarball."

  say "Launching NVIDIA initrd flash in --initrd (boot-only) mode..."
  say "Once the device boots, you can SSH in with:"
  say "  ssh root@${JETSON_INITRD_IPV6}   # machine automation credentials are managed by tooling"
  say ""

  sudo ./tools/kernel_flash/l4t_initrd_flash.sh \
    --showlogs \
    --network usb0 \
    --initrd \
    --external-device "${EXTERNAL_DEVICE_PART}" \
    -c "${NVME_XML}" \
    -p "-c ${QSPI_CFG}" \
    "${BOARD}" "${TARGET_NVME_PART}" |& tee "$LOG_DIR/diagnose_initrd.log" &
  local nvidia_pid=$!

  # Phase 1: wait for the NVIDIA tool to report the device has booted into initrd.
  # The tool first generates the flash package, then does RCM boot, then polls for
  # initrd SSH — all of which takes 3-8 minutes.  Only start our SSH probe after
  # the tool confirms initrd is up, otherwise we race against a device that hasn't
  # even started RCM boot yet.
  say "Phase 1: waiting for NVIDIA tool to confirm initrd boot (up to 600s)..."
  local waited=0
  local booted=0
  while [[ $waited -lt 600 ]]; do
    if grep -q "Device has booted into initrd" "$LOG_DIR/diagnose_initrd.log" 2>/dev/null; then
      booted=1
      break
    fi
    # Also bail early if the NVIDIA tool has already exited with an error.
    if ! kill -0 "$nvidia_pid" 2>/dev/null; then
      say "NVIDIA tool exited before initrd boot was confirmed."
      wait "$nvidia_pid" 2>/dev/null || true
      return 1
    fi
    sleep 3
    waited=$((waited + 3))
    printf "."
  done
  echo ""

  if [[ $booted -eq 0 ]]; then
    say "Timed out waiting for NVIDIA tool to confirm initrd boot after ${waited}s."
    say "Check ${LOG_DIR}/diagnose_initrd.log for errors."
    wait "$nvidia_pid" 2>/dev/null || true
    return 1
  fi
  say "Jetson reported initrd boot at t=${waited}s. Starting SSH probe..."

  # Phase 2: now that initrd is up, SSH should come up within ~30s.
  local ssh_waited=0
  while ! sshpass -p root ssh "${SSH_OPTS[@]}" "root@${JETSON_INITRD_IPV6}" "echo SSH_READY" 2>/dev/null; do
    sleep 2
    ssh_waited=$((ssh_waited + 2))
    if [[ $ssh_waited -ge 60 ]]; then
      say "Timed out waiting for SSH after initrd boot confirmed (${ssh_waited}s)."
      say "The Jetson booted but SSH is not reachable at ${JETSON_INITRD_IPV6}."
      wait "$nvidia_pid" 2>/dev/null || true
      return 1
    fi
    printf "."
  done
  echo ""
  say "Jetson SSH is up (${ssh_waited}s after initrd boot confirmation)."
  say ""

  bootstrap_initrd_installer_ssh_user
  say ""

  # Run the diagnostic suite.
  say "=== Jetson Diagnostic Report ==="
  sshpass -p root ssh "${SSH_OPTS[@]}" "root@${JETSON_INITRD_IPV6}" bash -s <<'DIAG_EOF'
echo "--- Kernel ---"
uname -a

echo ""
echo "--- Uptime ---"
cat /proc/uptime

echo ""
echo "--- Memory ---"
cat /proc/meminfo | head -10

echo ""
echo "--- Watchdog Devices ---"
ls -la /dev/watchdog* 2>/dev/null || echo "(none found)"
if [ -f /proc/sys/kernel/watchdog ]; then
  echo "kernel.watchdog = $(cat /proc/sys/kernel/watchdog)"
fi
if [ -f /proc/sys/kernel/nmi_watchdog ]; then
  echo "kernel.nmi_watchdog = $(cat /proc/sys/kernel/nmi_watchdog)"
fi

echo ""
echo "--- Fan Speed ---"
found_fan=0
for pwm in /sys/class/hwmon/hwmon*/pwm1; do
  [ -f "$pwm" ] || continue
  echo "  ${pwm}: $(cat "$pwm" 2>/dev/null || echo n/a) (0=off, 255=max)"
  found_fan=1
done
for fan_in in /sys/class/hwmon/hwmon*/fan*_input; do
  [ -f "$fan_in" ] || continue
  echo "  ${fan_in}: $(cat "$fan_in" 2>/dev/null || echo n/a) RPM"
  found_fan=1
done
[ "$found_fan" -eq 1 ] || echo "  (no fan sysfs found)"

echo ""
echo "--- Thermal Zones ---"
for tz in /sys/class/thermal/thermal_zone*/; do
  [ -d "$tz" ] || continue
  # Use shell expansion — basename may not exist in this initrd
  tzname="${tz%/}"; tzname="${tzname##*/}"
  type="$(cat "${tz}type" 2>/dev/null || echo unknown)"
  temp="$(cat "${tz}temp" 2>/dev/null || echo n/a)"
  trip=""
  for tp in "${tz}"trip_point_*_temp; do
    [ -f "$tp" ] || continue
    tpname="${tp##*/}"
    trip="${trip} ${tpname}=$(cat "$tp")"
  done
  echo "  ${tzname}: type=${type} temp=${temp} trips=[${trip}]"
done

echo ""
echo "--- Block Devices ---"
lsblk 2>/dev/null || ls -la /dev/nvme* /dev/mmcblk* /dev/sd* 2>/dev/null || echo "(none)"

echo ""
echo "--- NVMe Health ---"
if [ -e /dev/nvme0 ]; then
  cat /sys/class/nvme/nvme0/model 2>/dev/null && echo ""
  cat /sys/class/nvme/nvme0/state 2>/dev/null
  cat /sys/class/nvme/nvme0/firmware_rev 2>/dev/null && echo ""
fi

echo ""
echo "--- Power/PMIC ---"
for f in /sys/bus/i2c/drivers/*/power/runtime_status; do
  [ -f "$f" ] && echo "  $f: $(cat "$f")"
done 2>/dev/null
# INA3221 power monitors on the devkit
for f in /sys/bus/i2c/devices/*/hwmon/*/in*_input; do
  [ -f "$f" ] && echo "  $f: $(cat "$f") mV"
done 2>/dev/null
for f in /sys/bus/i2c/devices/*/hwmon/*/curr*_input; do
  [ -f "$f" ] && echo "  $f: $(cat "$f") mA"
done 2>/dev/null

echo ""
echo "--- dmesg (last 30 lines) ---"
dmesg 2>/dev/null | tail -30

echo ""
echo "--- dmesg watchdog/thermal/power mentions ---"
dmesg 2>/dev/null | grep -iE 'watchdog|wdt|thermal|over.?temp|shutdown|power|pmic|oom|kill' || echo "(none)"
DIAG_EOF

  say ""
  say "=== End Diagnostic Report ==="
  say ""
  say "The Jetson is still booted in initrd. You can SSH in manually:"
  say "  ssh root@${JETSON_INITRD_IPV6}   # machine automation credentials are managed by tooling"
  if [[ "${OURBOX_INSTALLER_SSH_MODE}" != "off" ]]; then
    say "  ssh ${OURBOX_INSTALLER_SSH_USER}@${JETSON_INITRD_IPV6}    # if initrd user bootstrap succeeded"
  fi
  say ""
  say "When done, press Ctrl-C or power-cycle the Jetson."

  wait "$nvidia_pid" 2>/dev/null || true
}

# Extract BSP and prepare rootfs (shared between flash and diagnose modes).
# Results are cached by SHA-256 of the input tarballs; pass --no-cache to force
# a full rebuild.
_prepare_bsp() {
  mkdir -p "$WORK_DIR" "$LOG_DIR"

  cleanup_stale_exports
  harden_usb_for_flash
  trap restore_flash_env EXIT

  # --- BSP extraction checkpoint ---
  if _bsp_cache_valid; then
    say "BSP cache hit — skipping tarball extraction (${L4T_DIR} already up-to-date)."
    say "  (Run with --no-cache to force re-extraction.)"
  else
    if [[ -d "$L4T_DIR" ]]; then
      say "BSP cache miss — removing stale ${L4T_DIR}..."
      safe_rm_rf "$L4T_DIR"
    fi
    _invalidate_rootfs_stamp   # BSP changed → rootfs must be redone too

    say "Extracting BSP -> ${WORK_DIR}"
    tar xpf "$JETSON_TARBALL" -C "$WORK_DIR"
    [[ -d "$L4T_DIR" ]] || die "Extraction failed: ${L4T_DIR} not found"
    _write_bsp_stamp
    say "BSP extracted and stamped."
  fi

  cd "$L4T_DIR"

  # --- Rootfs + apply_binaries checkpoint ---
  if _rootfs_cache_valid; then
    say "Rootfs cache hit — skipping rootfs extraction and apply_binaries (already up-to-date)."
    say "  (Run with --no-cache to force re-extraction.)"
  else
    say "Preparing rootfs..."
    sudo rm -rf rootfs
    sudo mkdir -p rootfs
    sudo tar xpf "$ROOTFS_TARBALL" -C rootfs

    say "Applying NVIDIA binaries..."
    sudo ./apply_binaries.sh |& tee "$LOG_DIR/apply_binaries_${L4T_RELEASE}.log"
    _write_rootfs_stamp
    say "Rootfs prepared and stamped."
  fi

  local missing=()
  for c in sshpass exportfs rpcinfo mkfs.vfat gdisk parted cpio zstd xxd ethtool; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  if ((${#missing[@]})); then
    say "Host prerequisites missing: ${missing[*]}"
    say "Running NVIDIA prerequisites installer (may require internet the first time)..."
    sudo tools/l4t_flash_prerequisites.sh |& tee "$LOG_DIR/l4t_flash_prerequisites_${L4T_RELEASE}.log"
  else
    say "Host prerequisites look installed (skipping l4t_flash_prerequisites.sh)."
  fi

  preflight_nfs
  apply_usb_offloads_now

  # Inject telemetry into the Jetson-side flash scripts (idempotent).
  patch_bsp_for_telemetry
}

###############################################################################
# Main
###############################################################################

main() {
  local MODE="flash"

  # Argument parsing
  for arg in "$@"; do
    case "$arg" in
      --yes) ASSUME_YES="true" ;;
      --diagnose) MODE="diagnose" ;;
      --no-cache) NO_CACHE="true" ;;
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
  need_cmd sshpass
  need_cmd sha256sum

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

  # Diagnose mode: boot into initrd and inspect the board.
  if [[ "$MODE" == "diagnose" ]]; then
    run_diagnose_mode
    return 0
  fi

  # Normal flash mode.
  _prepare_bsp

  cd "$L4T_DIR"

  local QSPI_CFG NVME_XML
  QSPI_CFG="$(resolve_qspi_cfg)" \
    || die "Could not find flash_t234_qspi*.xml under ${L4T_DIR}/bootloader — check your BSP tarball."
  NVME_XML="$(resolve_nvme_xml)" \
    || die "Could not find flash_l4t_t234_nvme*.xml under ${L4T_DIR}/tools/kernel_flash — check your BSP tarball."

  say "Using QSPI cfg : ${QSPI_CFG}"
  say "Using NVMe xml : ${NVME_XML}"

  say ""
  say "Flashing using NVIDIA initrd workflow for Orin Nano + NVMe..."
  say "BOARD=${BOARD}"
  say "OS NVMe partition to be ERASED/Flashed: /dev/${TARGET_NVME_PART}"
  say "Logs: ${LOG_DIR}"

  # -p passes extra args to the inner flash.sh call (QSPI config).
  # -c provides the external (NVMe) partition layout for the initrd flash stage.
  # systemd-inhibit prevents the host from sleeping mid-flash.
  local flash_cmd=(
    sudo ./tools/kernel_flash/l4t_initrd_flash.sh
    --showlogs
    --network usb0
    --external-device "${EXTERNAL_DEVICE_PART}"
    -c "${NVME_XML}"
    -p "-c ${QSPI_CFG}"
    "${BOARD}" "${TARGET_NVME_PART}"
  )

  if command -v systemd-inhibit >/dev/null 2>&1; then
    systemd-inhibit \
      --what=sleep:shutdown:idle \
      --mode=block \
      --why="Jetson flashing (NFS over USB)" \
      "${flash_cmd[@]}" |& tee "$LOG_DIR/flash_${L4T_RELEASE}.log"
  else
    "${flash_cmd[@]}" |& tee "$LOG_DIR/flash_${L4T_RELEASE}.log"
  fi

  say "Flash complete."
  say "Log file: ${LOG_DIR}/flash_${L4T_RELEASE}.log"
}

main "$@"
