#!/bin/sh
# disk.sh - Mount/unmount disk.img on the host to inspect its contents
#
# Usage: ./disk.sh <command>
#
# Commands:
#	mount		Mount disk.img (loopback) at ./disk-mnt
#	umount		Unmount ./disk-mnt
#	status		Show whether disk.img is currently mounted
#	help		Display help info
#
# Configuration (edit variables below):
#	DISK		Path to the disk image
#	MNT		Mount point directory
set -eu

DISK="$PWD/disk.img"
MNT="$PWD/disk-mnt"

# Prepare arguments
cmd="${1:-}" # first argument is the subcommand (default: empty)

case "$cmd" in
	mount)
		if [ ! -f "$DISK" ]; then
			echo "Error: $DISK not found. Run ./setup.sh first." >&2
			exit 1
		fi

		if mountpoint -q "$MNT" 2>/dev/null; then
			echo "$MNT is already mounted"
			exit 0
		fi

		# disk.img is also used as a Firecracker block device (see
		# baremetal.sh) -- mounting it on the host at the same time
		# the VM is running risks the loop mount and the VM writing
		# through stale/conflicting views of the same blocks.
		if [ -S /tmp/firecracker.socket ] && curl -sf --unix-socket /tmp/firecracker.socket 'http://localhost/machine-config' > /dev/null 2>&1; then
			echo "Error: VM is running (./baremetal.sh status). Stop it first to avoid corrupting $DISK." >&2
			exit 1
		fi

		mkdir -p "$MNT"
		# ext2 has its own on-disk uid/gid per inode (unlike FAT/
		# ISO9660) -- passing mount(8)'s uid=/gid= remap options to it
		# is an invalid option the ext2 driver rejects outright, which
		# mount(8) reports as the generic (and misleading) "wrong fs
		# type, bad option, bad superblock" error. Browsing/editing
		# under $MNT after this needs sudo (or `sudo chown -R`) as a
		# result, same as any other root-owned ext2 loop mount.
		sudo mount -o loop "$DISK" "$MNT"
		echo "Mounted $DISK at $MNT"

		;;

	umount)
		if ! mountpoint -q "$MNT" 2>/dev/null; then
			echo "$MNT is not mounted"
			exit 0
		fi

		sudo umount "$MNT"
		echo "Unmounted $MNT"

		;;

	status)
		if mountpoint -q "$MNT" 2>/dev/null; then
			echo "$MNT is mounted"
		else
			echo "$MNT is not mounted"
		fi

		;;

	help|*)
		sed -n '2,14p' "$0" | sed 's/^# \?//'

		;;
esac
