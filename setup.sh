#!/bin/bash
set -e

BOLD="\033[1m"
NORMAL="\033[0m"
BRANCH=""

echo -e "${BOLD}BareMetal-App Setup${NORMAL}\n"

echo -e "- Running clean"
./clean.sh

# Pre-flight checks: make sure required utilities are installed
echo -e "- Pre-flight check"
for cmd in git curl unzip tar gcc nasm make patch jq mkfs.ext2; do
	if ! command -v "$cmd" > /dev/null 2>&1; then
		echo "Error: required command '$cmd' not found. Please install it before running this script." >&2
		exit 1
	fi
done

echo -e "${BOLD}Pulling repositories${NORMAL}"

CLONE_ARGS=()
if [ -n "$BRANCH" ]; then
	CLONE_ARGS=(--branch "$BRANCH")
fi

echo -e "- BareMetal-AppPort"
git clone --quiet "${CLONE_ARGS[@]}" https://github.com/ReturnInfinity/BareMetal-AppPort
echo -e "- BareMetal-Firecracker"
git clone --quiet "${CLONE_ARGS[@]}" https://github.com/ReturnInfinity/BareMetal-Firecracker

# Makre sure libBareMetal is up to date in AppPort
cp BareMetal-Firecracker/src/libBareMetal.* BareMetal-AppPort/port/

mkdir BareMetal-AppPort/build/
cp files/* BareMetal-AppPort/build
cd BareMetal-AppPort
./setup.sh
cd ..

DISK="$PWD/disk.img"
DISKSIZE=512M

# Create the disk image if it doesn't already exist, formatted as a
# plain EXT2 filesystem: BareMetal-AppPort/port/ext4_shim.c mounts it
# through lwext4 rather than reading/writing raw sectors directly (as
# the old BMFS format did). -b 4096 is required, not cosmetic --
# BareMetal-AppPort/port/lwext4_port/blockdev_baremetal.c presents the
# disk to lwext4 as a block device with a fixed 4096-byte physical
# block size (matching the kernel's b_nvs_read/b_nvs_write sector
# size); an EXT2 image built with a smaller logical block size (e.g.
# mkfs.ext2's own 1024-byte default) makes lwext4's logical-to-
# physical block count computation truncate to 0, silently turning
# every block read/write into a no-op -- which surfaces as a confusing
# ENOSPC on the very first file an app creates, not a mount failure.
if [ ! -f "$DISK" ]; then
	echo "Creating $DISKSIZE EXT2 disk image at $DISK"
	mkfs.ext2 -q -F -b 4096 "$DISK" "$DISKSIZE"
fi

# Installs the CA bundle apps' HTTPS traffic verifies against
# (port/tls_shim.c, curltest.c) onto the fresh image -- see
# BareMetal-AppPort/port/mbedtls_port/install-cacert.sh's own header
# for why this (unlike Python's stdlib/main.py) is a one-time setup.sh
# step rather than something 1-build.sh/3-upload.sh redo per deploy.
echo -e "- Installing CA trust store"
BareMetal-AppPort/port/mbedtls_port/install-cacert.sh "$DISK"

echo -e "\n${BOLD}Complete!${NORMAL}\n"
echo -e "- Run ${BOLD}./1-build.sh YOURPROGRAM.c/.py${NORMAL} to build your program into a unikernel"
echo -e "- Run ${BOLD}./2-run.sh${NORMAL} to run your program in a BareMetal microVM."
echo -e "- Run ${BOLD}./3-upload.sh${NORMAL} to upload your program to BareMetal Cloud"
