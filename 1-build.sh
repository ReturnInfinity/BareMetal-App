#!/bin/bash
set -e

BOLD="\033[1m"
NORMAL="\033[0m"

if [ -z "$1" ]; then
	echo "Usage: $0 <program.c> [otherfile.c ...]"
	echo "       $0 <program.py>"
	exit 1
fi

# A .py argument doesn't get compiled -- BareMetal-AppPort/setup.sh
# already built python.app (the CPython interpreter itself, see
# BareMetal-AppPort/PYTHON.md) once, ready to go. Instead, deploy the
# curated stdlib (install-stdlib.sh) and the script itself as
# /pylib/main.py (the fixed path python.c runs, see
# PYMAIN_SCRIPT_PATH there) onto disk.img via debugfs -w -- no host
# root/loop-mount needed, and safe even while a VM has disk.img open
# -- then build the unikernel around python.app instead of a
# freshly-compiled app.
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
	echo "$PROG_APP" > .prog_app

	if [ ! -f "BareMetal-AppPort/$PROG_APP" ]; then
		echo "Error: BareMetal-AppPort/$PROG_APP is missing -- run BareMetal-AppPort/setup.sh first." >&2
		exit 1
	fi
	if [ ! -f "disk.img" ]; then
		echo "Error: disk.img is missing -- run ./setup.sh first." >&2
		exit 1
	fi

	DEPLOY_LOG="/tmp/install-python-deploy.log"
	: > "$DEPLOY_LOG"
	echo "Deploying Python stdlib and $PROG_PY to disk.img (log: $DEPLOY_LOG) ..."
	if ! BareMetal-AppPort/port/python_port/install-stdlib.sh "$PWD/disk.img" >> "$DEPLOY_LOG" 2>&1; then
		echo "error: install-stdlib.sh failed -- see $DEPLOY_LOG" >&2
		cat "$DEPLOY_LOG" >&2
		exit 1
	fi
	if ! BareMetal-AppPort/port/python_port/install-main.sh "$PWD/disk.img" "$PROG_PY" >> "$DEPLOY_LOG" 2>&1; then
		echo "error: install-main.sh failed -- see $DEPLOY_LOG" >&2
		cat "$DEPLOY_LOG" >&2
		exit 1
	fi

	cp "BareMetal-AppPort/$PROG_APP" BareMetal-Firecracker/sys
	cd BareMetal-Firecracker
	./build.sh "$PROG_APP"
	cp sys/baremetal.elf ../
	cd ..

	exit 0
	;;
esac

PROG_SRCS=("$@")
PROG_APP="$(basename "${PROG_SRCS[0]}" .c).app"
echo "$PROG_APP" > .prog_app

# Mirror each source's path (and any header files sitting alongside it)
# into BareMetal-AppPort, so quote-form #includes between them resolve
# the same way there as they do here.
for SRC in "${PROG_SRCS[@]}"; do
	if [ ! -f "$SRC" ]; then
		echo "Error: $SRC not found"
		exit 1
	fi
	case "$SRC" in
	*.c) ;;
	*)
		echo "Error: $SRC is not a .c file"
		exit 1
		;;
	esac
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
cp "$PROG_APP" ../BareMetal-Firecracker/sys
cd ..

cd BareMetal-Firecracker
./build.sh "$PROG_APP"
cp sys/baremetal.elf ../
cd ..
