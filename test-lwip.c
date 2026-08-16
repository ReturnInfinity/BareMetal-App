// test-lwip.c -- exercises every lwIP component this port builds (see
// setup.sh's LWIP_SRCS and port/lwip_port/lwipopts.h) and prints a
// pass/fail line for each, plus a final summary. Exit code is the
// failure count (0 = everything passed). Modeled on test-mbedtls.c's
// three-tier layout.
//
// Unlike mbedTLS, lwIP ships no mbedtls_xxx_self_test()-style known-
// answer tests, so this is written from scratch as three tiers:
//
//   - Component unit tests: call each core module's own public API
//     directly (lwip/pbuf.h, lwip/mem.h, etc -- see build-app.sh's
//     LWIP_INC/LWIP_PORT comment for how an app source gets to
//     #include these at all) with no network required. These run
//     first, before anything below has touched net_shim.c/dns_shim.c.
//
//   - Port integration checks: the first POSIX socket() call below
//     triggers net_shim_socket()'s net_ensure_ready() (see
//     port/net_glue.c) the same way any other app's first network
//     call does -- lwip_init(), netif_add()/netif_set_up(), then
//     DHCP or the Firecracker "ip=" static path, whichever applies.
//     This section confirms that actually left the netif up with a
//     real IPv4 address, using lwIP's own public netif_default global
//     (lwip/netif.h) rather than reaching into net_glue.c's internals.
//
//   - Live network checks: the same connect-then-talk sequence
//     net_test.c/tcp_test.c/udp_test.c already use, against the same
//     hosts, to exercise tcp.c/tcp_in.c/tcp_out.c, udp.c, dns.c, and
//     (via the ARP cache check that follows them) etharp.c/ip4.c/
//     netif/ethernet.c all under real traffic rather than synthetic
//     unit tests. Needs tap0/internet (see 2-run.sh); a DNS/TCP/UDP-
//     level failure reports SKIP rather than FAIL, since that means
//     "no network," not "lwIP misbehaved."
//
// build with build-app.sh
//
// This is also a valid *nix program of course (net_shim.c/dns_shim.c
// aren't involved on a real Linux box, but plain BSD sockets are).

#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <netdb.h>

#include "lwip/init.h"
#include "lwip/def.h"
#include "lwip/mem.h"
#include "lwip/memp.h"
#include "lwip/pbuf.h"
#include "lwip/inet_chksum.h"
#include "lwip/ip4_addr.h"
#include "lwip/dns.h"
#include "lwip/netif.h"
#include "lwip/etharp.h"
#include "lwip/stats.h"

static int passed, failed, skipped;

typedef enum { CHK_PASS, CHK_FAIL, CHK_SKIP } result_t;

static void report(const char *label, result_t result, const char *detail)
{
	const char *tag = result == CHK_PASS ? "PASS" : result == CHK_SKIP ? "SKIP" : "FAIL";

	if (detail && detail[0])
		printf("  %-42s [%s] (%s)\n", label, tag, detail);
	else
		printf("  %-42s [%s]\n", label, tag);

	if (result == CHK_PASS)
		passed++;
	else if (result == CHK_SKIP)
		skipped++;
	else
		failed++;
}

static void ok(const char *label, int cond)
{
	report(label, cond ? CHK_PASS : CHK_FAIL, NULL);
}

// ---------------------------------------------------------------------------
// Component unit tests -- no network needed.
// ---------------------------------------------------------------------------

// def.c: on this little-endian x86-64 target, lwip_htons()/lwip_htonl()
// (what htons()/htonl() expand to -- see lwip/def.h) have to actually
// swap bytes, unlike the BYTE_ORDER==BIG_ENDIAN identity-macro path
// def.h also offers. Checks the real byte pattern in memory, not just
// that htons(ntohs(x))==x (which a broken no-op pair would also pass).
static int test_byteorder(void)
{
	uint16_t h16 = htons(0x1234);
	unsigned char b16[2];
	memcpy(b16, &h16, 2);

	uint32_t h32 = htonl(0x12345678UL);
	unsigned char b32[4];
	memcpy(b32, &h32, 4);

	return b16[0] == 0x12 && b16[1] == 0x34 &&
	       b32[0] == 0x12 && b32[1] == 0x34 && b32[2] == 0x56 && b32[3] == 0x78 &&
	       ntohs(h16) == 0x1234 && ntohl(h32) == 0x12345678UL;
}

// inet_chksum.c: rather than hand-computing an expected constant (easy
// to get wrong), uses the Internet checksum's own self-verifying
// identity -- writing a buffer's checksum into the two bytes right
// after it (a plain memcpy, the same raw assignment icmp.c/udp.c/ip4.c
// use for a real header's chksum field, e.g. icmp.c's `icmphdr->chksum
// = inet_chksum(icmphdr, q->len)`, no extra htons() involved) and
// re-checksumming the extended buffer must fold to exactly zero -- the
// same identity ip4.c's own receive path relies on when it checksums a
// whole IP header, chksum field included, and expects zero back.
// That identity depends on the chksum field landing 16-bit-aligned
// relative to the start of the checksummed region, the same way a
// real protocol header's chksum field always does -- lwIP's
// LWIP_CHKSUM_ALGORITHM==2 (the default; see inet_chksum.c) sums the
// buffer as 16-bit words from its start, so an odd-length message
// would leave the appended field straddling a word boundary instead
// and break the fold. Message length is deliberately even here.
static int test_inet_chksum(void)
{
	static const char msg[] = "The quick brown fox jumps over the lazy dog.";
	unsigned char buf[sizeof(msg) - 1 + 2];

	memcpy(buf, msg, sizeof(msg) - 1);
	u16_t chksum = inet_chksum(buf, sizeof(msg) - 1);
	memcpy(buf + sizeof(msg) - 1, &chksum, sizeof(chksum));

	return inet_chksum(buf, sizeof(buf)) == 0;
}

// ip4_addr.c: parse/format round trip, plus confirming garbage is
// actually rejected rather than ip4addr_aton() silently accepting it
// (it implements permissive legacy inet_aton() syntax -- see
// net_glue.c's fc_parse_ip_param() comment -- so this checks the
// rejection path still exists at all, not that it's maximally strict).
static int test_ip4_addr(void)
{
	ip4_addr_t addr;

	if (!ip4addr_aton("192.168.1.1", &addr))
		return 0;
	if (strcmp(ip4addr_ntoa(&addr), "192.168.1.1") != 0)
		return 0;
	if (ip4addr_aton("not.an.ip.address", &addr))
		return 0;

	return 1;
}

// pbuf.c: single-pbuf alloc/write/read/free round trip (PBUF_RAM,
// routed through mem_malloc -- see MEM_LIBC_MALLOC in lwipopts.h),
// then a two-pbuf pbuf_cat() chain to exercise chain bookkeeping.
// pbuf_free()'s return value is the number of pbufs actually
// deallocated from the head of the chain (see pbuf.c's own doc
// comment) -- 1 for the lone pbuf, 2 once both links of the freshly
// pbuf_cat()'d chain (each still at its initial refcount of 1) go
// away together.
static int test_pbuf(void)
{
	static const char msg[] = "pbuf round trip";
	struct pbuf *p = pbuf_alloc(PBUF_RAW, sizeof(msg), PBUF_RAM);
	if (!p)
		return 0;

	int ok1 = p->tot_len == sizeof(msg) && p->len == sizeof(msg);
	ok1 = ok1 && pbuf_take(p, msg, sizeof(msg)) == ERR_OK;

	char out[sizeof(msg)];
	ok1 = ok1 && pbuf_copy_partial(p, out, sizeof(out), 0) == sizeof(out);
	ok1 = ok1 && memcmp(out, msg, sizeof(msg)) == 0;
	ok1 = ok1 && pbuf_free(p) == 1;

	struct pbuf *a = pbuf_alloc(PBUF_RAW, 4, PBUF_RAM);
	struct pbuf *b = pbuf_alloc(PBUF_RAW, 4, PBUF_RAM);
	int ok2 = a && b;
	if (ok2) {
		pbuf_cat(a, b);
		ok2 = a->tot_len == 8 && pbuf_free(a) == 2;
	}

	return ok1 && ok2;
}

// mem.c: with MEM_LIBC_MALLOC=1 (lwipopts.h) this is a thin wrapper
// over musl's malloc/free rather than lwIP's own static heap -- still
// worth confirming the wrapper itself round-trips real data rather
// than e.g. handing back unwritable or aliased memory.
static int test_mem(void)
{
	unsigned char *p = mem_malloc(64);
	if (!p)
		return 0;

	memset(p, 0xAA, 64);
	int ok1 = p[0] == 0xAA && p[63] == 0xAA;
	mem_free(p);

	return ok1;
}

// memp.c: MEMP_TCP_PCB is one of the pools LWIP_TCP=1 compiles in
// (see priv/memp_std.h). Only writes a handful of bytes rather than
// sizeof(struct tcp_pcb) -- that struct's full definition lives in
// lwip/priv/tcp_priv.h, which this file doesn't need to pull in just
// to prove the pool hands back real, writable memory.
static int test_memp(void)
{
	unsigned char *p = memp_malloc(MEMP_TCP_PCB);
	if (!p)
		return 0;

	memset(p, 0x55, 4);
	int ok1 = p[0] == 0x55 && p[3] == 0x55;
	memp_free(MEMP_TCP_PCB, p);

	return ok1;
}

// dns.c: dns_gethostbyname() short-circuits to ERR_OK with no callback
// and no network I/O at all when the "hostname" is already a numeric
// IPv4 literal (see dns_shim.c's own resolve() comment) -- this is the
// one DNS-layer behavior testable without touching the network.
static int test_dns_numeric_literal(void)
{
	ip_addr_t addr;
	err_t e = dns_gethostbyname("203.0.113.7", &addr, NULL, NULL);

	return e == ERR_OK && ip4_addr_get_u32(ip_2_ip4(&addr)) == PP_HTONL(0xCB007107UL);
}

// ---------------------------------------------------------------------------
// Live network checks -- needs tap0/internet (see 2-run.sh).
// ---------------------------------------------------------------------------

#define TCP_HOST "one.one.one.one"
#define TCP_PORT 80
#define UDP_HOST "1.1.1.1"
#define UDP_PORT 53

// Same connect-then-GET sequence as net_test.c: proves tcp.c/tcp_in.c/
// tcp_out.c (and gethostbyname()'s dns_shim.c->dns.c path) work end to
// end, over real traffic rather than a synthetic unit test.
static result_t live_tcp(char *why, size_t why_len)
{
	why[0] = '\0';

	struct hostent *he = gethostbyname(TCP_HOST);
	if (!he) {
		snprintf(why, why_len, "gethostbyname(%s) failed", TCP_HOST);
		return CHK_SKIP;
	}

	int fd = socket(AF_INET, SOCK_STREAM, 0);
	if (fd < 0) {
		snprintf(why, why_len, "socket() failed");
		return CHK_SKIP;
	}

	struct sockaddr_in addr;
	memset(&addr, 0, sizeof(addr));
	addr.sin_family = AF_INET;
	addr.sin_port = htons(TCP_PORT);
	memcpy(&addr.sin_addr, he->h_addr, sizeof(addr.sin_addr));

	if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
		close(fd);
		snprintf(why, why_len, "connect() to %s:%d failed", TCP_HOST, TCP_PORT);
		return CHK_SKIP;
	}

	static const char req[] = "GET / HTTP/1.0\r\nHost: " TCP_HOST "\r\nConnection: close\r\n\r\n";
	if (send(fd, req, sizeof(req) - 1, 0) < 0) {
		close(fd);
		snprintf(why, why_len, "send() failed");
		return CHK_SKIP;
	}

	char buf[64];
	long n = recv(fd, buf, sizeof(buf) - 1, 0);
	close(fd);

	if (n <= 0) {
		snprintf(why, why_len, "recv() got no data");
		return CHK_SKIP;
	}
	buf[n] = '\0';

	if (strncmp(buf, "HTTP/", 5) != 0) {
		snprintf(why, why_len, "response didn't start with \"HTTP/\"");
		return CHK_FAIL;
	}

	return CHK_PASS;
}

// Same hand-built DNS-over-UDP query as udp_test.c: proves udp.c's
// sendto()/recvfrom() path independently of TCP.
static result_t live_udp(char *why, size_t why_len)
{
	why[0] = '\0';

	int fd = socket(AF_INET, SOCK_DGRAM, 0);
	if (fd < 0) {
		snprintf(why, why_len, "socket() failed");
		return CHK_SKIP;
	}

	struct sockaddr_in addr;
	memset(&addr, 0, sizeof(addr));
	addr.sin_family = AF_INET;
	addr.sin_port = htons(UDP_PORT);
	inet_pton(AF_INET, UDP_HOST, &addr.sin_addr);

	static const unsigned char query[] = {
		0x13, 0x37,             // ID
		0x01, 0x00,             // flags: recursion desired
		0x00, 0x01,             // QDCOUNT = 1
		0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
		7, 'e','x','a','m','p','l','e', 3, 'c','o','m', 0,
		0x00, 0x01,             // QTYPE = A
		0x00, 0x01,             // QCLASS = IN
	};

	if (sendto(fd, query, sizeof(query), 0, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
		close(fd);
		snprintf(why, why_len, "sendto() failed");
		return CHK_SKIP;
	}

	unsigned char resp[512];
	long n = recvfrom(fd, resp, sizeof(resp), 0, NULL, NULL);
	close(fd);

	if (n < 12) {
		snprintf(why, why_len, "recvfrom() got no/short reply");
		return CHK_SKIP;
	}

	int id_matches = resp[0] == query[0] && resp[1] == query[1];
	int is_response = (resp[2] & 0x80) != 0; // QR bit

	if (!id_matches || !is_response) {
		snprintf(why, why_len, "reply id/QR bit didn't match the query");
		return CHK_FAIL;
	}

	return CHK_PASS;
}

// gethostbyname.c (dns_shim.c) -> dns.c, over the wire this time (a
// real hostname, not the numeric-literal fast path test_dns_numeric_
// literal() above already covers).
static result_t live_dns(char *why, size_t why_len)
{
	why[0] = '\0';

	struct hostent *he = gethostbyname(TCP_HOST);
	if (!he) {
		snprintf(why, why_len, "gethostbyname(%s) failed", TCP_HOST);
		return CHK_SKIP;
	}

	struct in_addr a;
	memcpy(&a, he->h_addr, sizeof(a));
	if (a.s_addr == 0) {
		snprintf(why, why_len, "resolved to 0.0.0.0");
		return CHK_FAIL;
	}

	snprintf(why, why_len, "-> %s", inet_ntoa(a));
	return CHK_PASS;
}

// etharp.c: by this point (called after the TCP/UDP/DNS checks above),
// at least one packet has had to leave the netif addressed to the
// gateway, which means etharp_output() had to ARP-resolve it first --
// so a hit here is proof ARP resolution and Ethernet framing both
// actually worked, not just that the higher layers reported success.
static result_t live_arp_cache(char *why, size_t why_len)
{
	why[0] = '\0';

	if (!netif_default || !netif_is_up(netif_default) ||
	    ip4_addr_isany_val(*netif_ip4_gw(netif_default))) {
		snprintf(why, why_len, "no netif/gateway to check");
		return CHK_SKIP;
	}

	struct eth_addr *eth_ret;
	const ip4_addr_t *ip_ret;
	ssize_t idx = etharp_find_addr(netif_default, netif_ip4_gw(netif_default), &eth_ret, &ip_ret);

	if (idx < 0) {
		snprintf(why, why_len, "no ARP cache entry for the gateway");
		return CHK_SKIP;
	}

	return CHK_PASS;
}

int main(void)
{
	printf("BareMetal test-lwip -- lwIP %s\n\n", LWIP_VERSION_STRING);

	printf("component unit tests (no network required):\n");
	ok("byte order (def.c)", test_byteorder());
	ok("Internet checksum (inet_chksum.c)", test_inet_chksum());
	ok("IPv4 address parse/format (ip4_addr.c)", test_ip4_addr());
	ok("pbuf alloc/write/read/cat/free (pbuf.c)", test_pbuf());
	ok("mem_malloc/mem_free (mem.c)", test_mem());
	ok("memp_malloc/memp_free (memp.c)", test_memp());
	ok("DNS numeric-literal fast path (dns.c)", test_dns_numeric_literal());
	report("stats (stats.c)", CHK_SKIP, "LWIP_STATS=0 in lwipopts.h -- module compiled in but inert");

	// First real socket() call below triggers net_ensure_ready() (see
	// port/net_glue.c) -- lwIP init, netif bring-up, DHCP-or-static
	// address assignment -- the same way every other app's first
	// network touch does. Block on it explicitly here so the report
	// below reflects the outcome rather than racing it.
	printf("\nport integration checks (brings up the real netif):\n");
	int probe_fd = socket(AF_INET, SOCK_DGRAM, 0);
	if (probe_fd >= 0)
		close(probe_fd);

	int netif_ready = netif_default && netif_is_up(netif_default) &&
			   !ip4_addr_isany_val(*netif_ip4_addr(netif_default));
	if (netif_ready) {
		char detail[64];
		snprintf(detail, sizeof(detail), "%s", ip4addr_ntoa(netif_ip4_addr(netif_default)));
		report("netif up + IPv4 address assigned (netif.c/dhcp.c/ip4.c)", CHK_PASS, detail);

		ip4_addr_t global_bcast;
		ip4addr_aton("255.255.255.255", &global_bcast);
		int bcast_ok = ip4_addr_isbroadcast(&global_bcast, netif_default) &&
			       !ip4_addr_isbroadcast(netif_ip4_addr(netif_default), netif_default);
		ok("broadcast address classification (ip4_addr.c)", bcast_ok);
	} else {
		report("netif up + IPv4 address assigned (netif.c/dhcp.c/ip4.c)", CHK_FAIL, "no address after net_ensure_ready()");
		report("broadcast address classification (ip4_addr.c)", CHK_SKIP, "no netif to check against");
	}

	printf("\nlive network checks (needs tap0/internet -- see 2-run.sh):\n");
	char why[128];

	report("TCP connect + HTTP GET (tcp.c/tcp_in.c/tcp_out.c)", live_tcp(why, sizeof(why)), why);
	report("UDP sendto/recvfrom (udp.c)", live_udp(why, sizeof(why)), why);
	report("DNS resolve over the wire (dns.c)", live_dns(why, sizeof(why)), why);
	report("ARP cache entry for gateway (etharp.c)", live_arp_cache(why, sizeof(why)), why);

	printf("\n%d/%d passed", passed, passed + failed);
	if (skipped)
		printf(", %d skipped", skipped);
	if (failed)
		printf(", %d FAILED\n", failed);
	else
		printf(", all OK\n");

	return failed;
}
