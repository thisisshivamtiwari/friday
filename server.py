from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler
import os


class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=os.path.dirname(__file__), **kwargs)


if __name__ == "__main__":
    port = int(os.environ.get("PORT", "8000"))
    host = "127.0.0.1"
    httpd = ThreadingHTTPServer((host, port), Handler)
    print(f"Serving Founder Office Copilot at http://{host}:{port}")
    httpd.serve_forever()
