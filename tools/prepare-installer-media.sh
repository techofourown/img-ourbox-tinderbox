#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

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

main() {
  require_root
  require_cmd lsblk awk sed grep cut tr head tail tar rsync parted mkfs.ext4 mount umount sync lsusb wipefs
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

  bold "Select target USB disk (WILL BE ERASED)"
  local disks=()
  local line
  while IFS= read -r line; do
    disks+=("$line")
  done < <(print_block_devices)

  if [[ "${#disks[@]}" -eq 0 ]]; then
    die "No block devices found via lsblk."
  fi

  local i=1
  for line in "${disks[@]}"; do
    printf "  [%d] %s\n" "${i}" "${line}"
    i=$((i+1))
  done

  echo
  local choice
  read -r -p "Enter the number of the USB disk to erase: " choice
  [[ "$choice" =~ ^[0-9]+$ ]] || die "Invalid selection."
  (( choice >= 1 && choice <= ${#disks[@]} )) || die "Selection out of range."

  local selected="${disks[$((choice-1))]}"
  local disk
  disk="$(awk '{print $1}' <<<"$selected")"

  # Strong suggestion: only allow TRAN=usb or RM=1
  local tran rm
  tran="$(awk '{print $4}' <<<"$selected")"
  rm="$(awk '{print $5}' <<<"$selected")"
  if [[ "${tran}" != "usb" && "${rm}" != "1" ]]; then
    warn "Selected disk does not look like removable USB (TRAN=${tran}, RM=${rm})."
    warn "If you are absolutely sure, you can continue — but double-check!"
  fi

  echo
  bold "DANGER ZONE"
  printf "About to ERASE: %s\n\n" "${selected}"
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
  ln -sf ../ourbox-hello.service "${l4t}/rootfs/etc/systemd/system/multi-user.target.wants/ourbox-hello.service"
  ln -sf ../ourbox-firstboot.service "${l4t}/rootfs/etc/systemd/system/multi-user.target.wants/ourbox-firstboot.service"

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
