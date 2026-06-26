#!/usr/bin/env python3
"""Signed direct media preview server for DeepSea Restream VPS nodes.

This process serves files from configured roots only. The control panel signs
short-lived URLs; the browser then streams directly from the user's VPS.
"""

from __future__ import annotations

import argparse
import hashlib
import hmac
import html
import json
import mimetypes
import os
import time
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, quote, urlparse


CHUNK_SIZE = 1024 * 1024


def load_config(path: str) -> dict:
    with open(path, "r", encoding="utf-8") as fh:
        config = json.load(fh)
    roots = [os.path.realpath(root) for root in config.get("roots", []) if root]
    return {
        "secret": str(config.get("secret") or ""),
        "roots": roots,
        "script_hash": str(config.get("script_hash") or ""),
    }


def sign(secret: str, file_path: str, expires_at: str) -> str:
    payload = f"{file_path}\n{expires_at}".encode("utf-8")
    return hmac.new(secret.encode("utf-8"), payload, hashlib.sha256).hexdigest()


def guess_type(path: str) -> str:
    ext = Path(path).suffix.lower()
    if ext == ".ts":
        return "video/mp2t"
    if ext == ".mkv":
        return "video/x-matroska"
    if ext == ".mp4":
        return "video/mp4"
    if ext == ".webm":
        return "video/webm"
    value, _ = mimetypes.guess_type(path)
    return value or "application/octet-stream"


class PreviewHandler(BaseHTTPRequestHandler):
    server_version = "DeepSeaPreview/1.0"

    def log_message(self, fmt: str, *args) -> None:
        return

    @property
    def config_path(self) -> str:
        return self.server.config_path  # type: ignore[attr-defined]

    def send_text(self, status: int, text: str, content_type: str = "text/plain; charset=utf-8") -> None:
        body = text.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def parse_signed_path(self) -> tuple[str | None, str | None]:
        parsed = urlparse(self.path)
        query = parse_qs(parsed.query)
        raw_path = (query.get("path") or [""])[0]
        expires_at = (query.get("exp") or [""])[0]
        provided_sig = (query.get("sig") or [""])[0]
        if not raw_path or not expires_at or not provided_sig:
            return None, "missing signature"
        try:
            if int(expires_at) < int(time.time()):
                return None, "preview link expired"
        except ValueError:
            return None, "bad expiry"

        try:
            config = load_config(self.config_path)
        except Exception:
            return None, "preview service is not configured"
        expected = sign(config["secret"], raw_path, expires_at)
        if not hmac.compare_digest(expected, provided_sig):
            return None, "bad signature"

        real_path = os.path.realpath(raw_path)
        roots = config["roots"]
        if not any(real_path == root or real_path.startswith(root + os.sep) for root in roots):
            return None, "path is not allowed"
        if not os.path.isfile(real_path):
            return None, "file not found"
        return real_path, None

    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        if parsed.path == "/health":
            self.handle_health()
            return
        if parsed.path == "/player":
            self.handle_player()
            return
        if parsed.path == "/file":
            self.handle_file()
            return
        self.send_text(HTTPStatus.NOT_FOUND, "not found")

    def do_HEAD(self) -> None:
        parsed = urlparse(self.path)
        if parsed.path == "/file":
            self.handle_file()
            return
        if parsed.path == "/health":
            self.handle_health()
            return
        self.send_text(HTTPStatus.NOT_FOUND, "not found")

    def handle_health(self) -> None:
        try:
            config = load_config(self.config_path)
            script_hash = config.get("script_hash", "")
        except Exception:
            script_hash = ""
        self.send_text(
            HTTPStatus.OK,
            json.dumps({"ok": True, "script_hash": script_hash}, ensure_ascii=False),
            "application/json; charset=utf-8",
        )

    def handle_player(self) -> None:
        file_path, error = self.parse_signed_path()
        if error:
            self.send_text(HTTPStatus.FORBIDDEN, error)
            return
        parsed = urlparse(self.path)
        query = parse_qs(parsed.query)
        name = (query.get("name") or [os.path.basename(file_path or "")])[0]
        file_url = "/file?" + parsed.query
        escaped_name = html.escape(name or os.path.basename(file_path or ""))
        escaped_file_url = html.escape(file_url, quote=True)
        body = f"""<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>{escaped_name}</title>
  <style>
    body {{ margin: 0; background: #0f172a; color: #e5e7eb; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }}
    main {{ min-height: 100vh; display: grid; grid-template-rows: auto 1fr auto; }}
    header, footer {{ padding: 14px 18px; background: rgba(15,23,42,.86); }}
    h1 {{ margin: 0; font-size: 16px; font-weight: 650; overflow-wrap: anywhere; }}
    video {{ width: 100%; height: calc(100vh - 104px); background: #000; display: block; }}
    a {{ color: #5eead4; }}
  </style>
</head>
<body>
  <main>
    <header><h1>{escaped_name}</h1></header>
    <video controls autoplay src="{escaped_file_url}"></video>
    <footer>流量由当前 VPS 直接提供。若浏览器无法播放该编码，请下载后本地播放或重新生成 MP4 文件。</footer>
  </main>
</body>
</html>"""
        self.send_text(HTTPStatus.OK, body, "text/html; charset=utf-8")

    def handle_file(self) -> None:
        file_path, error = self.parse_signed_path()
        if error:
            self.send_text(HTTPStatus.FORBIDDEN, error)
            return
        parsed = urlparse(self.path)
        query = parse_qs(parsed.query)
        disposition = "attachment" if (query.get("download") or [""])[0] == "1" else "inline"

        size = os.path.getsize(file_path)
        start = 0
        end = size - 1
        status = HTTPStatus.OK
        range_header = self.headers.get("Range", "")
        if range_header.startswith("bytes="):
            raw_range = range_header[6:].split(",", 1)[0].strip()
            if "-" in raw_range:
                start_raw, end_raw = raw_range.split("-", 1)
                try:
                    if start_raw:
                        start = max(0, int(start_raw))
                    if end_raw:
                        end = min(size - 1, int(end_raw))
                    if start > end or start >= size:
                        self.send_response(HTTPStatus.REQUESTED_RANGE_NOT_SATISFIABLE)
                        self.send_header("Content-Range", f"bytes */{size}")
                        self.end_headers()
                        return
                    status = HTTPStatus.PARTIAL_CONTENT
                except ValueError:
                    pass

        content_length = max(0, end - start + 1)
        self.send_response(status)
        self.send_header("Content-Type", guess_type(file_path))
        self.send_header("Content-Length", str(content_length))
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Cache-Control", "private, max-age=300")
        self.send_header("Content-Disposition", f"{disposition}; filename*=UTF-8''{quote(os.path.basename(file_path))}")
        if status == HTTPStatus.PARTIAL_CONTENT:
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.end_headers()
        if self.command == "HEAD":
            return

        with open(file_path, "rb") as fh:
            fh.seek(start)
            remaining = content_length
            while remaining > 0:
                chunk = fh.read(min(CHUNK_SIZE, remaining))
                if not chunk:
                    break
                self.wfile.write(chunk)
                remaining -= len(chunk)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=18780)
    parser.add_argument("--config", default="/root/douyin2youtube/preview_config.json")
    args = parser.parse_args()

    server = ThreadingHTTPServer((args.host, args.port), PreviewHandler)
    server.config_path = args.config  # type: ignore[attr-defined]
    server.serve_forever()


if __name__ == "__main__":
    main()
