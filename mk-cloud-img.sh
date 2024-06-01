#!/bin/bash

# Sources of inspiration:
# https://github.com/mvallim/cloud-image-ubuntu-from-scratch
# https://docs.zfsbootmenu.org/en/v2.3.x/guides/ubuntu/uefi.html

set -e

# Global Variables
DEB_CACHE_DIR=/home/df/src/ubuntu-jammi-zfs-cloud/debcache
PROXY_SERVER="127.0.0.1"
PROXY_PORT=3142
TARGET_REPO_URL="http://archive.ubuntu.com/ubuntu/"
TARGET_TIMEZONE="Europe/Berlin"
TARGET_UTF8_LOCALES="en_US de_DE"
TARGET_HOSTNAME="mycloudimg"
TARGET_ZPOOL="croot"
TARGET_IMAGE_PATH=$(pwd)
TARGET_IMAGE_NAME="ubuntu-cloudimg-zfs.raw"
TARGET_ROOT_MOUNTPOINT=$(pwd)/tmp_root

# Inherited from ZBM setup procedure.
BOOT_PART="1"
POOL_PART="2"
ID="ubuntu"

error_report() {
	echo "Error on line $1"
}

trap 'error_report $LINENO' ERR

msg() {
	echo "$1"
}

error() {
	msg "$1"
	exit ${2:-1}
}

cmd() {
	echo "$@"
	$@
}

cmd_quiet() {
	echo "$@"
	$@ 2>&1 > /dev/null
}

target_cmd() {
	# Execute commands in chroot
	cmd chroot $TARGET_ROOT_MOUNTPOINT $@
}

create_img_file() {
	# Do some checking to prevent screwing up things...
	local file="${TARGET_IMAGE_PATH}/${TARGET_IMAGE_NAME}"
	[ -e ${file} ] && error "${file} does already exist."
	msg "Creating image file ${file}."
	cmd dd if=/dev/zero of=${file} bs=1 count=0 seek=32212254720
}

format_image_file() {
	# Make sure the image file does exist.
	local file="${TARGET_IMAGE_PATH}/${TARGET_IMAGE_NAME}"
	[ ! -e ${file} ] && error "${file} does not exist. Cannot create partitions."
	# Parition the disk image for UEFI booting + ZFS Pool.
	cmd_quiet sgdisk -n "${BOOT_PART}:1m:+512m" -t "${BOOT_PART}:ef00" "$file"
	cmd_quiet sgdisk -n "${POOL_PART}:0:-10m" -t "${POOL_PART}:bf00" "$file"
}


create_loop_device() {
	# Make sure the image file does exist.
	local file="${TARGET_IMAGE_PATH}/${TARGET_IMAGE_NAME}"
	[ ! -e ${file} ] && error "${file} does not exist. Cannot create loop device."
	# Cannot use cmd here, since the substitution would lead to something like
	# LOOP_DEVICE=/dev/loopN which is not supposed to be executed.
	LOOP_DEVICE=$(losetup --find --show -P ${file})
}

destroy_loop_device() {
	# Doing some cleanup after we are done ;)
	msg "Destroying loop device."
	cmd losetup -d "$LOOP_DEVICE"
}

setup_disk() {
	# To be run after the loop device is known.
	BOOT_DISK="${LOOP_DEVICE}"
	BOOT_DEVICE="${BOOT_DISK}p${BOOT_PART}"

	# We are using a single virtual disk for both, booting and pool.
	POOL_DISK="${BOOT_DISK}"
	POOL_DEVICE="${POOL_DISK}p${POOL_PART}"

	cmd zpool create -f -o ashift=12 \
	 -O compression=lz4 \
	 -O acltype=posixacl \
	 -O xattr=sa \
	 -O relatime=on \
	 -o autotrim=on \
	 -o compatibility=openzfs-2.1-linux \
	 -m none "$TARGET_ZPOOL" "$POOL_DEVICE"

	# Create initial file systems
	cmd zfs create -o mountpoint=none ${TARGET_ZPOOL}/ROOT
	cmd zfs create -o mountpoint=/ -o canmount=noauto ${TARGET_ZPOOL}/ROOT/${ID}
	cmd zfs create -o mountpoint=/home ${TARGET_ZPOOL}/home

	cmd zpool set bootfs=${TARGET_ZPOOL}/ROOT/${ID} "$TARGET_ZPOOL"

	# Format the efi boot partition.
	cmd mkfs.vfat -F32 "$BOOT_DEVICE"
}

export_zpool() {
	# Export TARGET_ZPOOL if it exists.
	local pool
	for pool in $(zpool list -Ho name) ; do
	[ "$pool" == "$TARGET_ZPOOL" ] && cmd zpool export "$TARGET_ZPOOL"
	# Give the export some time to complete.
	sleep 1
	done
}

mount_filesystems() {
	[ -d $TARGET_ROOT_MOUNTPOINT ] || cmd mkdir -p $TARGET_ROOT_MOUNTPOINT
	msg "Importing zpool $TARGET_ZPOOL to $TARGET_ROOT_MOUNTPOINT."
	cmd zpool import -N -R $TARGET_ROOT_MOUNTPOINT $TARGET_ZPOOL
	cmd zfs mount ${TARGET_ZPOOL}/ROOT/${ID}
	cmd zfs mount ${TARGET_ZPOOL}/home

	mount -t zfs | grep ${TARGET_ZPOOL}

	# Mount the efi partition
	cmd mkdir -p ${TARGET_ROOT_MOUNTPOINT}/boot/efi
	cmd mount ${BOOT_DEVICE} ${TARGET_ROOT_MOUNTPOINT}/boot/efi
}


unmount_filesystems() {
	sleep 1
	cmd umount -n -R $TARGET_ROOT_MOUNTPOINT
}

setup_zbm() {
	# Fetch the ZFS Boot menu if we don't already have a copy.
	ZBM_CACHED=${TARGET_IMAGE_PATH}/BOOTX64.EFI
	ZBM_EFI_DIR=${TARGET_ROOT_MOUNTPOINT}/boot/efi/EFI/BOOT
	if [ ! -e "${ZBM_CACHED}" ]; then
	msg "Downloading ZBM ... to ${ZBM_CACHED}"
	cmd curl -o "${ZBM_CACHED}" -L https://get.zfsbootmenu.org/efi
	else
	msg "Found ${ZBM_CACHED}. Skipping download."
	fi

	# Create the Default efi directory and copy ZBM.
	cmd mkdir -p ${ZBM_EFI_DIR}
	cmd cp ${ZBM_CACHED} ${ZBM_EFI_DIR}
}

target_reconfigure_locales() {
	local l
	# Iterate over the desired UTF8 locales and uncomment any match in targets /etc/locale.gen
	for l in $TARGET_UTF8_LOCALES; do
		cmd sed -Ei "s/^\s*#\s*(${l}\.UTF-8.*$)/\1/" ${TARGET_ROOT_MOUNTPOINT}/etc/locale.gen
	done

	target_cmd dpkg-reconfigure -f noninteractive locales
	target_cmd update-locale LANG=en_US.UTF-8
}

target_set_timezone() {
	echo $TARGET_TIMEZONE > ${TARGET_ROOT_MOUNTPOINT}/etc/timezone
	target_cmd dpkg-reconfigure -f noninteractive tzdata
}

target_set_keyboard() {
	cat <<-EOF > ${TARGET_ROOT_MOUNTPOINT}/etc/default/keyboard
	# KEYBOARD CONFIGURATION FILE

	# Consult the keyboard(5) manual page.

	XKBMODEL="pc105"
	XKBLAYOUT="de"
	XKBVARIANT="nodeadkeys"
	XKBOPTIONS=""

	BACKSPACE="guess"
	EOF

	target_cmd dpkg-reconfigure -f noninteractive keyboard-configuration
}

target_setup_apt_proxy() {
	msg "Temporarily enabling proxy for target apt." 
	cat <<-EOF > ${TARGET_ROOT_MOUNTPOINT}/etc/apt/apt.conf.d/01proxy
	Acquire::http { Proxy "http://${PROXY_SERVER}:${PROXY_PORT}"; };
	EOF
}

target_remove_apt_proxy() {
	cmd rm ${TARGET_ROOT_MOUNTPOINT}/etc/apt/apt.conf.d/01proxy
}

bootstrap_os() {
	msg "Bootstrapping OS..." 
	cmd mkdir -p ${DEB_CACHE_DIR}
	cmd debootstrap --cache-dir=${DEB_CACHE_DIR} \
		--include=tzdata,locales \
		jammy ${TARGET_ROOT_MOUNTPOINT} \
		${TARGET_REPO_URL}
	cmd cp /etc/hostid ${TARGET_ROOT_MOUNTPOINT}/etc
	cmd cp /etc/resolv.conf ${TARGET_ROOT_MOUNTPOINT}/etc
	mount -t proc proc ${TARGET_ROOT_MOUNTPOINT}/proc
	mount -t sysfs sys ${TARGET_ROOT_MOUNTPOINT}/sys
	mount -B /dev ${TARGET_ROOT_MOUNTPOINT}/dev
	mount -t devpts pts ${TARGET_ROOT_MOUNTPOINT}/dev/pts

	msg "echo ${TARGET_HOSTNAME} > ${TARGET_ROOT_MOUNTPOINT}/etc/hostname"
	echo ${TARGET_HOSTNAME} > ${TARGET_ROOT_MOUNTPOINT}/etc/hostname

	target_reconfigure_locales

	# Need to use msg + echo here due to redirecting output to file.
	msg echo -e "\"127.0.1.1\t${TARGET_HOSTNAME}\" >> ${TARGET_ROOT_MOUNTPOINT}/etc/hosts"
	echo -e "127.0.1.1\t${TARGET_HOSTNAME}" >> ${TARGET_ROOT_MOUNTPOINT}/etc/hosts

	cat <<-EOF > ${TARGET_ROOT_MOUNTPOINT}/etc/apt/sources.list
	deb ${TARGET_REPO_URL} jammy main restricted universe multiverse
	# deb-src ${TARGET_REPO_URL} jammy main restricted universe multiverse

	deb ${TARGET_REPO_URL} jammy-updates main restricted universe multiverse
	# deb-src ${TARGET_REPO_URL} jammy-updates main restricted universe multiverse

	deb ${TARGET_REPO_URL} jammy-security main restricted universe multiverse
	# deb-src ${TARGET_REPO_URL} jammy-security main restricted universe multiverse

	deb ${TARGET_REPO_URL} jammy-backports main restricted universe multiverse
	# deb-src ${TARGET_REPO_URL} jammy-backports main restricted universe multiverse

	deb ${TARGET_REPO_URL} jammy partner
	# deb-src ${TARGET_REPO_URL} jammy partner
	EOF

	target_setup_apt_proxy

	# Update repository cache and system on target.
	target_cmd apt update
	target_cmd apt -y upgrade

	# Install additional base packages
	target_cmd apt -y install --no-install-recommends linux-generic locales keyboard-configuration console-setup

	# Configure packages to customize local and console properties
	target_set_timezone
#	target_reconfigure_locales
	target_set_keyboard
	target_cmd dpkg-reconfigure -f noninteractive console-setup

	# Install required packages
	target_cmd apt -y install --no-install-recommends dosfstools zfs-initramfs zfsutils-linux

	# Enable systemd ZFS services
	target_cmd systemctl enable zfs.target
	target_cmd systemctl enable zfs-import-cache
	target_cmd systemctl enable zfs-mount
	target_cmd systemctl enable zfs-import.target

	# Rebuild the initramfs
	target_cmd update-initramfs -c -k all

	# Remove proxy from image.
	target_remove_apt_proxy
}

main() {
	# Make sure that we run with sufficient privileges.
	[ $UID -ne 0 ] && error "$0 must be run as root."
	create_img_file
	format_image_file
	create_loop_device
	setup_disk

	export_zpool
	mount_filesystems

	setup_zbm
	bootstrap_os

	ls -l $ZBM_EFI_DIR
	mount | grep $TARGET_ROOT_MOUNTPOINT

	unmount_filesystems
	export_zpool
	destroy_loop_device
}

main

#vim: tabstop=4 noexpandtab
