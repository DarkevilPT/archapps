#!/bin/bash
set -e -x

DESCRIPTION="\
ArchLinux ARM
=============
Free fast and secure Linux based operating system for everyone, suitable
replacement to Windows or MacOS with different Desktop Environments.
    TYPES= server
    BOARDS= VIM3
" #DESCRIPTION_END

LABEL="ArchLinux"
BOARDS="VIM3 #"

FAIL() {
    echo "[e] $@">&2
    exit 1
}

# We'll be using bash

TARGET_DRIVE=$(mmcblk0)
BOARD_MODEL=$(tr -d '\0' < /sys/firmware/devicetree/base/model || echo Khadas)
BOARD_NAME=
case "$BOARD_MODEL" in
    *VIM3)
        BOARD_NAME=VIM3
        ;;
    *VIM2)
        BOARD_NAME=VIM2
        ;;
    *VIM1S)
        BOARD_NAME=VIM1S
        ;;
    *)
        BOARD_NAME=UNKNOWN
        ;;
esac


echo "ArchLinux installation for $BOARD ..."

# add dependencies
echo -e "\n\nInstall necessary dependencies...\n\n"
opkg update && opkg install libmbedtls12 git git-http gnupg



# We want to have both `/boot` and `/` seperate partition
#  VIM3:
#     [untouched partition] First 16 MB
#     [/boot (vfat)] Start 16 MB, size 250 MB
#     [/  (ext4)] start from closest 250MB, size Rest
PARTITION_DEF=
case "$BOARD_NAME" in
    VIM3)
        PARTITION_DEF=$(cat << EOF
        name=BOOT, start=16M, size=250M, type=0xB, bootable
        name=ROOT, start=250M, type=83
EOF
)
        ;;
    *)
        PARTITION_DEF="dump"
        ;;
esac

echo "Ensuring target partitions are not currently mounted"
mount | grep ${TARGET_DRIVE}p1 > /dev/null && FAIL "Please unmount ${TARGET_DRIVE}p1 first"
mount | grep ${TARGET_DRIVE}p2 > /dev/null && FAIL "Please unmount ${TARGET_DRIVE}p2 first"

echo "label: dos" | sfdisk "${TARGET_DRIVE}"
echo -e "${PARTITION_DEF}" | sfdisk "${TARGET_DRIVE}"


# create the boot partition
mkfs.fat -F 32 -n BOOT "${TARGET_DRIVE}p1"
# create root partition
mkfs.ext4 -F -L ROOT "${TARGET_DRIVE}p2"


# Preparing the filesystems
ROOT=/tmp/mounts/root
mkdir -p ${ROOT} && mount "${TARGET_DRIVE}p2" ${ROOT}
mkdir -p ${ROOT}/boot && mount "${TARGET_DRIVE}p1" ${ROOT}/boot


echo "Target root is ${ROOT}/"

# Download the current ARM Arch Linux image
SRC=http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz

echo "Downloading and extracting $SRC to ${ROOT}/"
curl -A downloader -jkL $SRC | pigz -dc | tar -xf- -C ${ROOT}



# Write the fstab
BOOT_UUID=$(blkid -s UUID -o value ${TARGET_DRIVE}p1)
ROOT_UUID=$(blkid -s UUID -o value ${TARGET_DRIVE}p2)

echo "UUID=${ROOT_UUID}" / auto errors=remount-ro 1 1 >> ${ROOT}/etc/fstab
echo "UUID=${BOOT_UUID}" /boot vfat defaults 0 0 >> ${ROOT}/etc/fstab

# setup extlinux config
mkdir -p "${ROOT}/boot/extlinux" && mkdir -p "${ROOT}/boot/dtbs"
cat <<-END > ${ROOT}/boot/extlinux/extlinux.conf
LABEL ArchLinux
    KERNEL /Image.gz
    INITRD /initramfs-linux.img
    FDTDIR /dtbs
    APPEND root=UUID=${ROOT_UUID} rw quiet
END

# setup host name
echo ${BOARD_MODEL// /-} > ${ROOT}/etc/hostname

# setup dhcp for ethernet
# Not needed because we are using systemd-resolve(5) in Arch Linux
# echo dhcpcd eth0 -d > ${ROOT}/etc/rc.local
# chmod 0777 ${ROOT}/etc/rc.local

# add device firmware
# Broadcom
DRIVER_CODE=4359
case $BOARD_MODEL in
    *VIM3)  DRIVER_CODE=4359
    ;;
    *) DRIVER_CODE=
    ;;
esac

GH_RAW="https://raw.githubusercontent.com"

CURR_DIR=$(pwd)
mkdir -p /tmp/extras && cd /tmp/extras
git clone "https://github.com/LibreELEC/brcmfmac_sdio-firmware" && cd brcmfmac_sdio-firmware
cp -av *$DRIVER_CODE* ${ROOT}/lib/firmware/brcm/ && cd -

# add default DT overlays
BOARD_NAME_LOW=$(echo "${BOARD_NAME}" | tr '[:upper:]' '[:lower:]')
git clone "https://github.com/khadas/khadas-linux-kernel-dt-overlays.git" khadas-overlays && cd khadas-overlays
cp -av -r ./overlays/${BOARD_NAME_LOW}/mainline/* "${ROOT}/boot/dtbs/" && cd -

# Prepare Arch PacStrap
git clone https://github.com/wick3dr0se/archstrap && cd archstrap
# can't archStrap because of gpg2 not current available

cd "${CURR_DIR}"


# setup host name
echo ${BOARD_MODEL// /-} > ${ROOT}/etc/hostname

# setup secure tty
echo ttyAML0 >> ${ROOT}/etc/securetty
echo ttyFIQ0 >> ${ROOT}/etc/securetty

# Unmount partitions safely...
umount ${ROOT}/boot
umount ${ROOT}

# install uboot to eMMC
mmc_update_uboot online

# optional install uboot to SPI flash
spi_update_uboot online -k && echo need poweroff and poweron device again

# DONE plz reboot device
