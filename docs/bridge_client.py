#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""本机翻译服务（Bridge API v1）调试客户端。

用途：在**不写任何 App 代码**的前提下验证翻译端是否符合
`docs/翻译互通-技术文档.md` 的契约。手机上跑着翻译 App 时，电脑执行

    adb forward tcp:8098 tcp:8098
    python docs/bridge_client.py health
    python docs/bridge_client.py text "こんにちは"
    python docs/bridge_client.py image --file shot.png --draw --out ./out

没有手机也能自测：先起 `docs/mock_bridge.py`（同目录的假服务端，同一份契约）。

只有标准库依赖；`--draw` 需要 Pillow（可选）。

约定（与文档一致）：
  - 除 health 外都要 X-Bridge-Token
  - 图片走原始字节，不做 base64
  - 渲染图分两步：先 POST 拿 render.id，再 GET /v1/render/{id}
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

API = 1
DEFAULT_BASE = "http://127.0.0.1:8098"
IMAGE_TYPES = {
    ".png": "image/png",
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
    ".webp": "image/webp",
    ".bmp": "image/bmp",
    ".gif": "image/gif",
}


# --------------------------------------------------------------------- HTTP

class BridgeError(Exception):
    def __init__(self, status: int, code: str, message: str, body: bytes = b"",
                 retry_after: float = 1.0):
        super().__init__(f"HTTP {status} {code}: {message}")
        self.status = status
        self.code = code
        self.message = message
        self.body = body
        self.retry_after = retry_after


def _request(base: str, path: str, *, method: str = "GET", token: str = "",
             data: bytes | None = None, content_type: str | None = None,
             timeout: float = 180.0) -> tuple[int, dict[str, str], bytes]:
    url = base.rstrip("/") + path
    req = urllib.request.Request(url, data=data, method=method)
    if content_type:
        req.add_header("Content-Type", content_type)
    if token:
        req.add_header("X-Bridge-Token", token)
    req.add_header("Accept", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, dict(resp.headers), resp.read()
    except urllib.error.HTTPError as e:
        return e.code, dict(e.headers), e.read()
    except urllib.error.URLError as e:
        raise SystemExit(
            f"连不上 {url}：{e.reason}\n"
            "  排查：1) 翻译 App 是否在跑 2) adb forward tcp:8098 tcp:8098 3) 端口是否被改（看 health.port）"
        ) from e


def _json_or_error(status: int, headers: dict[str, str], body: bytes) -> dict:
    ctype = headers.get("Content-Type", "")
    if "json" not in ctype:
        raise BridgeError(status, "non_json", body[:200].decode("utf-8", "replace"), body)
    payload = json.loads(body.decode("utf-8"))
    if status != 200 or payload.get("ok") is not True:
        try:
            retry_after = float(headers.get("Retry-After", "1"))
        except ValueError:
            retry_after = 1.0
        raise BridgeError(status, payload.get("code", "?"), payload.get("message", ""),
                          body, retry_after)
    return payload


def _with_busy_retry(call, attempts: int = 3):
    """409 busy 是常态（翻译端一次只跑一张图），按 Retry-After 退避重试，文档 §6.6。"""
    for i in range(attempts):
        try:
            return call()
        except BridgeError as e:
            if e.status != 409 or i == attempts - 1:
                raise
            wait = max(0.2, min(e.retry_after, 10.0))
            print(f"⏳ 翻译端忙，{wait:g}s 后重试（{i + 1}/{attempts - 1}）", file=sys.stderr)
            time.sleep(wait)


# --------------------------------------------------------------------- 命令

def cmd_health(args) -> int:
    status, headers, body = _request(args.base, "/v1/health", timeout=10)
    payload = json.loads(body.decode("utf-8"))
    print(json.dumps(payload, ensure_ascii=False, indent=2))
    if not payload.get("ok"):
        return 1
    for key in ("visionReady", "translateReady"):
        if payload.get(key) is False:
            print(f"⚠️  {key} = false：翻译端还没准备好，先去看它的设置页", file=sys.stderr)
    return 0


def cmd_text(args) -> int:
    text = args.text_opt or args.text
    if not text:
        raise SystemExit("要么给位置参数，要么给 --text")
    body = json.dumps(
        {"text": text, "source": args.source, "target": args.target},
        ensure_ascii=False,
    ).encode("utf-8")
    def send() -> dict:
        status, headers, raw = _request(
            args.base, "/v1/translate/text", method="POST", token=args.token,
            data=body, content_type="application/json; charset=utf-8",
        )
        return _json_or_error(status, headers, raw)

    payload = _with_busy_retry(send)
    print(payload.get("text", ""))
    if args.json:
        print(json.dumps(payload, ensure_ascii=False, indent=2), file=sys.stderr)
    return 0


def _translate_image(args, image_path: Path, out_dir: Path | None, stem: str | None = None) -> dict:
    """发一次 /v1/translate/image；给了 out_dir 就把 json/成品图落到那里。"""
    data = image_path.read_bytes()
    mime = IMAGE_TYPES.get(image_path.suffix.lower(), "image/png")
    qs = [
        f"target={args.target}",
        f"source={args.source}",
        "render=1" if args.render else "render=0",
        f"minChars={args.min_chars}",
    ]
    if args.max_side:
        qs.append(f"maxSide={args.max_side}")
    def send() -> dict:
        status, headers, raw = _request(
            args.base, "/v1/translate/image?" + "&".join(qs), method="POST",
            token=args.token, data=data, content_type=mime,
        )
        return _json_or_error(status, headers, raw)

    payload = _with_busy_retry(send)
    img = payload.get("image") or {}
    print(f"图片 {img.get('width')}x{img.get('height')}  "
          f"块 {len(payload.get('lines', []))}  "
          f"耗时 {payload.get('elapsedMs')}ms", file=sys.stderr)

    if out_dir is None:
        return payload

    out_dir.mkdir(parents=True, exist_ok=True)
    stem = stem or image_path.stem
    (out_dir / f"{stem}.json").write_text(
        json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")

    render = payload.get("render")
    if render:
        status2, headers2, img_bytes = _request(
            args.base, f"/v1/render/{render['id']}", token=args.token, timeout=60)
        if status2 != 200:
            print(f"⚠️  取渲染图失败 HTTP {status2}", file=sys.stderr)
        else:
            ctype = headers2.get("Content-Type", "image/png")
            ext = ".png" if "png" in ctype else (".jpg" if "jpeg" in ctype else ".bin")
            (out_dir / f"{stem}{ext}").write_bytes(img_bytes)
            print(f"成品图 {out_dir / f'{stem}{ext}'} ({len(img_bytes)} B)", file=sys.stderr)
    return payload


def _draw(image_path: Path, payload: dict, out_dir: Path) -> Path | None:
    try:
        from PIL import Image, ImageDraw
    except ImportError:
        print("⚠️  没装 Pillow，跳过 --draw（pip install pillow）", file=sys.stderr)
        return None
    im = Image.open(image_path).convert("RGB")
    draw = ImageDraw.Draw(im)
    for line in payload.get("lines", []):
        box = line.get("box")
        if not box or len(box) != 4:
            continue
        x, y, w, h = box
        color = (0, 200, 0) if line.get("ok") else (220, 0, 0)
        draw.rectangle([x, y, x + w, y + h], outline=color, width=3)
        draw.text((x + 2, max(0, y - 14)), str(line.get("i", "?")), fill=color)
    target = out_dir / f"{image_path.stem}.boxes.png"
    im.save(target)
    print(f"标注图 {target}", file=sys.stderr)
    return target


def cmd_image(args) -> int:
    path = Path(args.file)
    if not path.is_file():
        raise SystemExit(f"文件不存在：{path}")
    out_dir = Path(args.out) if args.out else None
    payload = _translate_image(args, path, out_dir)
    if args.draw:
        _draw(path, payload, out_dir or Path("."))
    if out_dir is None:
        print(json.dumps(payload, ensure_ascii=False, indent=2))
    return 0


def cmd_batch(args) -> int:
    src = Path(args.dir)
    if not src.is_dir():
        raise SystemExit(f"目录不存在：{src}")
    exts = {".png", ".jpg", ".jpeg", ".webp", ".bmp", ".gif"}
    pages = sorted(p for p in src.iterdir() if p.suffix.lower() in exts)
    if not pages:
        raise SystemExit(f"{src} 里没有图片")
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    event_file = out / "event.json"
    event = {
        "schema": 1,
        "eventId": event_file.parent.name,
        "galleryTitle": args.dir,
        "target": args.target,
        "sourceLang": args.source,
        "state": "running",
        "total": len(pages),
        "done": 0,
        "failed": 0,
        "pages": [],
    }
    if event_file.is_file():
        event.update(json.loads(event_file.read_text(encoding="utf-8")))

    started = time.time()
    for idx, page in enumerate(pages):
        stem = f"page-{idx + 1:04d}"
        entry = {"index": idx, "name": page.name, "state": "pending"}
        try:
            t0 = time.time()
            payload = _translate_image(args, page, out, stem=stem)
            entry.update(
                state="done",
                json=f"{stem}.json",
                image=f"{stem}.png" if payload.get("render") else None,
                lines=len(payload.get("lines", [])),
                elapsedMs=int((time.time() - t0) * 1000),
            )
            event["done"] += 1
        except BridgeError as e:
            entry.update(state="failed", error=f"{e.code}: {e.message}")
            event["failed"] += 1
            print(f"✗ [{idx + 1}/{len(pages)}] {page.name} → {e}", file=sys.stderr)
        event["pages"].append(entry)
        event_file.write_text(json.dumps(event, ensure_ascii=False, indent=2), encoding="utf-8")
        print(f"✓ [{idx + 1}/{len(pages)}] {page.name}", file=sys.stderr)

    event["state"] = "completed"
    event["elapsedMs"] = int((time.time() - started) * 1000)
    event_file.write_text(json.dumps(event, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"完成：{event['done']}/{event['total']}，失败 {event['failed']}，"
          f"耗时 {event['elapsedMs'] / 1000:.1f}s → {out}")
    return 0 if event["failed"] == 0 else 2


# --------------------------------------------------------------------- 入口

def main() -> int:
    env_token = os.environ.get("BRIDGE_TOKEN", "")
    p = argparse.ArgumentParser(description="Bridge API v1 调试客户端")
    p.add_argument("--base", default=os.environ.get("BRIDGE_BASE", DEFAULT_BASE))
    p.add_argument("--token", default=env_token, help="配对口令（也可用 BRIDGE_TOKEN 环境变量）")
    sub = p.add_subparsers(dest="cmd", required=True)

    sub.add_parser("health", help="探测服务").set_defaults(func=cmd_health)

    t = sub.add_parser("text", help="翻译一段文本")
    t.add_argument("text", nargs="?", help="要翻译的文本（位置参数）")
    t.add_argument("--text", dest="text_opt", help="同上，用参数形式给")
    t.add_argument("--source", default="auto")
    t.add_argument("--target", default="zh")
    t.add_argument("--json", action="store_true")
    t.set_defaults(func=cmd_text)

    def add_image_args(sp):
        sp.add_argument("--target", default="zh")
        sp.add_argument("--source", default="auto")
        sp.add_argument("--render", dest="render", action="store_true", default=True)
        sp.add_argument("--no-render", dest="render", action="store_false")
        sp.add_argument("--min-chars", type=int, default=0, dest="min_chars")
        sp.add_argument("--max-side", type=int, default=0, dest="max_side")

    i = sub.add_parser("image", help="翻译单张图片")
    i.add_argument("--file", required=True)
    i.add_argument("--out", help="输出目录（给了就存 json/png）")
    i.add_argument("--draw", action="store_true", help="把 box 画回原图（需 Pillow）")
    add_image_args(i)
    i.set_defaults(func=cmd_image)

    b = sub.add_parser("batch", help="翻译整个目录（模拟图集端批量）")
    b.add_argument("--dir", required=True)
    b.add_argument("--out", required=True)
    add_image_args(b)
    b.set_defaults(func=cmd_batch)

    args = p.parse_args()
    if args.cmd != "health" and not args.token:
        print("提示：没给 --token，服务端会回 401（除 health 外都要口令）", file=sys.stderr)
    try:
        return args.func(args)
    except BridgeError as e:
        print(f"✗ {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
