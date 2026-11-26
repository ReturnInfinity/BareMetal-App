# Serving a website with Caddy

`caddy.app` is the [Caddy](https://caddyserver.com/) 2.11.9 web server, ported to BareMetal. Like lighttpd, there's nothing for you to compile: the server is built once, and what changes from one site to the next is the Caddyfile and the web page files, which live on `disk.img`. Caddy logs to the VM's console and keeps running until the VM is stopped. Unlike lighttpd, it does HTTPS: with its own local certificate authority (`tls internal`) today, and with automatic certificates for a real domain.

For how the port itself works, see `BareMetal-AppPort/CADDY.md`.

## Building

```
./1-build.sh caddy [Caddyfile] [mysite]
```

This does three things:

1. Builds `caddy.app` if it isn't built yet. This needs [Go](https://go.dev/dl/) installed; the first build downloads Caddy's source modules. `./setup.sh` already does this step when Go is installed.
2. Copies the Caddyfile to `/caddy/Caddyfile` on `disk.img`, and the contents of your site directory to `/caddy/www`, replacing any site that was there before. Caddy's own data (certificates, its local CA) lives in `/caddy/data` and is kept, so certificates survive a redeploy.
3. Builds `baremetal.elf` around `caddy.app`.

With no arguments it uses the sample Caddyfile and site in `BareMetal-AppPort/port/caddy_port/`: plain HTTP on port 80, serving `/caddy/www`. To serve your own site, pass a Caddyfile and your site directory:

```
cp BareMetal-AppPort/port/caddy_port/Caddyfile .
./1-build.sh caddy Caddyfile mysite
```

### Writing your own Caddyfile

Start from the sample. Keep `root * /caddy/www`, since that's where your site is copied. Most Caddyfile directives work: `file_server`, `encode`, `respond`, `redir`, `reverse_proxy` to a backend on another machine, `header`, `log`, and so on. Differences from a regular host:

- **HTTPS with a local CA works out of the box.** A site block like `localhost { tls internal }` gets a certificate from Caddy's own CA. Browsers won't trust that CA unless you install its root (`/caddy/data/caddy/pki/authorities/local/root.crt` on `disk.img`); keep `skip_install_trust` in the global options, since there's no system trust store to install it into.
- **Automatic HTTPS for a real domain** (Let's Encrypt / ZeroSSL) needs the domain's DNS pointing at the VM and ports 80 and 443 reachable from the internet. It isn't tested yet.
- **The admin API** (`localhost:2019`) works, but nothing outside the VM can reach it. The sample turns it off with `admin off`.
- **IPv4 only**, and **about 12 connections at once** (the network stack has 16 sockets).
- **Nothing that runs other programs** (`exec`-based plugins): there's no `fork()`.
- **A warning at startup is harmless:** `failed to set GOMAXPROCS ... /proc/self/mountinfo`.

## Running it locally

Caddy needs more boot memory than other apps: at least 60 MiB, and an even number.

### Firecracker

```
MEMSIZE=64 ./2-run.sh
```

This needs `tap0` (create it with `./BareMetal-Firecracker/scripts/mkbr0.sh`, see [README.md](README.md#local-networking-optional)). Connect to the guest's address on the `br0` network. Without `tap0` Caddy still starts, after the 30-second DHCP timeout, but isn't reachable.

### QEMU

QEMU's default 256 MiB is enough. Forward host ports to the guest's 80 (and 443 for HTTPS):

```
HOSTFWD="18080:80 18443:443" ./2-run-qemu.sh
curl http://127.0.0.1:18080/
```

For a `localhost` site with `tls internal`: `curl -k --resolve localhost:18443:127.0.0.1 https://localhost:18443/`.

### Arguments

Arguments to `./2-run.sh` and `./2-run-qemu.sh` replace Caddy's command line, which is otherwise `caddy run --config /caddy/Caddyfile --adapter caddyfile`. For example, to check a new Caddyfile without starting the server:

```
./2-run-qemu.sh validate --config /caddy/Caddyfile --adapter caddyfile
```

`./2-run-qemu.sh version` prints Caddy's version.

## Running it in BareMetal Cloud

The same as for lighttpd (see [lighttpd.md](lighttpd.md#running-it-in-baremetal-cloud)): upload `baremetal.elf` and `disk.img` as images, then create a VM from them. Caddy needs at least 60 MiB of boot memory.
