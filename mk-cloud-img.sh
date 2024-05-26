#!/bin/bash

# Sources of inspiration:
# https://github.com/mvallim/cloud-image-ubuntu-from-scratch
# https://docs.zfsbootmenu.org/en/v2.3.x/guides/ubuntu/uefi.html

set -e

# Global Variables
TARGET_ZPOOL="croot"
TARGET_IMAGE_PATH=$(pwd)
TARGET_IMAGE_NAME="ubuntu-cloudimg-zfs.raw"

BOOT_PART="1"
POOL_PART="2"
ID="ubuntu"

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

main() {
    # Make sure that we run with sufficient privileges.
    [ $UID -ne 0 ] && error "$0 must be run as root."
    create_img_file
    format_image_file
    create_loop_device
    setup_disk

    export_zpool
    destroy_loop_device
}

main
