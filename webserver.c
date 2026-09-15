// webserver.c -- minimal HTTP server: binds/listens on LISTEN_PORT,
// accepts one connection at a time, and replies with a page echoing
// back the request headers it received. Proves the musl -> posix_shim
// -> net_shim -> lwIP TCP server-side (bind/listen/accept) path works
// end to end.
// build with build-app.sh

#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>

#define LISTEN_PORT 80

// Escape '<', '>', and '&' so raw request headers can be embedded in
// the HTML response without being interpreted as markup.
static void html_escape(char *dst, size_t dstsz, const char *src)
{
	size_t di = 0;
	for (size_t si = 0; src[si] != '\0' && di + 6 < dstsz; si++) {
		char c = src[si];
		if (c == '<') {
			memcpy(dst + di, "&lt;", 4);
			di += 4;
		} else if (c == '>') {
			memcpy(dst + di, "&gt;", 4);
			di += 4;
		} else if (c == '&') {
			memcpy(dst + di, "&amp;", 5);
			di += 5;
		} else {
			dst[di++] = c;
		}
	}
	dst[di] = '\0';
}

int main(void)
{
	int lfd = socket(AF_INET, SOCK_STREAM, 0);
	if (lfd < 0) {
		printf("socket() failed\n");
		return 1;
	}

	struct sockaddr_in addr;
	memset(&addr, 0, sizeof(addr));
	addr.sin_family = AF_INET;
	addr.sin_port = htons(LISTEN_PORT);
	addr.sin_addr.s_addr = INADDR_ANY;

	if (bind(lfd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
		printf("bind() to port %d failed\n", LISTEN_PORT);
		close(lfd);
		return 1;
	}

	if (listen(lfd, 4) < 0) {
		printf("listen() failed\n");
		close(lfd);
		return 1;
	}

	printf("listening on port %d\n", LISTEN_PORT);

	unsigned long hits = 0;

	for (;;) {
		struct sockaddr_in cliaddr;
		socklen_t clilen = sizeof(cliaddr);

		int cfd = accept(lfd, (struct sockaddr *)&cliaddr, &clilen);
		if (cfd < 0) {
			// accept() blocks for at most 30s (see OPENISSUES.md) and
			// returns EAGAIN/EWOULDBLOCK if nobody connected in that
			// window -- just go back and wait for the next one.
			if (errno == EAGAIN || errno == EWOULDBLOCK)
				continue;
			printf("accept() failed\n");
			continue;
		}

		hits++;

		char ip[INET_ADDRSTRLEN];
		strcpy(ip, inet_ntoa(cliaddr.sin_addr));
		printf("connection from %s:%d\n", ip, ntohs(cliaddr.sin_port));

		// Don't bother parsing the request -- just capture whatever
		// headers the client sent and echo them back as the page.
		char reqbuf[4096];
		int n = recv(cfd, reqbuf, sizeof(reqbuf) - 1, 0);
		reqbuf[n > 0 ? n : 0] = '\0';

		char escaped[4096 * 3];
		html_escape(escaped, sizeof(escaped), reqbuf);

		static const char *style =
			"<style>"
			"body{margin:0;padding:2rem;min-height:100vh;box-sizing:border-box;"
			"background:linear-gradient(135deg,#1e293b,#0f172a);"
			"font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;"
			"display:flex;justify-content:center;align-items:flex-start}"
			".card{max-width:40rem;width:100%;background:#fff;border-radius:12px;"
			"box-shadow:0 10px 30px rgba(0,0,0,.3);padding:2rem 2.5rem;color:#1e293b}"
			"h1{margin-top:0;color:#0f172a}"
			".hits{display:inline-block;background:#e0e7ff;color:#3730a3;"
			"font-weight:600;padding:.25rem .6rem;border-radius:999px;font-size:.9rem}"
			"pre{background:#0f172a;color:#e2e8f0;padding:1rem;border-radius:8px;"
			"overflow-x:auto;font-size:.85rem;line-height:1.4}"
			"</style>";

		char body[4096 * 3 + 1024];
		int blen = snprintf(body, sizeof(body),
			"<html><head><title>BareMetal Web Server</title>%s</head>"
			"<body><div class=\"card\"><h1>Hello!</h1>"
			"<p>This web server is running in a BareMetal microVM.</p>"
			"<p>Hits: <span class=\"hits\">%lu</span></p>"
			"<p>Headers received:</p>"
			"<pre>%s</pre></div></body></html>\n", style, hits, escaped);

		char resp[sizeof(body) + 256];
		int rlen = snprintf(resp, sizeof(resp),
			"HTTP/1.0 200 OK\r\n"
			"Content-Type: text/html\r\n"
			"Content-Length: %d\r\n"
			"Connection: close\r\n"
			"\r\n"
			"%s", blen, body);

		send(cfd, resp, rlen, 0);
		close(cfd);
	}

	close(lfd);
	return 0;
}
