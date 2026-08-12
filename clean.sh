#!/bin/bash
set -e

rm -rf BareMetal-AppPort
rm -rf BareMetal-Firecracker
rm -f baremetal.elf
rm -f disk.img
rm -f .prog_app

# Unmount before removing the (possibly still-mounted) directory --
# rm -rf on an active mount point would delete files off disk.img
# through the mount rather than the empty directory underneath it.
if mountpoint -q disk-mnt 2>/dev/null; then
	./disk.sh umount
fi
rm -rf disk-mnt
