# Kernel Build

Kernel configuration copying, compile, grub2 and systemd-boot updating, old kernel cleaning script for Gentoo Linux.

## Usage

* First, clone this repository and change directory:

```sh
git clone https://github.com/mofm/kernel-build.git
cd kernel-build
```

* Change script permissons:

```sh
chmod +x build-kernel.sh
```

* If you are using **systemd-boot** you should first learn rootfs disk **UUID** or **LVM** partitions and then add it to the script:


```sh
UUID="dfc588c0-edd4-8543-a3fe-d7d49bd8f141"
```

**Optional:** *You can add specific kernel parameters to ROOTFLAGS.* Example:

```
ROOTFLAGS="ro init=/usr/lib/systemd/systemd rootfstype=ext4 quiet"
```

Now you execute the script like so

 ```sh
 ./build-kernel.sh systemd-boot
 ```

 * If you are using **grub2**:
 
 ```sh
 ./build-kernel.sh grub2
 ```

---
 **NOTE**: This script only cleans the previous kernel.
---
