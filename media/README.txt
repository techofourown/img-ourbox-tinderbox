TINDERBOX INSTALLER MEDIA (OFFLINE)

This USB drive contains:
- Linux_for_Tegra (Jetson Linux / L4T) staged for JetPack base flashing
- a CLI-only flasher script for Jetson Orin NX 8GB/16GB

USAGE (on an Ubuntu x86_64 flashing host):
1) Put Jetson into Force Recovery Mode and connect it via USB to this host
2) From this directory, run:

  sudo ./flash-jetson.sh

NOTES:
- This tool REFUSES to flash anything except Orin NX 8GB/16GB.
- The OS NVMe will be erased.
- The DATA NVMe is formatted on first boot and mounted at /data.
