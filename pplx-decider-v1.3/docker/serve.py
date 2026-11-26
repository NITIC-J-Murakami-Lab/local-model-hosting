"""Minimal HTTP server for pplx-decider-v1.3 (Python standard library only).

    python3 serve.py --model <checkpoint dir> --name <model name> [--host 0.0.0.0] [--port 8000]

Decisions use the library bundled with the checkpoint (source/src/pplx_decider) as is.
The server starts listening once the model has loaded. Endpoints:

- GET  /health     200 {"status": "ready"}
- GET  /v1/models  the served model name
- POST /v1/decide  the body is a JSON object in the model card's request schema (state, questions, images).
                   The reply is exactly what Decider.decide() returns. "model" is accepted and ignored.
                   images must be base64 data URLs, so that clients cannot make the server read files in the container.
                   Malformed and over-length requests get 422 {"detail": "..."}.

A lock inside Decider runs the decisions one request at a time.
"""

from __future__ import annotations

import argparse
import json
import sys
import traceback
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

DECIDE_PATH = "/v1/decide"
# Generous, because images arrive as data URLs
MAX_BODY_BYTES = 256 << 20


class DecideServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, address: tuple[str, int], decider: Any, name: str, request_errors: tuple[type[Exception], ...]):
        super().__init__(address, Handler)
        self.decider = decider
        self.name = name
        self.request_errors = request_errors


class Handler(BaseHTTPRequestHandler):
    server: DecideServer

    def do_GET(self) -> None:
        if self.path == "/health":
            self._reply(HTTPStatus.OK, {"status": "ready"})
        elif self.path == "/v1/models":
            self._reply(HTTPStatus.OK, {"object": "list", "data": [{"id": self.server.name, "object": "model"}]})
        else:
            self._reply(HTTPStatus.NOT_FOUND, {"detail": "not found"})

    def do_POST(self) -> None:
        if self.path != DECIDE_PATH:
            self._reply(HTTPStatus.NOT_FOUND, {"detail": "not found"})
            return
        try:
            request = self._read_request()
        except ValueError as exc:
            self._reply(HTTPStatus.UNPROCESSABLE_ENTITY, {"detail": str(exc)})
            return
        try:
            response = self.server.decider.decide(request)
        except self.server.request_errors as exc:
            self._reply(HTTPStatus.UNPROCESSABLE_ENTITY, {"detail": str(exc)})
        except Exception:  # noqa: BLE001  reply 500 instead of silently dropping the connection, and log the cause
            traceback.print_exc()
            self._reply(HTTPStatus.INTERNAL_SERVER_ERROR, {"detail": "internal error"})
        else:
            self._reply(HTTPStatus.OK, response)

    def _read_request(self) -> dict[str, Any]:
        length = int(self.headers.get("Content-Length") or 0)
        if not 0 < length <= MAX_BODY_BYTES:
            raise ValueError(f"the body needs a Content-Length of 1 to {MAX_BODY_BYTES} bytes")
        request = json.loads(self.rfile.read(length))
        if not isinstance(request, dict):
            raise ValueError("the body must be a JSON object")
        request.pop("model", None)
        images = request.get("images", [])
        if not isinstance(images, list) or not all(
            isinstance(image, str) and image.startswith("data:image/") for image in images
        ):
            raise ValueError("images must be a list of base64 data URLs (data:image/...)")
        return request

    def _reply(self, status: HTTPStatus, body: Any) -> None:
        data = json.dumps(body, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--model", required=True, type=Path, help="checkpoint directory")
    ap.add_argument("--name", required=True, help="model name reported by /v1/models")
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--port", type=int, default=8000)
    args = ap.parse_args()

    sys.path.insert(0, str(args.model / "source" / "src"))
    from pplx_decider import Decider, LengthError, RequestError

    decider = Decider.from_pretrained(args.model, device="cuda")
    server = DecideServer((args.host, args.port), decider, args.name, (RequestError, LengthError))
    print(f"pplx-decider: {args.name} on http://{args.host}:{args.port}{DECIDE_PATH}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
