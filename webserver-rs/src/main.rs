// webserver-rs -- Rust counterpart to webserver.py: a single-threaded
// HTTP server with a hit counter, built on std::net::TcpListener.
// Exercises the musl -> posix_shim -> net_shim -> lwIP TCP
// server-side (bind/listen/accept) path via full `std`, the same way
// webserver.c and webserver.py already do for C and Python.

use std::io::{BufRead, BufReader, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::atomic::{AtomicU64, Ordering};

const HOST: &str = "0.0.0.0";
const PORT: u16 = 80;

static HIT_COUNT: AtomicU64 = AtomicU64::new(0);

fn handle_connection(mut stream: TcpStream) -> std::io::Result<()> {
    let peer = stream.peer_addr().ok();
    let mut reader = BufReader::new(&stream);

    let mut request_line = String::new();
    reader.read_line(&mut request_line)?;
    let request_line = request_line.trim_end();

    // Drain the rest of the request headers up to the blank line that
    // terminates them -- we don't need them, but a real client (curl,
    // a browser) expects the server to have read the full request
    // before it starts reading the response.
    loop {
        let mut line = String::new();
        if reader.read_line(&mut line)? == 0 || line == "\r\n" || line == "\n" {
            break;
        }
    }

    let count = HIT_COUNT.fetch_add(1, Ordering::Relaxed) + 1;

    match peer {
        Some(addr) => println!("Connection from {addr} - {request_line}"),
        None => println!("Connection from ? - {request_line}"),
    }

    let info_rows = [
        ("rustc version", env!("RUSTC_VERSION")),
        ("Crate version", env!("CARGO_PKG_VERSION")),
        ("Target triple", "x86_64-baremetal-firecracker"),
        (
            "Platform",
            "BareMetal unikernel (reports as std::env::consts::OS \
             = \"linux\" -- see BareMetal-AppPort/RUST.md)",
        ),
    ]
    .iter()
    .map(|(label, value)| format!("<tr><th>{label}</th><td>{value}</td></tr>"))
    .collect::<String>();

    let body = format!(
        r#"<!DOCTYPE html>
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
    color: #f74c00;
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
"#
    );

    write!(
        stream,
        "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        body.len()
    )?;
    stream.write_all(body.as_bytes())?;
    stream.flush()
}

fn main() -> std::io::Result<()> {
    let listener = TcpListener::bind((HOST, PORT))?;
    println!(
        "Running webserver-rs {}, built with {}",
        env!("CARGO_PKG_VERSION"),
        env!("RUSTC_VERSION")
    );
    println!("Serving on http://{HOST}:{PORT}");

    for stream in listener.incoming() {
        match stream {
            Ok(stream) => {
                if let Err(e) = handle_connection(stream) {
                    eprintln!("error handling connection: {e}");
                }
            }
            Err(e) => eprintln!("error accepting connection: {e}"),
        }
    }

    Ok(())
}
