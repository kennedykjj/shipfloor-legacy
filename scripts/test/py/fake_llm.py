"""A fake OpenAI-compatible endpoint for the provider tests (#151): GET /v1/models and POST /v1/responses on
127.0.0.1, on a port of the OS's choosing, in a thread of the test process.

modes: "ok" (both answer), "no-responses" (/v1/responses is 404, as an endpoint with chat completions only),
"429" (/v1/responses answers 429 Too Many Requests), "down" (nothing listens: the port was taken and given back).
The Authorization header of every request is recorded in .auth, the paths in .paths; the value of the key is
never printed."""
import json
import socket
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class FakeLLM:
    def __init__(self, mode="ok", models=("qwen3-coder",)):
        self.mode, self.models = mode, list(models)
        self.auth, self.paths = [], []
        self.server = None
        if mode == "down":
            s = socket.socket()
            s.bind(("127.0.0.1", 0))
            self.port = s.getsockname()[1]
            s.close()
            return
        fake = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def _send(self, code, body):
                data = json.dumps(body).encode()
                self.send_response(code)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def _note(self):
                fake.auth.append(self.headers.get("Authorization"))
                fake.paths.append("%s %s" % (self.command, self.path))

            def do_GET(self):
                self._note()
                if self.path.rstrip("/") == "/v1/models":
                    self._send(200, {"object": "list", "data": [{"id": m, "object": "model"} for m in fake.models]})
                else:
                    self._send(404, {"error": "not found"})

            def do_POST(self):
                self._note()
                n = int(self.headers.get("Content-Length") or 0)
                self.rfile.read(n)
                if self.path.rstrip("/") != "/v1/responses" or fake.mode == "no-responses":
                    self._send(404, {"error": "not found"})
                elif fake.mode == "429":
                    self._send(429, {"error": {"message": "rate limit exceeded"}})
                else:
                    self._send(200, {"id": "resp_1", "object": "response", "status": "completed", "output": []})

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.port = self.server.server_address[1]
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    @property
    def base_url(self):
        return "http://127.0.0.1:%d/v1" % self.port

    @property
    def host(self):
        return "127.0.0.1:%d" % self.port

    def stop(self):
        if self.server:
            self.server.shutdown()
            self.server.server_close()
            self.server = None
