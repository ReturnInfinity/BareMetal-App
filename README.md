# BareMetal-App

A quick way to get going with testing [BareMetal-Firecracker](https://github.com/ReturnInfinity/BareMetal-Firecracker), [BareMetal-AppPort](https://github.com/ReturnInfinity/BareMetal-AppPort), and uploading your program to [BareMetal Cloud](https://baremetal.returninfinity.com).

BareMetal is an exokernel written in x86-64 Assembly that expects a payload program. Your C program is compiled into an `.app` and is combined with the BareMetal kernel to produce a single bootable `.elf` unikernel. It can then be run directly in Firecracker microVM with as little as 4MiB of RAM. This repo wires together the pieces needed to go from a C file on your laptop to a running instance, either locally in a VM for fast iteration or on BareMetal Cloud for real deployment.

## Quickstart

Log into [BareMetal Cloud](https://baremetal.returninfinity.com), open API KEYS, and create a new API key.

On your linux system enter the command `export BM_API_KEY=YOURKEY`. Replace YOURKEY with the new key.

Enter the following commands:

```
git clone https://github.com/ReturnInfinity/BareMetal-App
cd BareMetal-App
./setup.sh
cp BareMetal-AppPort/hello.c .
./1-build.sh hello.c
./2-run.sh
./3-upload.sh
```

When prompted to upload to cloud hit `Y`. Your program should be running in BareMetal Cloud now.

`./1-build.sh` writes the name of the `.app` it built to `.prog_app` in the repo root, which `./3-upload.sh` reads back so it knows which file to upload — this is what lets the two scripts be run separately, one after the other.

Confirm it:
`./bm-api.sh instances list`

## Requirements

The following commands must be installed before running `./setup.sh`: `git`, `curl`, `unzip`, `tar`, `gcc`, `nasm`, `make`, `patch`, `jq`, `mkfs.ext2` (from `e2fsprogs`). The script will check for these.

To run VMs locally you'll also need [Firecracker](https://github.com/firecracker-microvm/firecracker) installed and accessible, `screen`, and your user must be in the `kvm` group:

```
sudo usermod -aG kvm $YOURUSERNAME
```

Log out and back in for the group change to take effect.

## Clone

```
git clone https://github.com/ReturnInfinity/BareMetal-App
cd BareMetal-App
```

## Setup

```
./setup.sh
```

This runs a "pre-flight" check to verify the prerequisites above are installed (including `mkfs.ext2`, from `e2fsprogs`), then clones `BareMetal-AppPort` and `BareMetal-Firecracker` alongside this repo, copies the bundled libraries in `files/` (lwIP, mbedTLS, musl) into the app-port build directory, and builds everything. It also creates a 512M `disk.img`, formatted as a plain EXT2 filesystem (`mkfs.ext2 -b 4096` - the 4096-byte block size matters, see `setup.sh`'s comment) for the VM to boot against; `BareMetal-AppPort/port/ext4_shim.c` mounts it through lwext4.

Re-running `./setup.sh` starts from a clean slate — it calls `./clean.sh` first, which removes the cloned repos, `baremetal.elf`, and `disk.img`.

## Write a program

Any standard C program is a valid starting point. For example:

```
echo -e '#include <stdio.h>\n\nint main(void) {\n    printf("Hello, World!\\n");\n    return 0;\n}' > hello.c
```

## Build it

```
./1-build.sh hello.c
```

You can also use multiple C files:

```
./1-build.sh testjson.c cjson/cjson.c
```

This will:

1. Build your program into a BareMetal `.app` via `BareMetal-AppPort/build-app.sh`.
2. Link it into a bootable kernel image via `BareMetal-Firecracker/build.sh`, producing `baremetal.elf` in the repo root.

## Run it

```
./2-run.sh
```

Boot `baremetal.elf` locally under Firecracker and print its console output.

## Upload it

Uploading requires a `BM_API_KEY`. Generate one from the [dashboard](https://baremetal.returninfinity.com) (or `POST /api/api-keys` while signed in), then:

```
export BM_API_KEY=YOURKEY
```

Upload `baremetal.elf` to the BareMetal Cloud and launch it as an instance.

```
./3-upload.sh
```

### Local networking (optional)

Local VM testing needs a `tap0` device. Create one with:

```
./BareMetal-Firecracker/scripts/mkbr0.sh
```

This sets up a `br0` bridge with `tap0` attached in promiscuous mode. On a wired connection the host NIC is enslaved to the bridge for full L2 visibility to the VM; on Wi-Fi (which can't be bridged in station mode) it falls back to NAT so the guest still has outbound connectivity. If `tap0` isn't present, `test.sh` simply skips the local run and moves on to the cloud upload prompt.

## Managing the local VM

`./baremetal.sh` controls the Firecracker VM directly:

| Command | Description |
|---|---|
| `start` | Configure and start the VM (kernel, disk, network, boot) |
| `status` | Check if the VM is currently running |
| `send <text>` | Send a line of text to the VM serial console |
| `output [--full]` | Print new console output since the last check (`--full` for the entire log) |
| `stop` | Gracefully shut down the VM (Ctrl+Alt+Del) |
| `attach` | Attach to the interactive `screen` session for the console |
| `help` | Show usage and current configuration |

`test.sh` calls `start` and `output --full` for you; use these directly when iterating without rebuilding, or `attach` to interact with the running program.

## Deploying to the BareMetal Cloud

![BareMetal Cloud UI](images/Screenshot.png)

Uploading from `test.sh` requires a `BM_API_KEY`. Generate one from the [dashboard](https://baremetal.returninfinity.com) (or `POST /api/api-keys` while signed in), then:

```
export BM_API_KEY=YOURKEY
```

An API key only ever authorizes `/api/images`, `/api/instances`, `/api/tasks`, and `/api/limits` — never billing or account routes.

`test.sh` handles a single upload-and-launch flow interactively. For everything else, `./bm-api.sh` is a standalone CLI over the same API:

```
BM_API_KEY=bmvps_... ./bm-api.sh <command> [args...]
```

| Command | Description |
|---|---|
| `images list` | List available images |
| `images upload <label> <file>` | Upload a built `.elf` as a new image |
| `images rm <image-id>` | Delete an image |
| `instances list` | List your instances |
| `instances show <instance-id>` | Show status and network info for an instance |
| `instances create <name> <vcpu> <ram-mib> <image-id>` | Create and start a new instance |
| `instances start\|stop\|reboot\|suspend\|resume\|snapshot\|restore <instance-id>` | Lifecycle actions |
| `instances rm <instance-id>` | Delete an instance |
| `instances logs <instance-id>` | Fetch an instance's console log |
| `tasks show <task-id>` | Check the status of an async provisioning task |

Pass `-v`/`--verbose` before a command to see the full JSON response instead of the trimmed default output. Commands that enqueue a provisioning task (create, start, stop, reboot, suspend, resume, snapshot, restore, rm, logs) poll until the task settles before printing anything.

## Cleaning up

```
./clean.sh
```

Removes the cloned `BareMetal-AppPort` and `BareMetal-Firecracker` repos, `baremetal.elf`, `disk.img`, and `.prog_app`. `setup.sh` runs this automatically before rebuilding.
