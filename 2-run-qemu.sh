#!/bin/bash
# 2-run-qemu.sh - Run baremetal.elf in a QEMU microvm instead of Firecracker
#
# Usage: ./2-run-qemu.sh [args...]   (args are handed to the app, as with 2-run.sh)
#
# The serial console is attached to this terminal. QEMU exits when the app
# finishes; press Ctrl-A then X to quit early (Ctrl-A then C for the QEMU monitor).
#
# Configuration (environment overrides):
#	MEMSIZE		VM memory in MiB (default 256). There is no memory hot-plug
#			under QEMU, so this is all the RAM the app gets. Only what the
#			app touches costs host memory
#	CPUCOUNT	vCPU count (default 1)
set -e

BOLD="\033[1m"
NORMAL="\033[0m"

KERNEL="$PWD/baremetal.elf"
DISK="$PWD/disk.img"
MEMSIZE="${MEMSIZE:-256}"
CPUCOUNT="${CPUCOUNT:-1}"
MAC="02:FC:AB:CD:EF:02" # 2-run.sh's Firecracker VM uses ...:01

# Check for QEMU
if ! command -v qemu-system-x86_64 > /dev/null 2>&1; then
	echo -e "${BOLD}Error${NORMAL}: 'qemu-system-x86_64' not found. Install QEMU to run locally under it." >&2
	exit 1
fi

# The kernel needs KVM (it uses the KVM clock)
if [ ! -r /dev/kvm ] || [ ! -w /dev/kvm ]; then
	echo -e "${BOLD}Error${NORMAL}: no access to /dev/kvm. Add your user to the 'kvm' group (see README)." >&2
	exit 1
fi

if [ ! -f "$KERNEL" ]; then
	echo -e "${BOLD}Error${NORMAL}: $KERNEL is missing -- run ./1-build.sh first." >&2
	exit 1
fi

# QEMU only boots an ELF that carries a PVH note
if command -v readelf > /dev/null 2>&1 && ! readelf -n "$KERNEL" 2>/dev/null | grep -q '^ *Xen '; then
	echo -e "${BOLD}Error${NORMAL}: $KERNEL has no PVH entry point, so QEMU can't boot it. Rebuild it from a BareMetal-Firecracker with PVH support." >&2
	exit 1
fi

# microvm machine options:
#	acpi=off	QEMU then lists the virtio-mmio devices on the kernel command
#			line (virtio_mmio.device=...), which is where init finds
#			them -- the same way Firecracker passes them
#	i8042		Keyboard controller -- the kernel shuts down with a keyboard
#			controller reset, which -no-reboot turns into a QEMU exit
# force-legacy=false makes the virtio-mmio transports modern (version 2), the
# only kind the kernel drives
QEMU_ARGS=(
	-M microvm,acpi=off
	-device i8042
	-enable-kvm -cpu host
	-smp "$CPUCOUNT"
	-m "$MEMSIZE"
	-kernel "$KERNEL"
	-no-reboot
	-display none
	-serial mon:stdio
	-global virtio-mmio.force-legacy=false
)

# Kernel command line: app args, passed the same way baremetal.sh does
if [ "$#" -gt 0 ]; then
	QEMU_ARGS+=(-append "args=\`$*\`")
fi

# Storage
if [ -f "$DISK" ]; then
	QEMU_ARGS+=(
		-drive id=rootfs,file="$DISK",format=raw,if=none
		-device virtio-blk-device,drive=rootfs
	)
else
	echo -e "${BOLD}Warning${NORMAL}: $DISK not found. VM will be started without a disk. Run ./setup.sh to create it." >&2
fi

# Network: tap0 (as with 2-run.sh) if it exists, otherwise QEMU's user-mode
# networking, which gives the guest outbound access via DHCP without any host setup
if ip link show tap0 > /dev/null 2>&1; then
	QEMU_ARGS+=(-netdev tap,id=eth0,ifname=tap0,script=no,downscript=no)
else
	echo -e "${BOLD}Note${NORMAL}: tap device 'tap0' not found. Using QEMU user-mode networking (outbound only). Run 'BareMetal-Firecracker/scripts/mkbr0.sh' to use tap0." >&2
	QEMU_ARGS+=(-netdev user,id=eth0)
fi
QEMU_ARGS+=(-device virtio-net-device,netdev=eth0,mac="$MAC")

echo -e "${BOLD}Starting QEMU microvm${NORMAL} (Ctrl-A then X to quit)"
exec qemu-system-x86_64 "${QEMU_ARGS[@]}"
