#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  check-initrd-ssh-smoke.sh [jetson-initrd-ipv6]

Defaults:
  jetson-initrd-ipv6=fc00:1:1:0::2

Env overrides:
  SSH_PORT=22
  OURBOX_INSTALLER_SSH_MODE=off|key|password|both
  OURBOX_INSTALLER_SSH_USER=ourbox-installer
  OURBOX_INSTALLER_SSH_KEY=/path/to/private_key
  OURBOX_INSTALLER_SSH_PASSWORD=<password>
  EXPECT_ROOT_LOGIN=0|1
  ROOT_SSH_PASSWORD=<root password, optional>
  DIAGNOSE_LOG_PATH=<local diagnose log path>
EOF
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

host="${1:-fc00:1:1:0::2}"
if [[ "${host}" == "-h" || "${host}" == "--help" ]]; then
  usage
  exit 0
fi

ssh_port="${SSH_PORT:-22}"
ssh_mode="${OURBOX_INSTALLER_SSH_MODE:-key}"
installer_user="${OURBOX_INSTALLER_SSH_USER:-ourbox-installer}"
installer_key="${OURBOX_INSTALLER_SSH_KEY:-}"
installer_password="${OURBOX_INSTALLER_SSH_PASSWORD:-}"
expect_root_login="${EXPECT_ROOT_LOGIN:-1}"
root_password="${ROOT_SSH_PASSWORD:-}"
diagnose_log_path="${DIAGNOSE_LOG_PATH:-${JETSON_FLASH_WORKDIR:-${XDG_CACHE_HOME:-$HOME/.cache}/jetson-flash}/logs/diagnose_initrd.log}"

case "${ssh_mode}" in
  off|key|password|both) ;;
  *) echo "Invalid OURBOX_INSTALLER_SSH_MODE=${ssh_mode}" >&2; exit 1 ;;
esac
case "${expect_root_login}" in
  0|1) ;;
  *) echo "Invalid EXPECT_ROOT_LOGIN=${expect_root_login}" >&2; exit 1 ;;
esac

need_cmd ssh

ssh_opts=(
  -6
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o ConnectTimeout=5
  -p "${ssh_port}"
)

check_port() {
  if command -v nc >/dev/null 2>&1; then
    nc -z -6 -w 3 "${host}" "${ssh_port}" >/dev/null 2>&1
    return
  fi
  if command -v ssh-keyscan >/dev/null 2>&1; then
    ssh-keyscan -6 -T 3 -p "${ssh_port}" "${host}" >/dev/null 2>&1
    return
  fi
  ssh -o PreferredAuthentications=none -o NumberOfPasswordPrompts=0 "${ssh_opts[@]}" "root@${host}" "true" >/dev/null 2>&1
}

installer_auth="none"

installer_ssh() {
  local remote_cmd="${1:?remote command required}"
  case "${installer_auth}" in
    key)
      ssh "${ssh_opts[@]}" -i "${installer_key}" "${installer_user}@${host}" "${remote_cmd}"
      ;;
    password)
      SSHPASS="${installer_password}" sshpass -e ssh "${ssh_opts[@]}" "${installer_user}@${host}" "${remote_cmd}"
      ;;
    *)
      echo "No installer auth method selected." >&2
      return 1
      ;;
  esac
}

echo "==> [1/4] Checking sshd is listening on [${host}]:${ssh_port}"
check_port || {
  echo "FAIL: sshd is not reachable on [${host}]:${ssh_port}" >&2
  exit 1
}
echo "PASS: ssh port reachable"

echo "==> [2/4] Checking root automation SSH expectation (EXPECT_ROOT_LOGIN=${expect_root_login})"
if [[ "${expect_root_login}" == "1" ]]; then
  if [[ -n "${root_password}" ]]; then
    need_cmd sshpass
    SSHPASS="${root_password}" sshpass -e ssh "${ssh_opts[@]}" "root@${host}" "true" >/dev/null
    echo "PASS: root password login succeeded"
  else
    echo "WARN: ROOT_SSH_PASSWORD not set; skipped definitive root login success check"
  fi
else
  if ssh -o BatchMode=yes "${ssh_opts[@]}" "root@${host}" "true" >/dev/null 2>&1; then
    echo "FAIL: root login succeeded with EXPECT_ROOT_LOGIN=0" >&2
    exit 1
  fi
  if [[ -n "${root_password}" ]]; then
    need_cmd sshpass
    if SSHPASS="${root_password}" sshpass -e ssh "${ssh_opts[@]}" "root@${host}" "true" >/dev/null 2>&1; then
      echo "FAIL: root password login succeeded with EXPECT_ROOT_LOGIN=0" >&2
      exit 1
    fi
  fi
  echo "PASS: root login blocked as expected"
fi

echo "==> [3/4] Checking ${installer_user} login using mode=${ssh_mode}"
case "${ssh_mode}" in
  off)
    if ssh -o BatchMode=yes "${ssh_opts[@]}" "${installer_user}@${host}" "true" >/dev/null 2>&1; then
      echo "FAIL: ${installer_user} login succeeded but mode=off" >&2
      exit 1
    fi
    echo "PASS: ${installer_user} login blocked as expected (mode=off)"
    ;;
  key)
    [[ -n "${installer_key}" ]] || {
      echo "FAIL: mode=key requires OURBOX_INSTALLER_SSH_KEY" >&2
      exit 1
    }
    ssh -o BatchMode=yes "${ssh_opts[@]}" -i "${installer_key}" "${installer_user}@${host}" "true" >/dev/null
    installer_auth="key"
    echo "PASS: ${installer_user} key login succeeded"
    ;;
  password)
    [[ -n "${installer_password}" ]] || {
      echo "FAIL: mode=password requires OURBOX_INSTALLER_SSH_PASSWORD" >&2
      exit 1
    }
    need_cmd sshpass
    SSHPASS="${installer_password}" sshpass -e ssh "${ssh_opts[@]}" "${installer_user}@${host}" "true" >/dev/null
    installer_auth="password"
    echo "PASS: ${installer_user} password login succeeded"
    ;;
  both)
    if [[ -n "${installer_key}" ]]; then
      ssh -o BatchMode=yes "${ssh_opts[@]}" -i "${installer_key}" "${installer_user}@${host}" "true" >/dev/null
      installer_auth="key"
      echo "PASS: ${installer_user} key login succeeded"
    else
      [[ -n "${installer_password}" ]] || {
        echo "FAIL: mode=both requires key or password input" >&2
        exit 1
      }
      need_cmd sshpass
      SSHPASS="${installer_password}" sshpass -e ssh "${ssh_opts[@]}" "${installer_user}@${host}" "true" >/dev/null
      installer_auth="password"
      echo "PASS: ${installer_user} password login succeeded"
    fi
    ;;
esac

echo "==> [4/4] Checking logs for leaked secrets"
if [[ -f "${diagnose_log_path}" ]]; then
  ! grep -E -q 'sshpass -p |password: ourbox-install|ubuntu:ourbox-install' "${diagnose_log_path}"
  echo "PASS: local diagnose log contains no known secret patterns"
else
  echo "WARN: local diagnose log not found at ${diagnose_log_path}; skipped local leak scan"
fi

if [[ "${installer_auth}" != "none" ]]; then
  installer_ssh "for f in /run/ourbox-installer.log /var/log/messages; do [ -f \"\$f\" ] && grep -E -q 'ourbox-install|password:' \"\$f\" && exit 1; done; exit 0"
  echo "PASS: remote quick log scan contains no known secret patterns"
else
  echo "WARN: no installer login method available; skipped remote leak scan"
fi

echo "All initrd SSH smoke checks passed for [${host}]"
