#!/bin/bash
# This script is used to build the kernel and initramfs on Gentoo Linux.

#Required 
#The UUID of your disk. systemd-boot needs it. be careful!
# Note: if using LVM, this should be the LVM partition.
ROOT_UUID=""

#Optional
# Any rootflags you wish to set. For example, mine are currently
# "subvol=@ quiet splash intel_pstate=enable".
CMDLINE=""

# Secure boot key and cert
# If you want to sign your kernel with a secure boot key, set this to the path of your key.
# if you added your key and cert to in the make.conf, you can leave it blank.
SECUREBOOT_SIGN_KEY=""
SECUREBOOT_SIGN_CERT=""

# Path to kernel source directory: Default is "/usr/src/linux"
KERNEL_DIR="/usr/src/linux"

die() {
  printf '\033[1;31mERROR:\033[0m %s\n' "$@" >&2  # bold red
  exit 1
}

einfo() {
  printf '\033[1;32mINFO:\033[0m %s\n' "$@" >&2  # bold green
}

ewarn() {
  printf '\033[1;33mWARN:\033[0m %s\n' "$@" >&2  # bold yellow
}

# getopts options
while getopts ":hcilsra" opt; do
  case $opt in
    h)
      printf "Usage: %s: [-h] [-c] [-i] [-l] [-s] [-r] [-a] \n" "$0"
      printf "  -h  Show this help message\n"
      printf "  -c  Configure and compile kernel\n"
      printf "  -i  Build, Install kernel and initramfs\n"
      printf "  -l  Update boot system(grub or systemd-boot)\n"
      printf "  -s  Sign kernel with secure boot key and cert\n"
      printf "  -r  Remove old kernel(s) and initramfs(exclude last 2 kernel(s))\n"
      printf "  -a  All of the above(execute all options)\n"
      exit 0
      ;;
    c)
      COMPILE_KERNEL="true"
      ;;
    i)
      INSTALL_KERNEL="true"
      ;;
    l)
      UPDATE_BOOT_SYSTEM="true"
      ;;
    s)
      SIGN_KERNEL="true"
      ;;
    r)
      REMOVE_OLD_KERNEL="true"
      ;;
    a)
      COMPILE_KERNEL="true"
      INSTALL_KERNEL="true"
      UPDATE_BOOT_SYSTEM="true"
      SIGN_KERNEL="true"
      REMOVE_OLD_KERNEL="true"
      ;;
    \?)
      die "Invalid option: -$OPTARG"
      ;;
  esac
done

#check getopts options
if [ "$#" -eq 0 ]; then
  die "No options specified. See -h for help."
fi

pushd_quiet() {
    pushd "$1" &>/dev/null || die "Failed to enter $1."
}

popd_quiet() {
    popd &>/dev/null || die "Failed to leave $1."
}

build_initramfs() {
	printf "\n"
	einfo "Starting to building initramfs..please wait..."
	is_installed "sys-kernel/genkernel"
  vendor=$(grep -m 1 vendor_id /proc/cpuinfo | awk '{ printf "%s\n", $3 }')
	if [ "$vendor" == "GenuineIntel" ]; then
		is_installed "sys-firmware/intel-microcode"
		genkernel --install --no-ramdisk-modules --lvm --microcode initramfs || die "Failed to build initramfs"
	else
		genkernel --install --no-ramdisk-modules --lvm initramfs || die "Failed to build initramfs"
	fi
	einfo "Initramfs built successfully."
}

is_installed() {
  package=$1
  package_test=$(equery -q list "$package")
  if [ -z "${package_test}" ]; then
    install_package "$package"
  fi
}

install_package() {
	emerge -q "$@"
	if [ $? -eq 1 ]; then
		etc-update --automode -5
		emerge -q "$@" || die "Failed to install $1"
	fi
	env-update && source /etc/profile
}


compile_kernel () {
  printf "\n"
  einfo "Cleaning up kernel source tree..."
  pushd_quiet "$KERNEL_DIR"
  make -s mrproper || die "Failed to clean kernel source tree"
  printf "\n"
  einfo "Copying kernel config..."
  # try to multiple methods to copy the kernel config
  if [ -f /etc/kernels/kernel-config-"$(uname -m)" ]; then
    cp /etc/kernels/kernel-config-"$(uname -m)" .config || die "Failed to copy kernel config"
  elif [ -f /proc/config.gz ]; then
    zcat /proc/config.gz > .config || die "Failed to copy kernel config"
  elif [ -f /boot/config-"$(uname -r)" ]; then
    cp /boot/config-"$(uname -r)" .config || die "Failed to copy kernel config"
  else
    die "Failed to find kernel config"
  fi
  printf "\n"
  einfo "Starting to compile kernel...please wait..."
  if [ -f /etc/portage/make.conf ]; then
    source /etc/portage/make.conf
  fi
  printf "\n"
  einfo "Configuring kernel..."
  make -s olddefconfig || die "Failed to configure kernel"
  printf "\n"
  einfo "Compiling kernel..."
  make -s ARCH="$(uname -m)" "${MAKEOPTS}"  bzImage || die "Failed to compile kernel"
  printf "\n"
  einfo "Compiling kernel modules..."
  make -s ARCH="$(uname -m)" "${MAKEOPTS}" modules || die "Failed to compile kernel modules"
  printf "\n"
  einfo "Kernel and Modules compiled successfully."
  popd_quiet "$KERNEL_DIR"
}

#install kernel and modules
install_kernel() {
  printf "\n"
  einfo "Installing kernel and modules..."
  pushd_quiet "$KERNEL_DIR"
  make -s INSTALL_MOD_STRIP=1 modules_install || die "Failed to install kernel modules"
  make -s install || die "Failed to install kernel"
  printf "\n"
  einfo "Kernel and modules installed successfully."
  popd_quiet "$KERNEL_DIR"
}

# this function find installed kernel(s) in /boot and create bash array
find_kernels() {
  local KERNELS=()
  readarray -t FOUND_KERNEL < <(find /boot -maxdepth 1 -name 'vmlinuz-*' -type f -not -name '*.old' -print0 | xargs -r -0 ls -t | sort -n)
  # remove basename from kernel path and add to array
  for i in "${FOUND_KERNEL[@]}"; do
    KERNEL=("$(basename "$i")")
    KERNELS+=("${KERNEL:8}")
  done
  # return array
  echo "${KERNELS[@]}"
}

# this function create systemd-boot entry given kernel version
create_systemd_entry() {
  VERSION=$1
  FILENAME=$2
  cat <<EOF > /boot/loader/entries/"${FILENAME}".conf
title Gentoo Linux ${VERSION}
linux /vmlinuz-${VERSION}
initrd /initramfs-${VERSION}.img
options root=UUID=${ROOT_UUID} ${CMDLINE}
EOF
}

update_grub() {
  printf "\n"
  einfo "Updating grub..."
  # check if boot partition is mounted and
  # grub is installed
  if ! mount | grep -qs "/boot" ; then
    ewarn "Boot partition is not mounted or separate boot partition not found"
  elif [ ! -d "/boot/grub" ]; then
    die "/boot/grub directory not found. Please emerge sys-boot/grub:2"
  else
    grub-mkconfig -o /boot/grub/grub.cfg || die "Failed to update grub"
  fi
}

update_systemd_boot() {
  printf "\n"
  einfo "Updating systemd-boot..."
  # check if boot partition is mounted and
  # systemd-boot is installed
  if ! mount | grep -qs "/boot" ; then
    ewarn "Boot partition is not mounted or separate boot partition not found"
  elif [ ! -d "/boot/loader" ]; then
    die "/boot/loader directory not found. Please emerge sys-boot/systemd-boot"
  fi
  # check if >=systemd-254 is installed with boot use flag(older versions is required to install with gnu-efi use flag)
  if ! equery -N -C uses systemd | grep -e '^ + [-+] boot' -e '^ + [-+] gnuefi' -qs; then
    die "sys-boot/systemd must be installed with boot use flag"
  fi
  # create local array from find_kernels function
  local KERNELS=()
  IFS=" " read -r -a KERNELS <<< "$(find_kernels)"; unset IFS
  # check if kernel(s) found
  if [ "${#KERNELS[@]}" -eq 0 ]; then
    die "No kernel(s) found in /boot"
  fi
  # create systemd-boot entry for latest kernel
  LATEST_KERNEL="${KERNELS[-1]}"
  einfo "Creating systemd-boot entry for ${LATEST_KERNEL}"
  create_systemd_entry "${LATEST_KERNEL}" "gentoo" || die "Failed to create systemd-boot entry"
  # create previous kernel entries
  for i in "${!KERNELS[@]}"; do
    if [ "$i" -gt 0 ]; then
      PREV_KERNEL="${KERNELS[$i-1]}"
      einfo "Creating systemd-boot entry for ${PREV_KERNEL}"
      create_systemd_entry "${PREV_KERNEL}" "gentoo-${PREV_KERNEL}" || die "Failed to create systemd-boot entry"
    fi
  done
  printf "\n"
  einfo "Updating systemd-boot firmware ..."
  # disabled below line because 'bootctl update' exit with error code 1
  # But It works fine. So, I dont check exit code.
#  bootctl update || die "Failed to update systemd-boot firmware"
  bootctl -q update
  einfo "Systemd-boot updated successfully."
}

# detect and update boot system: systemd-boot or grub
update_boot_system() {
  printf "\n"
  einfo "Detecting boot system..."
  # check if boot partition is mounted
  if ! mount | grep -qs "/boot" ; then
    ewarn "Boot partition is not mounted or separate boot partition not found"
  fi
  # check if systemd-boot is installed
  if [ -d "/boot/loader" ]; then
    update_systemd_boot
  elif [ -d "/boot/grub" ]; then
    update_grub
  else
    die "Boot system not found"
  fi
}

# sign kernel with secure boot key and cert
sign_kernel () {
  printf "\n"
  einfo "Signing kernel with secure boot key and cert..."
  # check if secure boot key and cert is set
  if [ -n "$SECUREBOOT_SIGN_KEY" ] && [ -n "$SECUREBOOT_SIGN_CERT" ]; then
    einfo "Secure boot key and cert is set in build-kernel.sh"
  elif [ -f /etc/portage/make.conf ]; then
    source /etc/portage/make.conf
    if [ -n "$SECUREBOOT_SIGN_KEY" ] && [ -n "$SECUREBOOT_SIGN_CERT" ]; then
      einfo "Secure boot key and cert is set in make.conf"
    else
      die "Secure boot key and cert is not set"
    fi
  fi
  # check if sbsign is installed
  is_installed "app-crypt/sbsigntools"
  # create local array from find_kernels function
  local KERNELS=()
  IFS=" " read -r -a KERNELS <<< "$(find_kernels)"; unset IFS
  # check if kernel(s) found
  if [ "${#KERNELS[@]}" -eq 0 ]; then
    die "No kernel(s) found in /boot"
  fi
  # sign kernel(s)
  for i in "${!KERNELS[@]}"; do
    einfo "Signing kernel ${KERNELS[$i]}"
    sbsign --key "$SECUREBOOT_SIGN_KEY" --cert "$SECUREBOOT_SIGN_CERT" --output "/boot/vmlinuz-${KERNELS[$i]}" "/boot/vmlinuz-${KERNELS[$i]}" || die "Failed to sign kernel"
  done
}

# remove old kernel(s) and initramfs exclude last 2 kernel(s)
remove_old_kernel() {
  # create local array from find_kernels function
  local KERNELS=()
  IFS=" " read -r -a KERNELS <<< "$(find_kernels)"; unset IFS
  # check if kernel(s) found
  if [ "${#KERNELS[@]}" -eq 0 ]; then
    die "No kernel(s) found in /boot"
  fi
  # remove old kernel(s) exclude last 2 kernel(s)
  for i in "${!KERNELS[@]}"; do
    if [ "$i" -lt $((${#KERNELS[@]}-2)) ]; then
      einfo "Removing old kernel ${KERNELS[$i]} from /boot"
      rm -f "/boot/vmlinuz-${KERNELS[$i]}" || die "Failed to remove kernel"
      rm -f "/boot/System.map-${KERNELS[$i]}" || die "Failed to remove System.map"
      rm -f "/boot/config-${KERNELS[$i]}" || die "Failed to remove config"
      rm -f "/boot/initramfs-${KERNELS[$i]}.img" || die "Failed to remove initramfs"
      einfo "Removing old kernel ${KERNELS[$i]} from /lib/modules"
      rm -rf "/lib/modules/${KERNELS[$i]}" || die "Failed to remove kernel modules"
      einfo "Removing old kernel ${KERNELS[$i]} from /usr/src"
      rm -rf "/usr/src/linux-${KERNELS[$i]}" || die "Failed to remove kernel source"
      einfo "Removing old kernel systemd-boot entry"
      rm -f "/boot/loader/entries/gentoo-${KERNELS[$i]}.conf" || die "Failed to remove systemd-boot entry"
    else
      einfo "Keeping kernel ${KERNELS[$i]}"
    fi
  done
}

# control_c()
# Trap Ctrl-C for a quick and clean exit when necessary
control_c() {
	echo "Control-c pressed - exiting NOW"
	exit 1
}

# Trap any ctrl+c and call control_c function provided through functions.sh
trap control_c SIGINT

banner() {
	printf "\n"
	printf "============================================================= \n"
	printf "Gentoo Linux kernel build \n"
	printf "https://github.com/mofm/kernel-build \n"
	printf "============================================================= \n"
	printf "\n"
	printf "If you run into any problems, please open an issue so it can fixed. Thanks! \n"
}

banner

# check if user is root
if [ "$EUID" -ne 0 ]; then
  die "Please run as root"
fi

# compile kernel
if [ "$COMPILE_KERNEL" == "true" ]; then
  compile_kernel
fi

# install kernel and modules and build initramfs
if [ "$INSTALL_KERNEL" == "true" ]; then
  install_kernel
  build_initramfs
fi

# sign kernel with secure boot key and cert
if [ "$SIGN_KERNEL" == "true" ]; then
  sign_kernel
fi

# update boot system
if [ "$UPDATE_BOOT_SYSTEM" == "true" ]; then
  update_boot_system
fi

# remove old kernel(s) and initramfs
if [ "$REMOVE_OLD_KERNEL" == "true" ]; then
  remove_old_kernel
fi
