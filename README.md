# BareMetal-App

A quick way to get going with testing [BareMetal-Firecracker](https://github.com/ReturnInfinity/BareMetal-Firecracker), [BareMetal-AppPort](https://github.com/ReturnInfinity/BareMetal-AppPort), and uploading your program to [BareMetal Cloud](https://baremetal.returninfinity.com).

BareMetal is an exokernel written in x86-64 Assembly that expects a payload program. Your C program is compiled into an `.app` and is combined with the BareMetal kernel to produce a single bootable `.elf` unikernel. It can then be run directly in Firecracker microVM with as little as 4MiB of RAM. This repo wires together the pieces needed to go from a C file on your laptop to a running instance, either locally in a VM for fast iteration or on BareMetal Cloud for real deployment.

## Quickstart

Log into [BareMetal Cloud](https://baremetal.returninfinity.com), open API keys, and create a new API key.

Enter the following commands, pasting the new key when `./bmcloud login` asks for it:

```
git clone https://github.com/ReturnInfinity/BareMetal-App
cd BareMetal-App
./setup.sh
./bmcloud login
cp BareMetal-AppPort/hello.c .
./1-build.sh hello.c
./2-run.sh
./3-upload.sh
```

When prompted to upload to cloud hit `Y`. Your program should be running in BareMetal Cloud now.

`./1-build.sh` writes the name of the `.app` it built to `.prog_app` in the repo root, which `./3-upload.sh` reads back so it knows which file to upload — this is what lets the two scripts be run separately, one after the other.

Confirm it:
`./bmcloud vm list`

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

This runs a "pre-flight" check to verify the prerequisites above are installed (including `mkfs.ext2`, from `e2fsprogs`), then clones `BareMetal-AppPort` and `BareMetal-Firecracker` alongside this repo, copies the bundled libraries in `files/` (lwIP, mbedTLS, musl) into the app-port build directory, builds everything, and downloads the [`bmcloud`](https://baremetal.returninfinity.com/cli/bmcloud) CLI into the repo root. It also creates a 512M `disk.img`, formatted as a plain EXT2 filesystem (`mkfs.ext2 -b 4096` - the 4096-byte block size matters, see `setup.sh`'s comment) for the VM to boot against; `BareMetal-AppPort/port/ext4_shim.c` mounts it through lwext4. A CA bundle (`files/cacert.pem`) is installed onto that image too, so `https://` requests (`tls_shim.c`, `curltest.c`) verify the server's certificate rather than trusting it blindly; the same bundle is also compiled directly into every app binary as a fallback, so verification still works even with no disk attached at all.

Re-running `./setup.sh` starts from a clean slate — it calls `./clean.sh` first, which removes the cloned repos, `baremetal.elf`, `disk.img`, and `bmcloud`.

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

### Run it under QEMU

```
./2-run-qemu.sh
```

Boot the same `baremetal.elf` in a QEMU `microvm` instead, with `disk.img` and a network device attached and the serial console in your terminal. QEMU exits when the app finishes; press `Ctrl-A` then `X` to quit early. Needs `qemu-system-x86_64` and access to `/dev/kvm`. The network uses `tap0` if it exists, otherwise QEMU's user-mode networking (outbound only, no host setup needed). There is no memory hot-plug under QEMU, so the VM gets `MEMSIZE` MiB up front (default 256; e.g. `MEMSIZE=1024 ./2-run-qemu.sh`). Arguments are passed to the app as with `./2-run.sh`.

## Upload it

Uploading requires an API key. Create one on the API keys page of the [BareMetal Cloud portal](https://baremetal.returninfinity.com), then save it once with:

```
./bmcloud login
```

Upload `baremetal.elf` to BareMetal Cloud as a kernel image and launch it as a VM:

```
./3-upload.sh
```

The image and the VM are both named after your program (e.g. `hello`). See [Deploying to BareMetal Cloud](#deploying-to-baremetal-cloud) for managing it afterwards.

### Local networking (optional)

Local VM testing needs a `tap0` device. Create one with:

```
./BareMetal-Firecracker/scripts/mkbr0.sh
```

This sets up a `br0` bridge with `tap0` attached in promiscuous mode. On a wired connection the host NIC is enslaved to the bridge for full L2 visibility to the VM; on Wi-Fi (which can't be bridged in station mode) it falls back to NAT so the guest still has outbound connectivity. If `tap0` isn't present, `./2-run.sh` warns and starts the VM without network access, and `./2-run-qemu.sh` falls back to QEMU's user-mode networking.

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

`./2-run.sh` calls `start`, `attach` (when `screen` is installed), and `output --full` for you; use these directly when iterating without rebuilding, or `attach` to interact with the running program.

## Deploying to BareMetal Cloud

![BareMetal Cloud UI](images/Screenshot.png)

`./3-upload.sh` handles a single upload-and-launch flow. For everything else, use `./bmcloud`, the BareMetal Cloud command-line client (`setup.sh` downloads it from <https://baremetal.returninfinity.com/cli/bmcloud>; `./3-upload.sh` fetches it if it's missing). It needs `bash` 4+, `curl`, and `jq`.

Authenticate with an API key from the portal's API keys page, either saved once or set per shell:

```
./bmcloud login               # prompts for the key and saves it to ~/.config/bmcloud/credentials
export BMC_API_KEY=bmc_...    # or provide it per shell/session
```

Then:

```
./bmcloud [--json] [--url URL] <command> [args...]
```

VMs and images can be referred to by id or by a unique name.

| Command | Description |
|---|---|
| `login` / `logout` | Save / remove the API key |
| `whoami` | Account, plan, balance, and limits |
| `vm list` | List your VMs |
| `vm show <vm>` | Status, hostname, memory, disk, forwards, and domains of a VM |
| `vm create <name> --kernel <image> [--ram MiB] [--hotplug MiB] [--disk ext2\|raw\|none\|image] [--disk-size MiB] [--disk-image <image>] [--args "app args"] [--no-start] [--no-https]` | Create (and by default start) a VM |
| `vm start\|stop\|suspend\|resume <vm>` | Lifecycle actions (applied asynchronously) |
| `vm wait <vm> <status> [--timeout SECONDS]` | Wait until a VM reaches a status, e.g. `running` |
| `vm delete <vm> [--yes]` | Delete a VM and its disk |
| `vm args <vm> "<app args>"` | Change app arguments (VM must be stopped) |
| `vm memory <vm> <ram-mib> [hotplug-mib]` | Change memory (VM must be stopped) |
| `vm console <vm> [--bytes N] [--follow]` | Print the VM's console output |
| `vm usage <vm>` | Hourly resource usage and cost |
| `vm forwards <vm>` | List port forwards |
| `vm forward-add <vm> <http\|tcp\|udp> <guest-port> [public-port]` | Forward a public port (or the HTTPS hostname) to the VM |
| `vm forward-rm <vm> <forward-id>` | Remove a port forward |
| `vm domains <vm>` | Custom domains and the DNS records they need |
| `vm domain-add <vm> <hostname>` | Add a custom domain |
| `vm domain-check <vm> <domain-id>` | Retry the DNS check and certificate now |
| `vm domain-rm <vm> <domain-id>` | Remove a custom domain |
| `image list` | List your images |
| `image upload <file> [--name NAME] [--kind auto\|kernel\|disk]` | Upload a built `.elf` (kernel) or a disk image |
| `image delete <image> [--yes]` | Delete an image |
| `billing` | Balance, spend, and recent transactions |
| `billing usage` | Hourly usage records |
| `billing topup <amount>` | Fund the account (opens Stripe Checkout) |

Pass `--json` before a command to print the raw JSON API response instead (for scripting). Run `./bmcloud help` for the full usage text.

## Cleaning up

```
./clean.sh
```

Removes the cloned `BareMetal-AppPort` and `BareMetal-Firecracker` repos, `examples`, `baremetal.elf`, `disk.img`, `.prog_app`, and `bmcloud`. Your saved `bmcloud login` credentials are kept. `setup.sh` runs this automatically before rebuilding.
