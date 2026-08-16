#!/usr/bin/env python3
"""Simple HTTP server with a hit counter."""

import platform
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from threading import Lock

HOST = "0.0.0.0"
PORT = 80

hit_count = 0
hit_count_lock = Lock()


class HitCounterHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        global hit_count
        with hit_count_lock:
            hit_count += 1
            count = hit_count

        print(f"Connection from {self.client_address[0]}:{self.client_address[1]} - {self.requestline}")

        info_rows = "".join(
            f"<tr><th>{label}</th><td>{value}</td></tr>"
            for label, value in (
                ("Python version", platform.python_version()),
                ("Python implementation", platform.python_implementation()),
                ("Python build", " ".join(platform.python_build())),
                ("Python compiler", platform.python_compiler()),
                ("Executable", sys.executable),
            )
        )

        body = f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>BareMetal-App</title>
<style>
  body {{
    margin: 0;
    padding: 3rem 1.5rem;
    background: #0f172a;
    color: #e2e8f0;
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    display: flex;
    justify-content: center;
  }}
  .card {{
    background: #1e293b;
    border-radius: 12px;
    padding: 2rem 2.5rem;
    max-width: 640px;
    width: 100%;
    box-shadow: 0 10px 30px rgba(0, 0, 0, 0.3);
  }}
  h1 {{
    margin-top: 0;
    font-size: 1.5rem;
    color: #38bdf8;
  }}
  .hits {{
    font-size: 2.5rem;
    font-weight: 700;
    color: #f8fafc;
    margin: 0.25rem 0 1.5rem;
  }}
  table {{
    width: 100%;
    border-collapse: collapse;
    font-size: 0.9rem;
  }}
  th, td {{
    text-align: left;
    padding: 0.5rem 0;
    border-bottom: 1px solid #334155;
  }}
  th {{
    color: #94a3b8;
    font-weight: 500;
    width: 40%;
  }}
  td {{
    color: #e2e8f0;
    word-break: break-all;
  }}
</style>
</head>
<body>
  <div class="card">
    <h1>Hello!</h1>
    <p class="hits">{count} hit(s)</p>
    <table>{info_rows}</table>
  </div>
</body>
</html>
""".encode("utf-8")

        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        pass


def main():
    server = HTTPServer((HOST, PORT), HitCounterHandler)
    print(f"Running on Python {platform.python_version()} ({platform.python_implementation()})")
    print(f"Serving on http://{HOST}:{PORT}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down.")
        server.server_close()


if __name__ == "__main__":
    main()
