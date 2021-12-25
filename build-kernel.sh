#!/bin/bash

#Required 
#The UUID of your disk. systemd-boot needs it. be careful!
# Note: if using LVM, this should be the LVM partition.
UUID=""

#Optional
# Any rootflags you wish to set. For example, mine are currently
# "subvol=@ quiet splash intel_pstate=enable".
ROOTFLAGS=""

build_initramfs() {
	printf "\n"
	printf "Starting to building initramfs..please wait...\n"
	is_installed "sys-kernel/genkernel"
	vendor=$(cat /proc/cpuinfo | grep -m 1 vendor_id | awk '{ printf "%s\n", $3 }')
	if [ $vendor == "GenuineIntel" ]; then
		is_installed "sys-firmware/intel-microcode"
		genkernel --install --no-ramdisk-modules --lvm --microcode initramfs
	else
		genkernel --install --no-ramdisk-modules --lvm initramfs
	fi
}

is_installed() {
	package=$1
    package_test=$(equery -q list "$package")
    if [ -z ${package_test} ]; then
		install_package "$package"
    fi
}

install_package() {
	emerge -q $@
	if [ $? -eq 1 ]; then
		etc-update --automode -5
		emerge -q $@
	fi
	env-update && source /etc/profile
}

compile_kernel() {
	printf "\n"
	printf "Cleaning directory... \n"
	cd /usr/src/linux
	make clean
	printf "\n"
	printf "Copying old config... \n"
	modprobe configs
	if [ $? -gt 0 ]; then
		printf "Error: failed to probe configs kernel module, must not be enabled - try another method. \n"
	fi
	zcat /proc/config.gz > /usr/src/linux/.config
	if [ $? -gt 0 ]; then
		CONFIG=$(find /boot -maxdepth 1 -name 'config-*' -type f -not -name '*.old' -print0 | xargs -r -0 ls -t | tail -1)
		cp ${CONFIG} /usr/src/linux/.config
	else
		printf "Error: failed to copy kernel config file to /usr/src/linux/.config - try another method. \n"
		exit 1
	fi
	printf "\n"
	printf "Starting to build kernel.. please wait... \n"
	source /etc/portage/make.conf
	printf "\n"
        printf "Configure Kernel\n"
        make olddefconfig
	printf "\n"
	printf "Compiling bzImage\n"
	make ARCH=$(uname -m) ${MAKEOPTS} bzImage
	if [ $? -eq 0 ]; then
		printf "\n"
		printf "Compiling modules\n"
		make ARCH=$(uname -m) ${MAKEOPTS} modules
		printf "\n"
		printf "compiling finished. installing kernel and modules\n"
		make INSTALL_MOD_STRIP=1 modules_install
		make install
	fi
}

update_grub() {
	printf "\n"
	printf "Updating grub config\n"
	printf "\n"
	isBootMounted=$(mount | grep /boot)
	if [ -z "${isBootMounted}" ]; then
		printf "Warning: /boot is not mounted - mount before attempting to proceed with GRUB update. \n"
		exit 1
	elif [ ! -d /boot/grub/ ]; then
		printf "\n"
		printf "Error: /boot/grub/ directory does not exist. Please emerge sys-boot/grub:2 \n"
		exit 1
	fi
	printf "\n"
	grub-mkconfig -o /boot/grub/grub.cfg
	if [ $? -gt 0 ]; then
		printf "Error: didn't create grub.cfg. \n"
		exit 1
	fi
}

update_systemd() {
	printf "\n"
	printf "Updating systemd-boot\n"
	isBootMounted=$(mount | grep /boot)
	if [ -z "${isBootMounted}" ]; then
		printf "Warning: /boot is not mounted - mount before attempting to proceed with systemd-boot update. \n"
		exit 1
	elif [ ! -d /boot/loader/ ]; then
		printf "Error: /boot/loader/ directory does not exist. Please install systemd-boot loader with 'bootctl install'. \n"
		exit 1
	fi
	equery -N -C uses systemd | grep '^ + + gnuefi'
	if [ $? -gt 0 ]; then
		printf "Error: systemd doesn't support efi. please enable gnuefi useflag and re-emerge. \n"
		exit 1
	fi

	# Our kernels.
	KERNELS=()
	FIND="find /boot -maxdepth 1 -name 'vmlinuz-*' -type f -not -name '*.old' -print0 | sort -Vrz"
	while IFS= read -r -u3 -d $'\0' LINE; do
		KERNEL=$(basename "${LINE}")
		KERNELS+=("${KERNEL:8}")
	done 3< <(eval "${FIND}")

	# There has to be at least one kernel.
	if [ ${#KERNELS[@]} -lt 1 ]; then
		echo -e "\e[2msystemd-boot\e[0m \e[1;31mNo kernels found.\e[0m"
		exit 1
	fi

	# Copy the latest kernel files to a consistent place so we can
	# keep using the same loader configuration.
	LATEST="${KERNELS[@]:0:1}"
	echo -e "\e[2msystemd-boot\e[0m \e[1;32m${LATEST}\e[0m"
	cat << EOF > /boot/loader/entries/gentoo.conf
title   Gentoo Linux
linux   /vmlinuz-${LATEST}
initrd  /initramfs-${LATEST}.img
options root=UUID=${UUID} rw ${ROOTFLAGS}
EOF

	# Copy any legacy kernels over too, but maintain their version-
	# based names to avoid collisions.
	if [ ${#KERNELS[@]} -gt 1 ]; then
		LEGACY=("${KERNELS[@]:1}")
		for VERSION in "${LEGACY[@]}"; do
		    echo -e "\e[2msystemd-boot\e[0m \e[1;32m${VERSION}\e[0m"
		    cat << EOF > /boot/loader/entries/gentoo-${VERSION}.conf
title   Gentoo Linux ${VERSION}
linux   /vmlinuz-${VERSION}
initrd  /initramfs-${VERSION}.img
options root=UUID=${UUID} rw ${ROOTFLAGS}
EOF
		done
	fi

	printf "\n"
	printf "Updating systemd-boot firmware \n"
	bootctl update

	# Success!
	echo -e "\e[2m---\e[0m"
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
	printf "Gentoo kernel build \n"
	printf "https://github.com/mofm/kernel-build \n"
	printf "============================================================= \n"
	printf "\n"
	printf "If you run into any problems, please open an issue so it can fixed. Thanks! \n"
}

banner

# check root privileges and
# do nothing if both versions are the same
new_kernel_ver=$(readlink /usr/src/linux | sed 's/^linux-//');
current_kernel_ver=$(uname -r | sed 's/-x86_64$//');
if [ "$EUID" -ne 0 ]; then
	printf "\n"
	printf "Warning: Please run this script as root privileges. \n"
	exit 1
elif [ ${new_kernel_ver} == ${current_kernel_ver} ]; then
	printf "\n"
	printf "Warning: eselect kernel was unset, please set it. \n"
	exit 1
fi

if [ $1 == "systemd-boot" ]; then
	if [ -z "$UUID" ]; then
		printf "Error: Please add rootfs UUID. aborted. \n"
		exit 1
	else
		compile_kernel
		build_initramfs
		#rebuild modules
		emerge -1 @module-rebuild
		update_systemd
	fi
elif [ $1 == "grub2" ]; then
	compile_kernel
	build_initramfs
	#rebuild modules
	emerge -1 @module-rebuild
	update_grub
else
	printf "Error: Please select loader: systemd-boot or grub2 \n"
	exit 1
fi

# clean old kernel
printf "\n"
printf "Cleaning old kernel, modules and files. \n"
rm -rf /boot/{config,vmlinuz,System.map}-${current_kernel_ver}
rm -rf /boot/initramfs-${current_kernel_ver}.img
rm -rf /lib/modules/${current_kernel_ver}

printf "\n" 
printf "Complete! \n"

