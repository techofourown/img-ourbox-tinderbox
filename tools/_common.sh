#!/usr/bin/env bash
set -euo pipefail

# Common helpers for tinderbox tooling.

bold() { printf "\033[1m%s\033[0m\n" "$*"; }
note() { printf "==> %s\n" "$*"; }
warn() { printf "\033[33m[warn]\033[0m %s\n" "$*" >&2; }
die()  { printf "\033[31m[error]\033[0m %s\n" "$*" >&2; exit 1; }

require_cmd() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || die "Missing required command: $cmd"
  done
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "This script must run as root (try: sudo $0 ...)"
  fi
}

script_dir() {
  cd "$(dirname "${BASH_SOURCE[0]}")" && pwd
}

repo_root() {
  cd "$(script_dir)/.." && pwd
}

load_defaults_env() {
  local root
  root="$(repo_root)"
  local f="$root/config/defaults.env"
  if [[ -f "$f" ]]; then
    # shellcheck disable=SC1090
    source "$f"
  else
    die "Missing config file: $f"
  fi
}

# Returns the whole-disk device that backs /  (e.g. /dev/sda, /dev/nvme0n1).
root_backing_disk() {
  local root_src root_real root_parent
  root_src="$(findmnt -nr -o SOURCE / 2>/dev/null || true)"
  root_real="$(readlink -f "${root_src}" 2>/dev/null || echo "${root_src}")"
  root_parent="$(lsblk -no PKNAME "${root_real}" 2>/dev/null || true)"
  if [[ -n "${root_parent}" ]]; then
    echo "/dev/${root_parent}"
  else
    echo "${root_real}"
  fi
}

# Echoes the best /dev/disk/by-id path for a disk, preferring usb-* symlinks.
preferred_byid_for_disk() {
  local disk="$1"
  local best=""
  local p target base

  for p in /dev/disk/by-id/*; do
    [[ -L "${p}" ]] || continue
    [[ "${p}" == *-part* ]] && continue
    target="$(readlink -f "${p}" 2>/dev/null || true)"
    [[ "${target}" == "${disk}" ]] || continue

    base="$(basename "${p}")"
    if [[ "${base}" == usb-* ]]; then
      echo "${p}"
      return 0
    fi
    [[ -z "${best}" ]] && best="${p}"
  done

  [[ -n "${best}" ]] && echo "${best}" || true
}

# Returns 0 only if disk is a USB or removable disk that is NOT the root disk.
# NVMe, SATA internal, and the disk backing / are all rejected.
is_candidate_media_disk() {
  local disk="$1"
  local root_disk="$2"
  local type tran rm

  type="$(lsblk -dn -o TYPE "${disk}" 2>/dev/null | tr -d '[:space:]')"
  [[ "${type}" == "disk" ]] || return 1
  [[ "${disk}" != "${root_disk}" ]] || return 1

  tran="$(lsblk -dn -o TRAN "${disk}" 2>/dev/null | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
  rm="$(lsblk -dn -o RM "${disk}" 2>/dev/null | tr -d '[:space:]')"
  [[ "${tran}" == "usb" || "${rm}" == "1" ]] || return 1

  return 0
}

confirm_dangerous() {
  local prompt="${1:-Type YES to continue: }"
  local answer
  read -r -p "$prompt" answer
  [[ "$answer" == "YES" ]] || die "Aborted."
}

unmount_partitions() {
  local disk="$1"
  mapfile -t mps < <(lsblk -lnpo NAME,MOUNTPOINT "$disk" | awk 'NF==2 {print $1 "|" $2}')
  local line dev mp
  for line in "${mps[@]}"; do
    dev="${line%%|*}"
    mp="${line#*|}"
    if [[ -n "$mp" ]]; then
      note "Unmounting $dev from $mp"
      umount -f "$dev" || true
    fi
  done
}
