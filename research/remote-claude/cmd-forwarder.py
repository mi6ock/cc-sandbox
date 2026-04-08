#!/usr/bin/env python3
"""
cmd-forwarder.py — リモート側コマンド転送
git/ghコマンドをローカルエージェントに転送し、結果を返す。

Usage:
    cmd-forwarder.py <command> [args...]
    e.g., cmd-forwarder.py git status
"""

import sys
import os
import socket
import struct
import json
import base64

def main():
    if len(sys.argv) < 2:
        print("Usage: cmd-forwarder.py <command> [args...]", file=sys.stderr)
        sys.exit(1)

    cmd = sys.argv[1]
    args = sys.argv[2:]
    cwd = os.getcwd()
    port = int(os.environ.get("COMMAND_AGENT_PORT", "9999"))
    token = os.environ.get("COMMAND_AGENT_TOKEN", "")

    req = {"cmd": cmd, "args": args, "cwd": cwd}
    if token:
        req["token"] = token

    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(130)
        sock.connect(("127.0.0.1", port))

        # 送信
        payload = json.dumps(req).encode("utf-8")
        sock.sendall(struct.pack(">I", len(payload)) + payload)

        # 受信
        raw_len = b""
        while len(raw_len) < 4:
            chunk = sock.recv(4 - len(raw_len))
            if not chunk:
                print("エージェントからの応答なし", file=sys.stderr)
                sys.exit(1)
            raw_len += chunk

        msg_len = struct.unpack(">I", raw_len)[0]
        raw_msg = b""
        while len(raw_msg) < msg_len:
            chunk = sock.recv(msg_len - len(raw_msg))
            if not chunk:
                break
            raw_msg += chunk

        resp = json.loads(raw_msg.decode("utf-8"))
        sock.close()

        if resp.get("stdout"):
            sys.stdout.buffer.write(base64.b64decode(resp["stdout"]))
            sys.stdout.buffer.flush()
        if resp.get("stderr"):
            sys.stderr.buffer.write(base64.b64decode(resp["stderr"]))
            sys.stderr.buffer.flush()

        sys.exit(resp.get("exit_code", 1))

    except ConnectionRefusedError:
        print(f"ローカルエージェントに接続できません (port {port})", file=sys.stderr)
        print("remote-claudeセッション外でgitを使う場合は /usr/bin/git を直接使ってください", file=sys.stderr)
        sys.exit(1)
    except socket.timeout:
        print("ローカルエージェントからの応答タイムアウト", file=sys.stderr)
        sys.exit(124)
    except Exception as e:
        print(f"転送エラー: {e}", file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__":
    main()
