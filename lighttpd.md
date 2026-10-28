# Serving a website with lighttpd

`lighttpd.app` is the [lighttpd](https://www.lighttpd.net/) 1.4.85 web server, ported to BareMetal. Unlike a C program, there's nothing for you to compile: `./setup.sh` builds the server once, and what changes from one site to the next is the config file and the web page files, which live on `disk.img`. lighttpd listens on port 80, logs to the VM's console, and keeps running until the VM is stopped.

For how the port itself works, and the full list of built-in modules, see `BareMetal-AppPort/LIGHTTPD.md`.

## Quickstart

After `./setup.sh` (see [README.md](README.md)), build and run the sample site:

```
./1-build.sh lighttpd
HOSTFWD=18080:80 ./2-run-qemu.sh
```

Then, from another terminal:

```
curl http://127.0.0.1:18080/
```

Press `Ctrl-A` then `X` to stop the VM.

## Your web page files

Put your site in a directory on your machine, with `index.html` at the top. Subdirectories, images, CSS and JavaScript all work:

```
mysite/
├── index.html
├── style.css
├── images/
│   └── logo.png
└── docs/
    └── index.html
```

## Building

```
./1-build.sh lighttpd [lighttpd.conf] [docroot-dir]
```

This does two things:

1. Copies the config to `/lighttpd/lighttpd.conf` on `disk.img`, and the contents of your site directory to `/lighttpd/www`, replacing any site that was there before. It also creates `/lighttpd/tmp`, where large request bodies are spooled.
2. Builds `baremetal.elf` around `lighttpd.app`.

With no arguments it uses the sample config and site in `BareMetal-AppPort/port/lighttpd_port/`. To serve your own site, pass a config and your site directory:

```
cp BareMetal-AppPort/port/lighttpd_port/lighttpd.conf .
./1-build.sh lighttpd lighttpd.conf mysite
```

The config comes first, so to use your own site you need to pass a config too; the sample one works as is.

Files are copied onto `disk.img` with `debugfs`, so no root access or loop mount is needed. If you change your site, run the same command again to copy the new version over. The rebuild of `baremetal.elf` is quick.

### Writing your own config

Start from `BareMetal-AppPort/port/lighttpd_port/lighttpd.conf`. Leave `server.document-root` set to `/lighttpd/www`, since that's where your site is copied. Most normal lighttpd options work, with a few differences from a regular host:

- **`server.max-fds` must be at least 128.** lighttpd indexes its tables by file descriptor number, and this port numbers its sockets from 100 to 115.
- **Keep `server.max-connections` at about 12 or less.** The network stack has 16 sockets, and one of them is the listener.
- **Don't set `server.errorlog`, `server.pid-file`, `server.username`/`server.groupname` or `server.chroot`.** There's no syslog, user accounts or processes, and logging already goes to the console.
- **Use prefix, suffix and equality conditions (`=^`, `=$`, `==`), not regexes (`=~`).** PCRE2 isn't built in, so regex conditions and the regex forms of `mod_rewrite`/`mod_redirect` aren't available.
- **IPv4 only.** Bind to `0.0.0.0` or an IPv4 address.
- **No CGI, and no TLS yet.** `mod_cgi` isn't available because there's no `fork()`. `mod_fastcgi`, `mod_scgi` and `mod_proxy` work with a backend that's already running on another machine. HTTPS isn't supported yet.

If you serve file types the sample config doesn't list, add them to `mimetype.assign`. Anything not listed is sent as `application/octet-stream`.

## Running it locally

### QEMU

QEMU's user-mode networking needs no host setup, but the guest isn't reachable from the host unless you forward a port to it. `HOSTFWD` maps a host port to guest port 80:

```
HOSTFWD=18080:80 ./2-run-qemu.sh
```

Open http://127.0.0.1:18080/ in a browser, or use `curl`. To forward more than one port, separate the pairs with spaces, e.g. `HOSTFWD="18080:80 18081:81"`.

If `tap0` exists, QEMU uses it instead and `HOSTFWD` is ignored. Connect to the guest's own address instead.

### Firecracker

```
./2-run.sh
```

This needs `tap0` (create it with `./BareMetal-Firecracker/scripts/mkbr0.sh`, see [README.md](README.md#local-networking-optional)). Connect to the guest's address on the `br0` network.

### Arguments

Arguments to `./2-run.sh` and `./2-run-qemu.sh` are added to lighttpd's command line, after the `-D -f /lighttpd/lighttpd.conf` it always gets. For example, `-tt` checks the config and exits, which is a quick way to catch mistakes in a new config:

```
./2-run-qemu.sh -tt
```

## Checking it's working

- The VM's console shows lighttpd's log, including any config errors at startup.
- The sample config turns on `mod_status`, so `/server-status` shows live connection stats.
- The sample config also turns on directory listings, so a directory without an `index.html` shows its files. Set `dir-listing.activate = "disable"` in your config if you don't want that.


## Running it in BareMetal Cloud

- Log into BareMetal Cloud at https://baremetal.returninfinity.com
- Click on Images
- In the Upload section click on Browse and select the `baremetal.elf` file, give it a name like "lighttpd unikernel", and click Upload
- In the Upload section again click on Browse and select the `disk.img` file, give it a name like "lighttpd disk", and click Upload
- Click on VMs
- Click on New VM
- Give the VM a name, select the kernel, from the Disk dropdown select From disk image, and then select the disk image
- Click Create VM
- Once the VM is created click on the Hostname to test access
