# [0.1.0](https://github.com/techofourown/img-ourbox-tinderbox/compare/v0.0.0...v0.1.0) (2026-02-27)


### Bug Fixes

* ensure usb0 udev rule prevents flash NFS failure ([700667a](https://github.com/techofourown/img-ourbox-tinderbox/commit/700667a7e16893b1b8dafacfddf82fd8267027af))
* **flash:** harden USB link to prevent disconnect during rootfs transfer ([a6e2ae5](https://github.com/techofourown/img-ourbox-tinderbox/commit/a6e2ae55424726e1ee953ca72e66da055f316f5d))
* **flash:** restart NFS stack before flashing to prevent APP rootfs failure ([85ba3c5](https://github.com/techofourown/img-ourbox-tinderbox/commit/85ba3c5d2d878296f74b54a4d3b67fc086ca73b1))
* harden flash-jetson.sh against NFS/RPC/VPN/firewall/sleep failures ([7374018](https://github.com/techofourown/img-ourbox-tinderbox/commit/73740184bbc6e48d1dd34bdca9e3fa88d4b282f8))
* retry loop for jetson recovery mode detection ([548a5e5](https://github.com/techofourown/img-ourbox-tinderbox/commit/548a5e56d904ec1e791da4c6cee5e3d9d6e27068))
* stage Linux_for_Tegra to local disk before flashing ([d3f7f55](https://github.com/techofourown/img-ourbox-tinderbox/commit/d3f7f558c33c1987e130c2c41d897e744064349e))


### Features

* add fetch-nvidia-artifacts script and usability improvements ([21a0dd4](https://github.com/techofourown/img-ourbox-tinderbox/commit/21a0dd4a8a64ae63ab993be18c1128c62dddea5e))
* add usb-only hard filter for installer media selection ([c70666d](https://github.com/techofourown/img-ourbox-tinderbox/commit/c70666d29caf1b849e7acca38f409d7f2ac688e1))
* **flash:** add caching, telemetry injection, and diagnose mode ([3a6a2b7](https://github.com/techofourown/img-ourbox-tinderbox/commit/3a6a2b7d58d0edc5ef5d7d624e56befb3f506a00))
* **flash:** add Orin Nano NVMe flash script with artifact fetch and clean gitignore ([bfa8ced](https://github.com/techofourown/img-ourbox-tinderbox/commit/bfa8ced01bb23d648abb171e8313c70b9a9eb702))
* pre-install flash deps and improve nvme selection ux ([faa2a83](https://github.com/techofourown/img-ourbox-tinderbox/commit/faa2a83cef3c5fd68db0358ae05c8db115bf0e47))
