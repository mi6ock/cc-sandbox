#!/usr/bin/env python3
"""
local-agent.py — ローカルコマンド実行エージェント
git/gh コマンドをTCP経由で受信し、ローカルで実行して結果を返す。
"""

import argparse
import json
import struct
import socket
import subprocess
import shutil
import base64
import threading
import signal
import sys
import os
from datetime import datetime

ALLOWED_COMMANDS = {"git", "gh"}

# コマンドのフルパスを解決（起動時に一度だけ）
# バックグラウンドプロセスやサンドボックスでPATHが制限される場合に備え、
# 一般的なパスも含めて検索する
EXTRA_PATHS = [
    "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
    os.path.expanduser("~/.local/bin"),
]

def resolve_command(cmd: str) -> str | None:
    """コマンドのフルパスを解決する"""
    # まず通常のPATHで検索
    path = shutil.which(cmd)
    if path:
        return path
    # 見つからなければ追加パスで検索
    for d in EXTRA_PATHS:
        candidate = os.path.join(d, cmd)
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    return None

# 起動時にコマンドパスをキャッシュ
COMMAND_PATHS: dict[str, str] = {}
for _cmd in ALLOWED_COMMANDS:
    _path = resolve_command(_cmd)
    if _path:
        COMMAND_PATHS[_cmd] = _path

def log(msg: str):
    ts = datetime.now().strftime("%H:%M:%S")
    print(f"[{ts}] {msg}", file=sys.stderr, flush=True)

def read_message(sock: socket.socket) -> dict:
    raw_len = _recv_exact(sock, 4)
    if not raw_len:
        return {}
    msg_len = struct.unpack(">I", raw_len)[0]
    if msg_len > 10 * 1024 * 1024:
        raise ValueError(f"メッセージが大きすぎます: {msg_len}")
    raw_msg = _recv_exact(sock, msg_len)
    return json.loads(raw_msg.decode("utf-8"))

def _recv_exact(sock: socket.socket, n: int) -> bytes:
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            return b""
        buf += chunk
    return buf

def send_message(sock: socket.socket, data: dict):
    payload = json.dumps(data).encode("utf-8")
    sock.sendall(struct.pack(">I", len(payload)) + payload)

def handle_client(conn: socket.socket, addr, path_map: dict, token: str | None):
    try:
        req = read_message(conn)
        if not req:
            return

        if token and req.get("token") != token:
            send_message(conn, {"exit_code": 1, "stdout": "", "stderr": base64.b64encode(b"auth failed").decode()})
            log(f"認証失敗: {addr}")
            return

        cmd = req.get("cmd", "")
        args = req.get("args", [])
        cwd = req.get("cwd", os.getcwd())

        if cmd not in ALLOWED_COMMANDS:
            send_message(conn, {
                "exit_code": 1,
                "stdout": "",
                "stderr": base64.b64encode(f"許可されていないコマンド: {cmd}".encode()).decode()
            })
            log(f"拒否: {cmd} (許可: {', '.join(ALLOWED_COMMANDS)})")
            return

        for remote_prefix, local_prefix in path_map.items():
            if cwd.startswith(remote_prefix):
                cwd = cwd.replace(remote_prefix, local_prefix, 1)
                break

        # cwdが存在しない場合（パスマッピング外のリモートパス）はホームにフォールバック
        if not os.path.isdir(cwd):
            fallback_cwd = os.path.expanduser("~")
            log(f"cwdが存在しません: {cwd} → フォールバック: {fallback_cwd}")
            cwd = fallback_cwd

        log(f"実行: {cmd} {' '.join(args)} (cwd: {cwd})")

        # キャッシュ済みのフルパスを使用
        cmd_path = COMMAND_PATHS.get(cmd)
        if not cmd_path:
            send_message(conn, {
                "exit_code": 127,
                "stdout": "",
                "stderr": base64.b64encode(f"{cmd}: command not found in PATH".encode()).decode(),
            })
            log(f"コマンド未検出（PATH解決失敗）: {cmd}")
            return

        try:
            result = subprocess.run(
                [cmd_path] + args,
                capture_output=True,
                cwd=cwd,
                timeout=120,
            )
            send_message(conn, {
                "exit_code": result.returncode,
                "stdout": base64.b64encode(result.stdout).decode(),
                "stderr": base64.b64encode(result.stderr).decode(),
            })
            log(f"完了: exit={result.returncode}")
        except subprocess.TimeoutExpired:
            send_message(conn, {
                "exit_code": 124,
                "stdout": "",
                "stderr": base64.b64encode(b"timeout (120s)").decode(),
            })
            log("タイムアウト")
        except FileNotFoundError:
            send_message(conn, {
                "exit_code": 127,
                "stdout": "",
                "stderr": base64.b64encode(f"{cmd}: command not found".encode()).decode(),
            })
            log(f"コマンド未検出: {cmd}")

    except Exception as e:
        log(f"エラー: {e}")
        try:
            send_message(conn, {
                "exit_code": 1,
                "stdout": "",
                "stderr": base64.b64encode(str(e).encode()).decode(),
            })
        except Exception:
            pass
    finally:
        conn.close()

def main():
    parser = argparse.ArgumentParser(description="ローカルコマンド実行エージェント")
    parser.add_argument("--port", type=int, default=9999, help="待受ポート (default: 9999)")
    parser.add_argument("--path-map", action="append", default=[], help="パスマッピング remote:local (複数指定可)")
    parser.add_argument("--token", default=None, help="認証トークン")
    args = parser.parse_args()

    path_map = {}
    for pm in args.path_map:
        parts = pm.split(":", 1)
        if len(parts) == 2:
            path_map[parts[0]] = parts[1]

    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)

    def shutdown(sig, frame):
        log("シャットダウン...")
        server.close()
        sys.exit(0)

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)

    server.bind(("127.0.0.1", args.port))
    server.listen(5)
    log(f"エージェント起動: port={args.port}, 許可コマンド={ALLOWED_COMMANDS}")
    for c, p in COMMAND_PATHS.items():
        log(f"  コマンドパス: {c} → {p}")
    if path_map:
        for r, l in path_map.items():
            log(f"  パスマップ: {r} → {l}")
    if args.token:
        log("  トークン認証: 有効")

    while True:
        try:
            conn, addr = server.accept()
            t = threading.Thread(target=handle_client, args=(conn, addr, path_map, args.token), daemon=True)
            t.start()
        except OSError:
            break

if __name__ == "__main__":
    main()
