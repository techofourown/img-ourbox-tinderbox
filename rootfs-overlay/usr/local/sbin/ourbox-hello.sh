#!/usr/bin/env bash
set -euo pipefail

echo
echo "############################################################"
echo "#  Hello Tinderbox 👋                                       #"
echo "############################################################"
echo

if [[ -r /proc/device-tree/model ]]; then
  model="$(tr -d '\0' </proc/device-tree/model)"
  echo "Model: ${model}"
fi

echo "Kernel: $(uname -a)"
echo "Uptime: $(uptime -p || true)"
echo

echo "Root filesystem:"
findmnt / || true
echo

echo "Block devices:"
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,FSTYPE,LABEL,MODEL || true
echo

if mountpoint -q /data; then
  echo "/data is mounted:"
  df -h /data || true
else
  echo "/data is not mounted (firstboot may still be running)."
fi

echo
echo "Journal hint:"
echo "  sudo journalctl -u ourbox-hello -u ourbox-firstboot --no-pager"
echo
