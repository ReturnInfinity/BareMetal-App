#!/bin/bash
set -e

BOLD="\033[1m"
NORMAL="\033[0m"

if [ -z "$1" ]; then
	echo "Usage: $0 <program.c> [otherfile.c ...]"
	echo "       $0 <program.py>"
	exit 1
fi

# Same as 1-build.sh, except the unikernel is built around the ELF64
# intermediate build-app.sh links (build/$PROG_APP.elf) instead of the
# objcopy'd flat binary (build-app.sh's OUTPUT_FORMAT(binary) $PROG_APP)
# it normally flattens that ELF down to -- see build-app.sh's own
# comment on why that two-stage link exists. The flat binary is what
# start_flat_app in kernel.asm expects; this is for exercising
# kernel.asm's start_elf_app path instead (ELF magic 0x7F454C46 at
# 0x200000) rather than for normal app builds.
#
# A .py argument doesn't get compiled -- BareMetal-AppPort/setup.sh
# already built python.app (the CPython interpreter itself, see
# BareMetal-AppPort/PYTHON.md) once, ready to go. Instead, deploy the
# script onto disk.img as /pylib/main.py (the fixed path python.c
# runs, see PYMAIN_SCRIPT_PATH there) via install-main.sh's debugfs -w
# approach -- no host root/loop-mount needed, and safe even while a VM
# has disk.img open -- then build the unikernel around python.app.elf
# instead of a freshly-compiled app.
case "$1" in
*.py)
	if [ "$#" -gt 1 ]; then
		echo "Error: only one .py file is supported (it's deployed as /pylib/main.py, python.c's fixed entry point -- see BareMetal-AppPort/PYTHON.md)"
		exit 1
	fi
	PROG_PY="$1"
	if [ ! -f "$PROG_PY" ]; then
		echo "Error: $PROG_PY not found"
		exit 1
	fi

	PROG_APP="python.app"
	PROG_APP_ELF="build/python.app.elf"
	echo "$PROG_APP" > .prog_app

	if [ ! -f "BareMetal-AppPort/$PROG_APP_ELF" ]; then
		echo "Error: BareMetal-AppPort/$PROG_APP_ELF is missing -- run BareMetal-AppPort/setup.sh first." >&2
		exit 1
	fi
	if [ ! -f "disk.img" ]; then
		echo "Error: disk.img is missing -- run ./setup.sh first." >&2
		exit 1
	fi

	BareMetal-AppPort/port/python_port/install-main.sh "$PWD/disk.img" "$PROG_PY"

	cp "BareMetal-AppPort/$PROG_APP_ELF" "BareMetal-Firecracker/sys/$PROG_APP"
	cd BareMetal-Firecracker
	./build.sh "$PROG_APP"
	cp sys/baremetal.elf ../
	cd ..

	exit 0
	;;
esac

PROG_SRCS=("$@")
PROG_APP="$(basename "${PROG_SRCS[0]}" .c).app"
PROG_APP_ELF="build/$PROG_APP.elf"
echo "$PROG_APP" > .prog_app

# Mirror each source's path (and any header files sitting alongside it)
# into BareMetal-AppPort, so quote-form #includes between them resolve
# the same way there as they do here.
for SRC in "${PROG_SRCS[@]}"; do
	if [ ! -f "$SRC" ]; then
		echo "Error: $SRC not found"
		exit 1
	fi
	SRC_DIR=$(dirname "$SRC")
	mkdir -p "BareMetal-AppPort/$SRC_DIR"
	cp "$SRC" "BareMetal-AppPort/$SRC_DIR/"
	for HDR in "$SRC_DIR"/*.h; do
		if [ -f "$HDR" ]; then
			cp "$HDR" "BareMetal-AppPort/$SRC_DIR/"
		fi
	done
done

cd BareMetal-AppPort
./build-app.sh "${PROG_SRCS[@]}"
cp "$PROG_APP_ELF" "../BareMetal-Firecracker/sys/$PROG_APP"
cd ..

cd BareMetal-Firecracker
./build.sh "$PROG_APP"
cp sys/baremetal.elf ../
cd ..
