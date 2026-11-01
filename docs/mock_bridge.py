#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Bridge API v1 的**假服务端**，只用来在真翻译端写出来之前验证客户端与协议自洽。

它不是规范的一部分，也不实现任何真实的 OCR/翻译：
  - /v1/translate/image 按图片尺寸编出一组等距的假框，原文/译文都是占位串；
  - render=1 时用 PIL 在图上画出货真价实的 PNG，好让“取成品图”这条链路被真正走通。

用法：
    python docs/mock_bridge.py --port 8098 --token testtoken
    python docs/bridge_client.py --token testtoken health

它与 `docs/翻译互通-技术文档.md` §6 一一对应；如果发现 mock 与文档不一致，
以文档为准，并把这个 mock 改过来。
"""

from __future__ import annotations

import argparse
import io
import json
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

try:
    from PIL import Image, ImageDraw
except ImportError:  # pragma: no cover
    Image = None

MAX_BODY = 32 * 1024 * 1024
RENDER_TTL = 600.0
RENDER_SLOTS = 4
BUSY = threading.Lock()


class RenderCache:
    def __init__(self) -> None:
        self.items: dict[str, tuple[float, bytes]] = {}
        self.lock = threading.Lock()

    def put(self, data: bytes) -> str:
        rid = "r-" + uuid.uuid4().hex[:8]
        with self.lock:
            now = time.time()
            self.items = {k: v for k, v in self.items.items() if now - v[0] < RENDER_TTL}
            while len(self.items) >= RENDER_SLOTS:
                oldest = min(self.items, key=lambda k: self.items[k][0])
                del self.items[oldest]
            self.items[rid] = (now, data)
        return rid

    def get(self, rid: str) -> bytes | None:
        with self.lock:
            hit = self.items.get(rid)
            if hit is None or time.time() - hit[0] > RENDER_TTL:
                self.items.pop(rid, None)
                return None
            return hit[1]


CACHE = RenderCache()


def fake_lines(width: int, height: int, translate: bool) -> list[dict]:
    lines = []
    rows = 6
    for i in range(rows):
        top = int(height * (0.08 + 0.13 * i))
        left = int(width * 0.07)
        w = int(width * 0.55)
        h = max(12, int(height * 0.018))
        src = f"テスト行 {i + 1}: この先は立入禁止です"
        lines.append({
            "i": i,
            "box": [left, top, w, h],
            "source": src,
            "target": (f"测试第 {i + 1} 行：前面禁止入内" if translate else None),
            "conf": round(0.99 - 0.01 * i, 4),
            "ok": translate,
            "error": None if translate else "translate=0",
        })
    return lines


def render_png(raw: bytes, lines: list[dict], target: str) -> bytes | None:
    if Image is None:
        return None
    try:
        im = Image.open(io.BytesIO(raw)).convert("RGB")
    except Exception:
        return None
    draw = ImageDraw.Draw(im)
    for line in lines:
        x, y, w, h = line["box"]
        draw.rectangle([x, y, x + w, y + h], fill=(255, 255, 255))
        draw.text((x + 4, y + max(0, (h - 11) // 2)), line.get("target") or "", fill=(20, 20, 20))
    out = io.BytesIO()
    im.save(out, format="PNG")
    return out.getvalue()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    token = "testtoken"

    # ---------------------------------------------------------------- 工具
    def _send(self, status: int, body: bytes, ctype: str, extra: dict | None = None) -> None:
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("X-Bridge-Api", "1")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def _json(self, status: int, payload: dict, extra: dict | None = None) -> None:
        self._send(status, json.dumps(payload, ensure_ascii=False).encode("utf-8"),
                   "application/json; charset=utf-8", extra)

    def _err(self, status: int, code: str, message: str, extra: dict | None = None) -> None:
        self._json(status, {"api": 1, "ok": False, "code": code, "message": message}, extra)

    def _authed(self) -> bool:
        if self.headers.get("X-Bridge-Token", "") != self.token:
            self._err(401, "unauthorized", "口令不对")
            return False
        return True

    def log_message(self, fmt: str, *args) -> None:  # 安静一点
        print("  " + fmt % args)

    # ---------------------------------------------------------------- 路由
    def do_GET(self) -> None:
        path = urlparse(self.path).path
        if path == "/v1/health":
            self._json(200, {
                "api": 1, "ok": True, "app": "mock.bridge", "versionName": "mock",
                "versionCode": 0, "port": self.server.server_port, "busy": BUSY.locked(),
                "visionReady": True, "translateReady": True, "backend": "mock",
                "model": "none", "targetDefault": "zh", "needToken": True,
            })
            return
        if path.startswith("/v1/render/"):
            if not self._authed():
                return
            rid = path.rsplit("/", 1)[-1]
            data = CACHE.get(rid)
            if data is None:
                self._err(410, "render_gone", "渲染图已过期")
                return
            self._send(200, data, "image/png")
            return
        self._err(404, "not_found", f"没有 {path}")

    def do_POST(self) -> None:
        parsed = urlparse(self.path)
        path = parsed.path
        query = {k: v[0] for k, v in parse_qs(parsed.query).items()}

        length = self.headers.get("Content-Length")
        if length is None:
            self._err(411, "length_required", "必须带 Content-Length")
            return
        length = int(length)
        if length > MAX_BODY:
            self._err(413, "payload_too_large", "请求体太大")
            return
        body = self.rfile.read(length) if length else b""

        if path == "/v1/translate/text":
            if not self._authed():
                return
            try:
                req = json.loads(body.decode("utf-8"))
            except Exception:
                self._err(400, "bad_request", "body 不是合法 JSON")
                return
            text = str(req.get("text", ""))
            self._json(200, {"api": 1, "ok": True, "text": f"【译】{text}",
                             "targetLang": req.get("target", "zh"),
                             "elapsedMs": 3, "backend": "mock"})
            return

        if path != "/v1/translate/image":
            self._err(404, "not_found", f"没有 {path}")
            return
        if not self._authed():
            return

        ctype = self.headers.get("Content-Type", "")
        if not any(ctype.startswith(t) for t in ("image/png", "image/jpeg", "image/webp")):
            self._err(415, "unsupported_media", f"不支持的 {ctype}")
            return
        if Image is None:
            self._err(500, "internal", "mock 需要 Pillow")
            return
        try:
            im = Image.open(io.BytesIO(body))
            width, height = im.size
        except Exception as e:
            self._err(422, "decode_failed", f"解不开图片：{e}")
            return

        if not BUSY.acquire(blocking=False):
            self._err(409, "busy", "正在处理上一张图片", {"Retry-After": "1"})
            return
        try:
            t0 = time.time()
            if self.server.delay:
                time.sleep(self.server.delay)  # 只为复现 409：故意占着锁
            translate = query.get("translate", "1") == "1"
            lines = fake_lines(width, height, translate)
            payload = {
                "api": 1, "ok": True,
                "image": {"width": width, "height": height},
                "lines": lines,
                "elapsedMs": int((time.time() - t0) * 1000),
                "stats": {"blocks": len(lines), "translated": len(lines),
                          "failed": 0, "dropped": 0},
            }
            if query.get("render", "1") == "1":
                png = render_png(body, lines, query.get("target", "zh"))
                if png is not None:
                    rid = CACHE.put(png)
                    payload["render"] = {"id": rid, "mime": "image/png", "bytes": len(png)}
                else:
                    payload["render"] = None
            self._json(200, payload)
        finally:
            BUSY.release()


def main() -> None:
    p = argparse.ArgumentParser(description="Bridge v1 假服务端（仅供客户端自测）")
    p.add_argument("--port", type=int, default=8098)
    p.add_argument("--token", default="testtoken")
    p.add_argument("--delay", type=float, default=0.0,
                   help="每张图故意占用多少秒（用来复现 409 busy）")
    args = p.parse_args()
    Handler.token = args.token
    srv = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    srv.daemon_threads = True
    srv.delay = args.delay
    print(f"mock bridge 在 http://127.0.0.1:{args.port} 口令 {args.token}")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
