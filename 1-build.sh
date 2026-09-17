#!/bin/bash
set -e

BOLD="\033[1m"
NORMAL="\033[0m"

if [ -z "$1" ]; then
	echo "Usage: $0 <program.c> [otherfile.c ...]"
	echo "       $0 <program.cpp> [otherfile.cpp ...]"
	echo "       $0 <program.py>"
	echo "       $0 <program.lua>"
	echo "       $0 <yourcrate/src/main.rs>"
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
*.lua)
	# Same shape as the .py case above, just for lua.app (see
	# BareMetal-AppPort/LUA.md) instead of python.app -- no separate
	# stdlib deploy step needed, Lua's standard library is compiled
	# straight into the interpreter itself (setup.sh's LUA_SRCS), so
	# only the script itself needs to land on disk.img.
	if [ "$#" -gt 1 ]; then
		echo "Error: only one .lua file is supported (it's deployed as /lualib/main.lua, lua.c's fixed entry point -- see BareMetal-AppPort/LUA.md)"
		exit 1
	fi
	PROG_LUA="$1"
	if [ ! -f "$PROG_LUA" ]; then
		echo "Error: $PROG_LUA not found"
		exit 1
	fi

	PROG_APP="lua.app"
	echo "$PROG_APP" > .prog_app

	if [ ! -f "BareMetal-AppPort/$PROG_APP" ]; then
		echo "Error: BareMetal-AppPort/$PROG_APP is missing -- run BareMetal-AppPort/setup.sh first." >&2
		exit 1
	fi
	if [ ! -f "disk.img" ]; then
		echo "Error: disk.img is missing -- run ./setup.sh first." >&2
		exit 1
	fi

	DEPLOY_LOG="/tmp/install-lua-deploy.log"
	: > "$DEPLOY_LOG"
	echo "Deploying $PROG_LUA to disk.img (log: $DEPLOY_LOG) ..."
	if ! BareMetal-AppPort/port/lua_port/install-main.sh "$PWD/disk.img" "$PROG_LUA" >> "$DEPLOY_LOG" 2>&1; then
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
*.rs)
	if [ "$#" -gt 1 ]; then
		echo "Error: only one .rs file is supported -- it must be <yourcrate>/src/main.rs, and BareMetal-AppPort/build-rust-app.sh builds the whole cargo crate it belongs to (see RUST.md)"
		exit 1
	fi
	PROG_RS="$1"
	if [ ! -f "$PROG_RS" ]; then
		echo "Error: $PROG_RS not found"
		exit 1
	fi

	CRATE_DIR="$(cd "$(dirname "$PROG_RS")/.." && pwd)"
	if [ ! -f "$CRATE_DIR/Cargo.toml" ]; then
		echo "Error: $CRATE_DIR/Cargo.toml not found -- $PROG_RS must be <yourcrate>/src/main.rs"
		exit 1
	fi
	PROG_APP="$(basename "$CRATE_DIR").app"
	echo "$PROG_APP" > .prog_app

	cd BareMetal-AppPort
	./build-rust-app.sh "$OLDPWD/$PROG_RS"
	cp "$PROG_APP" ../BareMetal-Firecracker/sys
	cd ..

	cd BareMetal-Firecracker
	./build.sh "$PROG_APP"
	cp sys/baremetal.elf ../
	cd ..

	exit 0
	;;
*.cpp)
	# Same shape as the plain .c path below (multi-file support,
	# mirrored into BareMetal-AppPort so quote-form #includes resolve
	# the same way there), just dispatching to build-cpp-app.sh instead
	# of build-app.sh -- see BareMetal-AppPort/CPP.md for how the C++
	# port itself works.
	PROG_SRCS=("$@")
	PROG_APP="$(basename "${PROG_SRCS[0]}" .cpp).app"
	echo "$PROG_APP" > .prog_app

	for SRC in "${PROG_SRCS[@]}"; do
		if [ ! -f "$SRC" ]; then
			echo "Error: $SRC not found"
			exit 1
		fi
		case "$SRC" in
		*.cpp) ;;
		*)
			echo "Error: $SRC is not a .cpp file"
			exit 1
			;;
		esac
		SRC_DIR=$(dirname "$SRC")
		mkdir -p "BareMetal-AppPort/$SRC_DIR"
		cp "$SRC" "BareMetal-AppPort/$SRC_DIR/"
		for HDR in "$SRC_DIR"/*.h "$SRC_DIR"/*.hpp; do
			if [ -f "$HDR" ]; then
				cp "$HDR" "BareMetal-AppPort/$SRC_DIR/"
			fi
		done
	done

	cd BareMetal-AppPort
	./build-cpp-app.sh "${PROG_SRCS[@]}"
	cp "$PROG_APP" ../BareMetal-Firecracker/sys
	cd ..

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
