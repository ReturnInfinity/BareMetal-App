#!/bin/bash
set -e

BOLD="\033[1m"
NORMAL="\033[0m"

if [ -z "$1" ]; then
	echo "Usage: $0 <program.c> [otherfile.c ...]"
	echo "       $0 <program.cpp> [otherfile.cpp ...]"
	echo "       $0 <program.py>"
	echo "       $0 <program.lua>"
	echo "       $0 <script.sql> [database.db|-]"
	echo "       $0 <yourcrate/src/main.rs>"
	echo "       $0 <program.zig>"
	echo "       $0 lighttpd [lighttpd.conf] [docroot-dir]"
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
	# Same shape as the .py path above, minus the stdlib deploy: Lua's
	# whole standard library is compiled into lua.app (built once by
	# BareMetal-AppPort/setup.sh, see BareMetal-AppPort/LUA.md), so
	# only the script itself goes onto disk.img, as /lua/main.lua (the
	# fixed path lua.c runs, see LUAMAIN_SCRIPT_PATH there). Other
	# .lua modules it require()s can be copied into /lua/ the same way.
	if [ "$#" -gt 1 ]; then
		echo "Error: only one .lua file is supported (it's deployed as /lua/main.lua, lua.c's fixed entry point -- see BareMetal-AppPort/LUA.md)"
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
	echo "Deploying $PROG_LUA to disk.img (log: $DEPLOY_LOG) ..."
	if ! BareMetal-AppPort/port/lua_port/install-main.sh "$PWD/disk.img" "$PROG_LUA" > "$DEPLOY_LOG" 2>&1; then
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
*.sql)
	# Same shape as the .lua path above: sqlite.app (SQLite's own shell,
	# built once by BareMetal-AppPort/setup.sh) runs /sqlite/main.sql off
	# disk.img against /sqlite/main.db, printing each statement and its
	# results. The database persists between runs; a second argument
	# replaces it with a copy of a local database file, or "-" deletes it
	# so the next run starts empty. See port/sqlite_port/install-main.sh.
	if [ "$#" -gt 2 ]; then
		echo "Error: usage is $0 script.sql [database.db|-]"
		exit 1
	fi
	PROG_SQL="$1"
	if [ ! -f "$PROG_SQL" ]; then
		echo "Error: $PROG_SQL not found"
		exit 1
	fi
	INSTALL_ARGS=("$PWD/disk.img" "$PROG_SQL")
	if [ -n "${2:-}" ]; then
		if [ "$2" != "-" ] && [ ! -f "$2" ]; then
			echo "Error: $2 not found"
			exit 1
		fi
		INSTALL_ARGS+=("$2")
	fi

	PROG_APP="sqlite.app"
	echo "$PROG_APP" > .prog_app

	if [ ! -f "BareMetal-AppPort/$PROG_APP" ]; then
		echo "Error: BareMetal-AppPort/$PROG_APP is missing -- run BareMetal-AppPort/setup.sh first." >&2
		exit 1
	fi
	if [ ! -f "disk.img" ]; then
		echo "Error: disk.img is missing -- run ./setup.sh first." >&2
		exit 1
	fi

	DEPLOY_LOG="/tmp/install-sqlite-deploy.log"
	echo "Deploying $PROG_SQL to disk.img (log: $DEPLOY_LOG) ..."
	if ! BareMetal-AppPort/port/sqlite_port/install-main.sh "${INSTALL_ARGS[@]}" > "$DEPLOY_LOG" 2>&1; then
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
lighttpd)
	# Not a program to compile: lighttpd.app (the lighttpd web server,
	# built once by BareMetal-AppPort/setup.sh, see
	# BareMetal-AppPort/LIGHTTPD.md) runs whatever config and site are on
	# disk.img. Deploy those (install.sh puts the config at
	# /lighttpd/lighttpd.conf, the fixed path lighttpd.c passes to -f,
	# and the docroot's contents under /lighttpd/www), then build the
	# unikernel around lighttpd.app. With no arguments, install.sh's own
	# defaults are used: port/lighttpd_port/lighttpd.conf and its www/.
	if [ "$#" -gt 3 ]; then
		echo "Error: usage is $0 lighttpd [lighttpd.conf] [docroot-dir]"
		exit 1
	fi
	INSTALL_ARGS=("$PWD/disk.img")
	if [ -n "${2:-}" ]; then
		if [ ! -f "$2" ]; then
			echo "Error: $2 not found"
			exit 1
		fi
		INSTALL_ARGS+=("$(realpath "$2")")
	fi
	if [ -n "${3:-}" ]; then
		if [ ! -d "$3" ]; then
			echo "Error: $3 is not a directory"
			exit 1
		fi
		INSTALL_ARGS+=("$(realpath "$3")")
	fi

	PROG_APP="lighttpd.app"
	echo "$PROG_APP" > .prog_app

	if [ ! -f "BareMetal-AppPort/$PROG_APP" ]; then
		echo "Error: BareMetal-AppPort/$PROG_APP is missing -- run BareMetal-AppPort/setup.sh first." >&2
		exit 1
	fi
	if [ ! -f "disk.img" ]; then
		echo "Error: disk.img is missing -- run ./setup.sh first." >&2
		exit 1
	fi

	DEPLOY_LOG="/tmp/install-lighttpd-deploy.log"
	echo "Deploying the lighttpd config and docroot to disk.img (log: $DEPLOY_LOG) ..."
	if ! BareMetal-AppPort/port/lighttpd_port/install.sh "${INSTALL_ARGS[@]}" > "$DEPLOY_LOG" 2>&1; then
		echo "error: install.sh failed -- see $DEPLOY_LOG" >&2
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
*.zig)
	# Same shape as the .c path below, but a single file only --
	# BareMetal-AppPort/build-zig-app.sh (unlike build-app.sh/
	# build-cpp-app.sh) only takes one source at a time. See
	# BareMetal-AppPort/ZIG.md for how the Zig port itself works and
	# BareMetal-AppPort/examples/zig/hello/hello.zig for the required
	# `export fn main(...) callconv(.c) c_int` entry-point shape.
	if [ "$#" -gt 1 ]; then
		echo "Error: only one .zig file is supported (see BareMetal-AppPort/ZIG.md)"
		exit 1
	fi
	PROG_ZIG="$1"
	if [ ! -f "$PROG_ZIG" ]; then
		echo "Error: $PROG_ZIG not found"
		exit 1
	fi

	PROG_APP="$(basename "$PROG_ZIG" .zig).app"
	echo "$PROG_APP" > .prog_app

	SRC_DIR=$(dirname "$PROG_ZIG")
	mkdir -p "BareMetal-AppPort/$SRC_DIR"
	cp "$PROG_ZIG" "BareMetal-AppPort/$SRC_DIR/"

	cd BareMetal-AppPort
	./build-zig-app.sh "$PROG_ZIG"
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
