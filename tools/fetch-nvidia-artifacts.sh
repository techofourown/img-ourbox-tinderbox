#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

usage() {
  cat <<USAGE
Usage: tools/fetch-nvidia-artifacts.sh [--yes]

Downloads the NVIDIA Jetson Linux artifacts required by this repo into:
  artifacts/nvidia/

This is the ONLY step that requires internet access.

Options:
  --yes   Non-interactive; assumes you have accepted NVIDIA's license terms.
USAGE
}

_download() {
  local url="$1"
  local dest="$2"
  local label="$3"

  if [[ -f "${dest}" ]]; then
    note "${label}: already present (skipping): ${dest}"
    return 0
  fi

  mkdir -p "$(dirname "${dest}")"

  local tmp="${dest}.partial"
  note "${label}: downloading..."
  note "  URL: ${url}"

  # Resume if a partial exists.
  if [[ -f "${tmp}" ]]; then
    curl -fL --retry 3 --retry-delay 2 --retry-connrefused -C - -o "${tmp}" "${url}"
  else
    curl -fL --retry 3 --retry-delay 2 --retry-connrefused -o "${tmp}" "${url}"
  fi

  mv "${tmp}" "${dest}"
  note "${label}: saved -> ${dest}"
}

_fix_ownership_if_sudo() {
  local path="$1"
  if [[ "${EUID}" -eq 0 && -n "${SUDO_USER:-}" ]]; then
    local grp
    grp="$(id -gn "${SUDO_USER}" 2>/dev/null || echo "${SUDO_USER}")"
    chown "${SUDO_USER}":"${grp}" "${path}" 2>/dev/null || true
  fi
}

main() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
  fi

  local assume_yes="false"
  if [[ "${1:-}" == "--yes" ]]; then
    assume_yes="true"
  fi

  require_cmd curl awk sed grep cut tr head tail sha256sum
  load_defaults_env

  local root
  root="$(repo_root)"
  local art_dir="${root}/artifacts/nvidia"
  mkdir -p "${art_dir}"

  local bsp="${art_dir}/${NVIDIA_BSP_TARBALL}"
  local rootfs="${art_dir}/${NVIDIA_ROOTFS_TARBALL}"

  # URLs can be overridden in config/defaults.env.
  local release_url="${NVIDIA_RELEASE_PAGE_URL:-}"
  local license_url="${NVIDIA_TEGRA_LICENSE_URL:-}"
  local bsp_url="${NVIDIA_BSP_URL:-}"
  local rootfs_url="${NVIDIA_ROOTFS_URL:-}"

  # Fallback to the ONLY supported release in this repo.
  if [[ -z "${bsp_url}" || -z "${rootfs_url}" ]]; then
    if [[ "${L4T_RELEASE}" == "R36.5.0" ]]; then
      local base="https://developer.download.nvidia.com/embedded/L4T/r36_Release_v5.0/release"
      release_url="${release_url:-https://developer.nvidia.com/embedded/jetson-linux-r365}"
      license_url="${license_url:-${base}/Tegra_Software_License_Agreement-Tegra-Linux.txt}"
      bsp_url="${bsp_url:-${base}/${NVIDIA_BSP_TARBALL}}"
      rootfs_url="${rootfs_url:-${base}/${NVIDIA_ROOTFS_TARBALL}}"
    else
      die "No download URLs configured for L4T_RELEASE=${L4T_RELEASE}.\n\nSet NVIDIA_BSP_URL and NVIDIA_ROOTFS_URL in config/defaults.env (and optionally NVIDIA_TEGRA_LICENSE_URL / NVIDIA_RELEASE_PAGE_URL)."
    fi
  fi

  bold "Fetch NVIDIA Jetson Linux artifacts (online step)"
  note "L4T_RELEASE=${L4T_RELEASE}"
  note "Destination: ${art_dir}"
  echo
  echo "This will download NVIDIA software required to build the offline installer media."
  echo "You must accept NVIDIA's license terms before using these files."
  echo
  if [[ -n "${release_url}" ]]; then
    echo "Release page: ${release_url}"
  fi
  if [[ -n "${license_url}" ]]; then
    echo "License:      ${license_url}"
  fi
  echo

  if [[ "${assume_yes}" != "true" ]]; then
    confirm_dangerous "Type YES to confirm you accept NVIDIA's license terms and download: "
  fi

  # Download license text for convenience (kept out of git via .gitignore)
  if [[ -n "${license_url}" ]]; then
    _download "${license_url}" "${art_dir}/NVIDIA_Tegra_Software_License_Agreement.txt" "NVIDIA license text"
    _fix_ownership_if_sudo "${art_dir}/NVIDIA_Tegra_Software_License_Agreement.txt"
  fi

  _download "${bsp_url}" "${bsp}" "Jetson Linux BSP tarball"
  _download "${rootfs_url}" "${rootfs}" "Sample rootfs tarball"

  # Write hashes for your own records (not NVIDIA-provided)
  note "Computing SHA256 (for your records)"
  (
    cd "${art_dir}"
    sha256sum "$(basename "${bsp}")" "$(basename "${rootfs}")" > SHA256SUMS.txt
  )
  _fix_ownership_if_sudo "${art_dir}/SHA256SUMS.txt"

  # If we ran under sudo, hand ownership to the invoking user.
  _fix_ownership_if_sudo "${bsp}"
  _fix_ownership_if_sudo "${rootfs}"

  bold "Done."
  note "Artifacts present:"
  ls -lh "${bsp}" "${rootfs}" 2>/dev/null || true
  note "Next: sudo ./tools/prepare-installer-media.sh"
}

main "$@"
