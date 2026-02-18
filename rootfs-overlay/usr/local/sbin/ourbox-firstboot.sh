#!/usr/bin/env bash
set -euo pipefail

MARKER="/var/lib/ourbox/firstboot.done"
mkdir -p "$(dirname "${MARKER}")"

echo "[ourbox-firstboot] starting..."

if [[ -r /proc/device-tree/model ]]; then
  model="$(tr -d '\0' </proc/device-tree/model)"
  echo "[ourbox-firstboot] model: ${model}"
  # Hard gate: we only support Orin NX. If someone somehow boots this elsewhere, fail loudly.
  if ! grep -qi "orin nx" <<<"${model}"; then
    echo "[ourbox-firstboot] ERROR: not an Orin NX model string; refusing to proceed." >&2
    exit 42
  fi
fi

ROOT_SRC="$(findmnt -n -o SOURCE / || true)"
if [[ -z "${ROOT_SRC}" ]]; then
  echo "[ourbox-firstboot] ERROR: could not determine root filesystem source." >&2
  exit 43
fi

# Find the parent disk of the root partition (e.g., nvme0n1 for /dev/nvme0n1p1)
ROOT_DISK="$(lsblk -no PKNAME "${ROOT_SRC}" 2>/dev/null || true)"
if [[ -z "${ROOT_DISK}" ]]; then
  # Fallback: strip /dev/ and a trailing partition suffix
  ROOT_DISK="$(basename "${ROOT_SRC}" | sed -E 's/p[0-9]+$//')"
fi
echo "[ourbox-firstboot] root disk: ${ROOT_DISK}"

# Enumerate NVMe disks
mapfile -t NVMES < <(ls -1 /dev/nvme*n1 2>/dev/null | xargs -n1 basename | sort -u || true)
if [[ "${#NVMES[@]}" -lt 2 ]]; then
  echo "[ourbox-firstboot] ERROR: expected 2 NVMe disks; found ${#NVMES[@]} (${NVMES[*]:-none})." >&2
  exit 44
fi

DATA_DISK=""
for d in "${NVMES[@]}"; do
  if [[ "${d}" != "${ROOT_DISK}" ]]; then
    DATA_DISK="${d}"
    break
  fi
done

if [[ -z "${DATA_DISK}" ]]; then
  echo "[ourbox-firstboot] ERROR: could not identify DATA NVMe (root=${ROOT_DISK})." >&2
  exit 45
fi

DATA_DEV="/dev/${DATA_DISK}"
echo "[ourbox-firstboot] data disk: ${DATA_DEV}"

# Determine partition name for p1-style devices (nvme uses p1)
DATA_PART="${DATA_DEV}p1"
if [[ "${DATA_DISK}" =~ [a-z]+$ ]]; then
  # Unlikely, but keep generic.
  DATA_PART="${DATA_DEV}1"
fi

# If a filesystem already exists on partition 1, do nothing except ensure it's mounted.
if [[ -b "${DATA_PART}" ]] && blkid "${DATA_PART}" >/dev/null 2>&1; then
  echo "[ourbox-firstboot] ${DATA_PART} already has a filesystem; will mount it."
else
  echo "[ourbox-firstboot] partitioning + formatting ${DATA_DEV} (this will ERASE it)."
  parted -s "${DATA_DEV}" mklabel gpt
  parted -s "${DATA_DEV}" mkpart primary ext4 1MiB 100%
  partprobe "${DATA_DEV}" || true
  sleep 1
  mkfs.ext4 -F -L "OURBOX-DATA" "${DATA_PART}"
fi

mkdir -p /data

UUID="$(blkid -s UUID -o value "${DATA_PART}" || true)"
if [[ -z "${UUID}" ]]; then
  echo "[ourbox-firstboot] ERROR: could not read UUID for ${DATA_PART}" >&2
  exit 46
fi

# Add to fstab if missing
if ! grep -q "OURBOX-DATA" /etc/fstab 2>/dev/null; then
  echo "[ourbox-firstboot] adding /data mount to /etc/fstab"
  echo "# OURBOX-DATA" >> /etc/fstab
  echo "UUID=${UUID}  /data  ext4  defaults,noatime  0  2" >> /etc/fstab
fi

# Mount now
mountpoint -q /data || mount /data

echo "[ourbox-firstboot] /data mounted:"
df -h /data || true

touch "${MARKER}"
echo "[ourbox-firstboot] done."
