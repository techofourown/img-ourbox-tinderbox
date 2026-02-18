#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

# ---------- NVIDIA artifact fetch ----------

maybe_fetch_nvidia_artifacts() {
  local root="$1"
  local bsp="$2"
  local rootfs="$3"

  if [[ -f "${bsp}" && -f "${rootfs}" ]]; then
    return 0
  fi

  warn "Missing required NVIDIA artifacts in artifacts/nvidia/."
  [[ -f "${bsp}" ]] || warn "  - ${bsp}"
  [[ -f "${rootfs}" ]] || warn "  - ${rootfs}"
  echo
  warn "These files are NOT committed to git."
  warn "We can download them now (online step), then everything else runs offline/airgapped."
  echo

  local fetch="${root}/tools/fetch-nvidia-artifacts.sh"
  [[ -x "${fetch}" ]] || die "Missing fetch script: ${fetch}"

  read -r -p "Type YES to download the NVIDIA artifacts now: " ans
  [[ "${ans}" == "YES" ]] || die "Aborted. Run: ./tools/fetch-nvidia-artifacts.sh"

  "${fetch}"
}

# ---------- USB target selection ----------

declare -a CANDIDATE_DISKS=()

refresh_candidate_disks() {
  local root_disk="$1"
  CANDIDATE_DISKS=()
  while read -r disk; do
    [[ -n "${disk}" ]] || continue
    if is_candidate_media_disk "${disk}" "${root_disk}"; then
      CANDIDATE_DISKS+=("${disk}")
    fi
  done < <(lsblk -dn -o NAME,TYPE | awk '$2=="disk" {print "/dev/"$1}')
}

print_candidate_disks() {
  local idx disk size tran model serial byid

  echo
  echo "Detected removable/USB target candidates:"
  echo
  printf '  %-3s %-14s %-8s %-6s %-22s %-14s\n' "#" "Device" "Size" "Tran" "Model" "Serial"
  for idx in "${!CANDIDATE_DISKS[@]}"; do
    disk="${CANDIDATE_DISKS[$idx]}"
    size="$(lsblk -dn -o SIZE "${disk}" 2>/dev/null | tr -d '[:space:]')"
    tran="$(lsblk -dn -o TRAN "${disk}" 2>/dev/null | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
    model="$(lsblk -dn -o MODEL "${disk}" 2>/dev/null | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    serial="$(lsblk -dn -o SERIAL "${disk}" 2>/dev/null | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [[ -n "${tran}" ]] || tran="-"
    [[ -n "${model}" ]] || model="-"
    [[ -n "${serial}" ]] || serial="-"
    printf '  %-3s %-14s %-8s %-6s %-22.22s %-14.14s\n' \
      "$((idx + 1))" "${disk}" "${size}" "${tran}" "${model}" "${serial}"

    byid="$(preferred_byid_for_disk "${disk}" || true)"
    if [[ -n "${byid}" ]]; then
      echo "      by-id: ${byid}"
    fi

    echo "      partitions (name fstype label mountpoints):"
    lsblk -nr -o NAME,FSTYPE,LABEL,MOUNTPOINTS "${disk}" 2>/dev/null | sed 's/^/        /'
  done
  echo
}

validate_target_dev_or_die() {
  local target="$1"
  local root_disk="$2"
  local target_real target_type

  [[ -n "${target}" ]] || die "target device is empty"
  [[ -e "${target}" ]] || die "target device does not exist: ${target}"

  target_real="$(readlink -f "${target}")"
  target_type="$(lsblk -dn -o TYPE "${target_real}" 2>/dev/null | tr -d '[:space:]')"
  [[ "${target_type}" == "disk" ]] || die "target is not a raw disk: ${target_real}"
  [[ "${target_real}" != "${root_disk}" ]] || die "refusing target that backs / (${root_disk})"
}

select_target_device_interactive() {
  local root_disk="$1"
  local choice idx selected byid confirm

  while true; do
    refresh_candidate_disks "${root_disk}"

    if (( ${#CANDIDATE_DISKS[@]} == 0 )); then
      echo
      echo "No removable/USB disk candidates found."
      echo "Insert the target USB media, then rescan."
      read -r -p "Press ENTER to rescan, or type q to quit: " choice
      [[ "${choice}" == "q" || "${choice}" == "Q" ]] && die "no target media selected"
      continue
    fi

    print_candidate_disks
    read -r -p "Select target number (r=rescan, q=quit): " choice
    case "${choice}" in
      r|R) continue ;;
      q|Q) die "operator canceled target media selection" ;;
    esac

    [[ "${choice}" =~ ^[0-9]+$ ]] || { warn "invalid selection: ${choice}"; continue; }
    idx="$((choice - 1))"
    (( idx >= 0 && idx < ${#CANDIDATE_DISKS[@]} )) || { warn "selection out of range: ${choice}"; continue; }

    selected="${CANDIDATE_DISKS[$idx]}"
    byid="$(preferred_byid_for_disk "${selected}" || true)"
    if [[ -n "${byid}" ]]; then
      selected="${byid}"
    fi

    validate_target_dev_or_die "${selected}" "${root_disk}"
    echo
    lsblk -o NAME,SIZE,MODEL,SERIAL,TYPE,FSTYPE,LABEL,MOUNTPOINTS "${selected}" || true
    echo
    read -r -p "Type SELECT to use ${selected}: " confirm
    [[ "${confirm}" == "SELECT" ]] || { warn "selection not confirmed; returning to list"; continue; }
    TARGET_DEV="${selected}"
    return 0
  done
}

# ---------- main ----------

main() {
  require_root
  require_cmd lsblk awk sed grep cut tr head tail tar rsync parted mkfs.ext4 \
              mount umount sync wipefs readlink findmnt
  load_defaults_env

  local root
  root="$(repo_root)"

  local art_dir="${root}/artifacts/nvidia"
  local bsp="${art_dir}/${NVIDIA_BSP_TARBALL}"
  local rootfs="${art_dir}/${NVIDIA_ROOTFS_TARBALL}"

  maybe_fetch_nvidia_artifacts "${root}" "${bsp}" "${rootfs}"

  [[ -f "${bsp}" ]] || die "Missing BSP tarball: ${bsp}\nRun: ./tools/fetch-nvidia-artifacts.sh"
  [[ -f "${rootfs}" ]] || die "Missing sample rootfs tarball: ${rootfs}\nRun: ./tools/fetch-nvidia-artifacts.sh"

  bold "Tinderbox installer media preparation"
  note "L4T_RELEASE=${L4T_RELEASE}"
  note "BSP:   ${NVIDIA_BSP_TARBALL}"
  note "ROOTFS:${NVIDIA_ROOTFS_TARBALL}"
  echo

  local root_disk
  root_disk="$(root_backing_disk)"

  local TARGET_DEV=""
  select_target_device_interactive "${root_disk}"
  validate_target_dev_or_die "${TARGET_DEV}" "${root_disk}"

  local disk
  disk="$(readlink -f "${TARGET_DEV}")"

  echo
  bold "DANGER ZONE"
  printf "About to ERASE: %s\n\n" "${disk}"
  lsblk -o NAME,SIZE,MODEL,SERIAL,TRAN,RM "${disk}" || true
  echo
  confirm_dangerous "Type YES to erase ${disk}: "

  unmount_partitions "${disk}"

  note "Wiping signatures on ${disk}"
  wipefs -a "${disk}" || true

  note "Creating GPT + single ext4 partition"
  parted -s "${disk}" mklabel gpt
  parted -s "${disk}" mkpart primary ext4 1MiB 100%
  parted -s "${disk}" set 1 msftdata on || true
  partprobe "${disk}" || true
  sleep 1

  local part="${disk}1"
  if [[ "${disk}" =~ [0-9]$ ]]; then
    part="${disk}p1"
  fi

  note "Formatting ${part} as ext4 (label: TINDERBOX_INSTALLER)"
  mkfs.ext4 -F -L "TINDERBOX_INSTALLER" "${part}"

  local mnt
  mnt="$(mktemp -d)"
  note "Mounting ${part} at ${mnt}"
  mount "${part}" "${mnt}"

  local work="${root}/build/l4t-staging"
  rm -rf "${work}"
  mkdir -p "${work}"

  note "Extracting NVIDIA BSP to staging dir"
  tar xf "${bsp}" -C "${work}"
  local l4t="${work}/Linux_for_Tegra"
  [[ -d "${l4t}" ]] || die "Expected ${l4t} after extracting BSP tarball, but it wasn't found."

  note "Extracting sample rootfs (this can take a while)"
  mkdir -p "${l4t}/rootfs"
  tar xpf "${rootfs}" -C "${l4t}/rootfs"

  note "Applying NVIDIA userspace binaries into rootfs"
  pushd "${l4t}" >/dev/null
  ./apply_binaries.sh
  popd >/dev/null

  note "Applying Ourbox rootfs overlay"
  rsync -a "${root}/rootfs-overlay/" "${l4t}/rootfs/"

  note "Creating default user (avoids OEM-config GUI)"
  local user="${TINDERBOX_DEFAULT_USER}"
  local pass="${TINDERBOX_DEFAULT_PASS}"
  local host="${TINDERBOX_HOSTNAME}"

  if [[ -z "${pass}" ]]; then
    pass="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20)"
    warn "Generated password for ${user}: ${pass}"
  fi

  pushd "${l4t}" >/dev/null
  ./tools/l4t_create_default_user.sh -u "${user}" -p "${pass}" -n "${host}" --accept-license
  popd >/dev/null

  note "Enabling ourbox systemd services (offline enable via symlinks)"
  mkdir -p "${l4t}/rootfs/etc/systemd/system/multi-user.target.wants"
  ln -sf ../ourbox-hello.service \
    "${l4t}/rootfs/etc/systemd/system/multi-user.target.wants/ourbox-hello.service"
  ln -sf ../ourbox-firstboot.service \
    "${l4t}/rootfs/etc/systemd/system/multi-user.target.wants/ourbox-firstboot.service"

  note "Copying installer payload onto USB"
  mkdir -p "${mnt}/tinderbox"
  rsync -a "${root}/media/" "${mnt}/tinderbox/"
  rsync -a "${root}/config/defaults.env" "${mnt}/tinderbox/defaults.env"

  # Copy staged Linux_for_Tegra (big!)
  rsync -a --delete "${l4t}/" "${mnt}/tinderbox/Linux_for_Tegra/"

  note "Writing manifest"
  {
    echo "L4T_RELEASE=${L4T_RELEASE}"
    echo "NVIDIA_BSP_TARBALL=${NVIDIA_BSP_TARBALL}"
    echo "NVIDIA_ROOTFS_TARBALL=${NVIDIA_ROOTFS_TARBALL}"
    echo "TINDERBOX_DEFAULT_USER=${user}"
    echo "TINDERBOX_HOSTNAME=${host}"
    echo "PREPARED_AT_UTC=$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
    if command -v sha256sum >/dev/null 2>&1; then
      echo "SHA256_BSP=$(sha256sum "${bsp}" | awk '{print $1}')"
      echo "SHA256_ROOTFS=$(sha256sum "${rootfs}" | awk '{print $1}')"
    else
      echo "SHA256_BSP="
      echo "SHA256_ROOTFS="
    fi
  } > "${mnt}/tinderbox/MANIFEST.env"

  sync
  umount "${mnt}"
  rmdir "${mnt}"

  bold "Done."
  note "Installer USB is ready."
  note "Next (offline): mount the USB and run: sudo ./flash-jetson.sh"
}

main "$@"
