# Kernel Build

Kernel configuration copying, compile, grub2 and systemd-boot updating, old kernel cleaning script for Gentoo Linux.

## Usage

* If you are using **systemd-boot** you should first learn rootfs disk **UUID** or **LVM** partitions and then add it to the script:


```sh
ROOT_UUID="dfc577c0-edd4-8543-a3fe-d7d49bd8f141"
```

**Optional:** *You can add specific kernel parameters to CMDLINE.* Example:

```
CMDLINE="ro init=/usr/lib/systemd/systemd rootfstype=ext4 quiet"
```

```
Usage: ./build-kernel.sh: [-h] [-c] [-i] [-l] [-s] [-r] [-a] 
  -h  Show this help message
  -c  Configure and compile kernel
  -i  Build, Install kernel and initramfs
  -l  Update boot system(grub or systemd-boot)
  -s  Sign kernel with secure boot key and cert
  -r  Remove old kernel(s) and initramfs(exclude last 2 kernel(s))
  -a  All of the above (execute all options)
```

NOTE: I have rewritten the script. If you are using the old version, you should update it.