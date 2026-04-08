# remote-claude Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** ローカルから `remote-claude` コマンド一発でリモートClaudeセッションに接続し、ファイル同期+git/ghコマンドのローカル転送を透過的に行うシステムを構築する。

**Architecture:** ローカルでTCPコマンドエージェント（git/ghのみ許可）を起動し、SSH逆トンネルでリモートに公開。リモート側ではgit/ghラッパーがこのトンネル経由でローカルに転送。mutagenで.git除外の双方向ファイル同期。ユーザーはリモートtmux内のClaudeセッションに直接入り、普通に操作する。

**Tech Stack:** Python 3（標準ライブラリのみ）, Bash, mutagen, tmux, SSH reverse tunnel

**Installation directory:** `~/.claude/skills/remote-claude/`

---

## File Structure

| ファイル | 責務 |
|---------|------|
| `remote-claude.sh` | メインエントリポイント。start/stop/statusサブコマンド。全体オーケストレーション |
| `local-agent.py` | ローカル側TCPサーバー。git/ghコマンドを受信・実行・結果返却 |
| `remote-setup.sh` | リモートにgit/ghラッパーをデプロイするワンタイムセットアップ |
| `cmd-forwarder.py` | リモートにデプロイされるコマンド転送スクリプト。git/ghラッパーから呼ばれる |
| `config.json` | 接続先・ポート・除外パターン等の設定 |
| `SKILL.md` | スキル定義ドキュメント |

### プロトコル仕様（local-agent ↔ cmd-forwarder）

```
[4 bytes: メッセージ長 (big-endian uint32)][JSON bytes]
```

Request:
```json
{"cmd": "git", "args": ["commit", "-m", "msg"], "cwd": "/home/exedev/remote-claude/proj", "token": "abc123"}
```

Response:
```json
{"exit_code": 0, "stdout": "<base64>", "stderr": "<base64>"}
```

---

### Task 1: local-agent.py — ローカルコマンドエージェント

**Files:**
- Create: `~/.claude/skills/remote-claude/local-agent.py`

- [ ] **Step 1: テスト用のechoサーバーで基本構造を作成**

`local-agent.py` を作成。引数解析とTCPサーバーの骨格:

```python
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
import base64
import threading
import signal
import sys
import os
from datetime import datetime

ALLOWED_COMMANDS = {"git", "gh"}

def log(msg: str):
    ts = datetime.now().strftime("%H:%M:%S")
    print(f"[{ts}] {msg}", file=sys.stderr, flush=True)

def read_message(sock: socket.socket) -> dict:
    """長さプレフィクス付きJSONを読み取る"""
    raw_len = _recv_exact(sock, 4)
    if not raw_len:
        return {}
    msg_len = struct.unpack(">I", raw_len)[0]
    if msg_len > 10 * 1024 * 1024:  # 10MB上限
        raise ValueError(f"メッセージが大きすぎます: {msg_len}")
    raw_msg = _recv_exact(sock, msg_len)
    return json.loads(raw_msg.decode("utf-8"))

def _recv_exact(sock: socket.socket, n: int) -> bytes:
    """正確にnバイト受信する"""
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            return b""
        buf += chunk
    return buf

def send_message(sock: socket.socket, data: dict):
    """長さプレフィクス付きJSONを送信する"""
    payload = json.dumps(data).encode("utf-8")
    sock.sendall(struct.pack(">I", len(payload)) + payload)

def handle_client(conn: socket.socket, addr, path_map: dict, token: str | None):
    """クライアント接続を処理する"""
    try:
        req = read_message(conn)
        if not req:
            return

        # トークン認証
        if token and req.get("token") != token:
            send_message(conn, {"exit_code": 1, "stdout": "", "stderr": base64.b64encode(b"auth failed").decode()})
            log(f"認証失敗: {addr}")
            return

        cmd = req.get("cmd", "")
        args = req.get("args", [])
        cwd = req.get("cwd", os.getcwd())

        # コマンドホワイトリスト
        if cmd not in ALLOWED_COMMANDS:
            send_message(conn, {
                "exit_code": 1,
                "stdout": "",
                "stderr": base64.b64encode(f"許可されていないコマンド: {cmd}".encode()).decode()
            })
            log(f"拒否: {cmd} (許可: {', '.join(ALLOWED_COMMANDS)})")
            return

        # パスマッピング
        for remote_prefix, local_prefix in path_map.items():
            if cwd.startswith(remote_prefix):
                cwd = cwd.replace(remote_prefix, local_prefix, 1)
                break

        log(f"実行: {cmd} {' '.join(args)} (cwd: {cwd})")

        try:
            result = subprocess.run(
                [cmd] + args,
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

    # パスマッピング解析
    path_map = {}
    for pm in args.path_map:
        parts = pm.split(":", 1)
        if len(parts) == 2:
            path_map[parts[0]] = parts[1]

    # シグナルハンドラ
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
```

- [ ] **Step 2: ローカルで起動テスト**

Run: `python3 ~/.claude/skills/remote-claude/local-agent.py --port 9999 &`

Expected: `[HH:MM:SS] エージェント起動: port=9999, 許可コマンド={'git', 'gh'}` が表示される

テスト用Pythonワンライナーで接続テスト:
```bash
python3 -c "
import socket, struct, json, base64
s = socket.socket(); s.connect(('127.0.0.1', 9999))
req = json.dumps({'cmd':'git','args':['--version'],'cwd':'.'}).encode()
s.sendall(struct.pack('>I', len(req)) + req)
raw_len = s.recv(4); msg_len = struct.unpack('>I', raw_len)[0]
resp = json.loads(s.recv(msg_len))
print(base64.b64decode(resp['stdout']).decode())
print('exit:', resp['exit_code'])
s.close()
"
```

Expected: `git version X.Y.Z` と `exit: 0` が表示される

- [ ] **Step 3: 不許可コマンドの拒否テスト**

```bash
python3 -c "
import socket, struct, json, base64
s = socket.socket(); s.connect(('127.0.0.1', 9999))
req = json.dumps({'cmd':'rm','args':['-rf','/'],'cwd':'.'}).encode()
s.sendall(struct.pack('>I', len(req)) + req)
raw_len = s.recv(4); msg_len = struct.unpack('>I', raw_len)[0]
resp = json.loads(s.recv(msg_len))
print(base64.b64decode(resp['stderr']).decode())
print('exit:', resp['exit_code'])
s.close()
"
```

Expected: `許可されていないコマンド: rm` と `exit: 1`

- [ ] **Step 4: エージェントを停止してコミット**

```bash
kill %1  # バックグラウンドジョブ停止
cd ~/.claude/skills/remote-claude
git add local-agent.py
git commit -m "feat: add local-agent.py — TCP command execution agent for git/gh"
```

---

### Task 2: cmd-forwarder.py — リモート側コマンド転送スクリプト

**Files:**
- Create: `~/.claude/skills/remote-claude/cmd-forwarder.py`

- [ ] **Step 1: cmd-forwarder.pyを作成**

リモートにデプロイされ、git/ghラッパーから呼ばれるスクリプト:

```python
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
        sock.settimeout(130)  # agent側の120sタイムアウト + マージン
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

        # stdout/stderrをデコードして出力
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
```

- [ ] **Step 2: local-agentとの結合テスト（ローカルで）**

```bash
# エージェント起動
python3 ~/.claude/skills/remote-claude/local-agent.py --port 9999 &

# フォワーダーテスト
python3 ~/.claude/skills/remote-claude/cmd-forwarder.py git --version

# ghテスト
python3 ~/.claude/skills/remote-claude/cmd-forwarder.py gh --version
```

Expected: 各コマンドのバージョンが表示される

- [ ] **Step 3: 不許可コマンドテスト**

```bash
python3 ~/.claude/skills/remote-claude/cmd-forwarder.py ls -la
```

Expected: `許可されていないコマンド: ls` が stderr に出力、exit code 1

- [ ] **Step 4: エージェント停止してコミット**

```bash
kill %1
git add cmd-forwarder.py
git commit -m "feat: add cmd-forwarder.py — remote-side command forwarding to local agent"
```

---

### Task 3: remote-setup.sh — リモートへのデプロイスクリプト

**Files:**
- Create: `~/.claude/skills/remote-claude/remote-setup.sh`

- [ ] **Step 1: remote-setup.shを作成**

```bash
#!/bin/bash
#
# remote-setup.sh — リモートにgit/ghラッパーをデプロイ
#
# Usage: bash remote-setup.sh <ssh_host>
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SSH_HOST="${1:?Usage: remote-setup.sh <ssh_host>}"

log() { echo "[$(date +%H:%M:%S)] $*"; }

log "リモートセットアップ開始: $SSH_HOST"

# 1. python3チェック
log "python3 チェック..."
if ! ssh "$SSH_HOST" "which python3 >/dev/null 2>&1"; then
    echo "ERROR: リモートに python3 がありません" >&2
    exit 1
fi

# 2. ディレクトリ作成
log "ディレクトリ作成..."
ssh "$SSH_HOST" "mkdir -p ~/bin"

# 3. cmd-forwarder.py デプロイ
log "cmd-forwarder.py デプロイ..."
scp "$SCRIPT_DIR/cmd-forwarder.py" "$SSH_HOST:~/bin/cmd-forwarder.py"
ssh "$SSH_HOST" "chmod +x ~/bin/cmd-forwarder.py"

# 4. git/gh ラッパー作成
log "git/gh ラッパー作成..."
ssh "$SSH_HOST" 'cat > ~/bin/git << '"'"'WRAPPER'"'"'
#!/bin/bash
exec python3 ~/bin/cmd-forwarder.py git "$@"
WRAPPER
chmod +x ~/bin/git'

ssh "$SSH_HOST" 'cat > ~/bin/gh << '"'"'WRAPPER'"'"'
#!/bin/bash
exec python3 ~/bin/cmd-forwarder.py gh "$@"
WRAPPER
chmod +x ~/bin/gh'

# 5. PATHに~/binを追加（未設定の場合）
log "PATH設定..."
ssh "$SSH_HOST" '
if ! grep -q "export PATH=\"\$HOME/bin:\$PATH\"" ~/.bashrc 2>/dev/null; then
    echo "" >> ~/.bashrc
    echo "# remote-claude: git/gh forwarding" >> ~/.bashrc
    echo "export PATH=\"\$HOME/bin:\$PATH\"" >> ~/.bashrc
    echo "追加: ~/bin をPATHに追加しました"
else
    echo "スキップ: ~/bin は既にPATHに含まれています"
fi'

# 6. 確認
log "デプロイ確認..."
ssh "$SSH_HOST" 'echo "PATH確認:"; which git; which gh; echo "---"; cat ~/bin/git'

log "セットアップ完了!"
log ""
log "注意: git/ghラッパーは remote-claude セッション中（ローカルエージェント起動中）のみ動作します。"
log "セッション外でgitを使うには /usr/bin/git を直接指定してください。"
```

- [ ] **Step 2: リモートにデプロイテスト**

```bash
bash ~/.claude/skills/remote-claude/remote-setup.sh salmon-river-kose.exe.xyz
```

Expected: デプロイ成功メッセージ、`which git` が `~/bin/git` を返す

- [ ] **Step 3: コミット**

```bash
git add remote-setup.sh
git commit -m "feat: add remote-setup.sh — deploy git/gh wrappers to remote"
```

---

### Task 4: remote-claude.sh — メインエントリポイント

**Files:**
- Create（上書き）: `~/.claude/skills/remote-claude/remote-claude.sh`
- Create: `~/.claude/skills/remote-claude/config.json`

- [ ] **Step 1: config.jsonのデフォルトを作成**

```json
{
  "default_host": "",
  "agent_port": 9999,
  "remote_base_dir": "~/remote-claude",
  "exclude_patterns": ["build/", ".dart_tool/", "node_modules/", ".gradle/", ".build/", "Pods/"]
}
```

- [ ] **Step 2: remote-claude.shを書き直す**

```bash
#!/bin/bash
#
# remote-claude — リモートClaudeセッションの透過的な起動
#
# Usage:
#   remote-claude [ssh_host] [local_path]
#   remote-claude stop [local_path]
#   remote-claude status
#   remote-claude setup <ssh_host>
#
# ssh_host省略時はconfig.jsonのdefault_hostを使用。
# local_path省略時はカレントディレクトリ。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.json"
PID_FILE="/tmp/remote-claude-agent.pid"
TOKEN_FILE="/tmp/remote-claude-token"
TMUX_SESSION="claude"

# ============================================================
# ユーティリティ
# ============================================================

log() { echo "[$(date +%H:%M:%S)] $*"; }
err() { echo "[$(date +%H:%M:%S)] ERROR: $*" >&2; }

read_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        cat > "$CONFIG_FILE" << 'DEFAULTCONFIG'
{
  "default_host": "",
  "agent_port": 9999,
  "remote_base_dir": "~/remote-claude",
  "exclude_patterns": ["build/", ".dart_tool/", "node_modules/", ".gradle/", ".build/", "Pods/"]
}
DEFAULTCONFIG
    fi
    # python3でJSON読み取り
    AGENT_PORT=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE')).get('agent_port', 9999))")
    REMOTE_BASE=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE')).get('remote_base_dir', '~/remote-claude'))")
    DEFAULT_HOST=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE')).get('default_host', ''))")
    EXCLUDES=$(python3 -c "
import json
patterns = json.load(open('$CONFIG_FILE')).get('exclude_patterns', [])
for p in patterns:
    print(p)
")
}

generate_token() {
    python3 -c "import secrets; print(secrets.token_hex(16))"
}

# ============================================================
# start — メインコマンド
# ============================================================

cmd_start() {
    local host="${1:-$DEFAULT_HOST}"
    local local_path="${2:-$(pwd)}"

    if [ -z "$host" ]; then
        err "ssh_hostを指定するか、config.jsonのdefault_hostを設定してください"
        exit 1
    fi

    local project_name
    project_name=$(basename "$local_path")
    local remote_path="${REMOTE_BASE}/${project_name}"
    local sync_name="remote-claude-${project_name}"
    local token
    token=$(generate_token)

    log "=== remote-claude 起動 ==="
    log "Host: $host"
    log "Local: $local_path"
    log "Remote: $remote_path"

    # --- 1. SSH接続テスト ---
    log "SSH接続テスト..."
    if ! ssh -o ConnectTimeout=5 "$host" "echo ok" >/dev/null 2>&1; then
        err "SSH接続失敗: $host"
        exit 1
    fi

    # --- 2. ローカルエージェント起動 ---
    if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        log "ローカルエージェント: 既に起動中 (PID $(cat "$PID_FILE"))"
    else
        log "ローカルエージェント起動..."
        local path_map_arg="${remote_path}:${local_path}"
        python3 "$SCRIPT_DIR/local-agent.py" \
            --port "$AGENT_PORT" \
            --path-map "$path_map_arg" \
            --token "$token" &
        echo $! > "$PID_FILE"
        echo "$token" > "$TOKEN_FILE"
        chmod 600 "$TOKEN_FILE"
        log "ローカルエージェント起動: PID $!, port $AGENT_PORT"
    fi

    # トークン読み込み（既存エージェントの場合）
    token=$(cat "$TOKEN_FILE")

    # --- 3. mutagen同期 ---
    mutagen daemon start 2>/dev/null || true
    if mutagen sync list 2>/dev/null | grep -q "Name: ${sync_name}"; then
        log "mutagen同期: 既存セッション再利用"
    else
        log "mutagen同期開始..."
        local exclude_args=""
        while IFS= read -r pattern; do
            [ -n "$pattern" ] && exclude_args="$exclude_args -i $pattern"
        done <<< "$EXCLUDES"

        eval mutagen sync create \
            --name="$sync_name" \
            --mode=two-way-resolved \
            --ignore-vcs \
            $exclude_args \
            "$host:$remote_path" "$local_path"

        # 初回同期待ち
        log "初回同期待ち..."
        local wait_count=0
        while true; do
            if mutagen sync list --name="$sync_name" 2>/dev/null | grep -q "Watching for changes"; then
                break
            fi
            wait_count=$((wait_count + 1))
            if [ $wait_count -gt 120 ]; then
                err "mutagen同期タイムアウト"
                exit 1
            fi
            sleep 5
        done
    fi
    log "mutagen同期: OK"

    # --- 4. クリーンアップ設定 ---
    cleanup() {
        log ""
        log "=== セッション終了 ==="

        # ローカルの変更を表示
        if [ -d "$local_path/.git" ]; then
            log "ローカルの変更:"
            git -C "$local_path" diff --stat 2>/dev/null || true
        fi

        # エージェント停止
        if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
            kill "$(cat "$PID_FILE")" 2>/dev/null || true
            rm -f "$PID_FILE" "$TOKEN_FILE"
            log "ローカルエージェント停止"
        fi

        log ""
        log "mutagen同期は継続中です。停止するには: remote-claude stop"
        log "ローカルでコミット: cd $local_path && git add -A && git commit"
    }
    trap cleanup EXIT

    # --- 5. SSH接続（逆トンネル付き）+ tmux ---
    log "リモートに接続中..."
    ssh -R "${AGENT_PORT}:localhost:${AGENT_PORT}" \
        -t "$host" "
        export COMMAND_AGENT_PORT=${AGENT_PORT}
        export COMMAND_AGENT_TOKEN=${token}
        export PATH=\"\$HOME/bin:\$PATH\"
        cd ${remote_path}
        if tmux has-session -t ${TMUX_SESSION} 2>/dev/null; then
            tmux attach -t ${TMUX_SESSION}
        else
            tmux new-session -s ${TMUX_SESSION} 'claude --dangerously-skip-permissions'
        fi
    "
}

# ============================================================
# setup — リモートセットアップ
# ============================================================

cmd_setup() {
    local host="${1:-$DEFAULT_HOST}"
    if [ -z "$host" ]; then
        err "ssh_hostを指定してください"
        exit 1
    fi
    bash "$SCRIPT_DIR/remote-setup.sh" "$host"
}

# ============================================================
# stop — 全停止
# ============================================================

cmd_stop() {
    local local_path="${1:-$(pwd)}"
    local project_name
    project_name=$(basename "$local_path")
    local sync_name="remote-claude-${project_name}"

    # エージェント停止
    if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        kill "$(cat "$PID_FILE")"
        rm -f "$PID_FILE" "$TOKEN_FILE"
        log "ローカルエージェント停止"
    else
        log "ローカルエージェント: 起動していません"
    fi

    # mutagen停止
    if mutagen sync list 2>/dev/null | grep -q "Name: ${sync_name}"; then
        mutagen sync terminate "$sync_name"
        log "mutagen同期停止: $sync_name"
    else
        log "mutagen同期: セッションなし"
    fi

    log "停止完了"
}

# ============================================================
# status — 状態表示
# ============================================================

cmd_status() {
    echo "=== remote-claude status ==="

    # エージェント
    if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        echo "ローカルエージェント: 起動中 (PID $(cat "$PID_FILE"))"
    else
        echo "ローカルエージェント: 停止"
    fi

    # mutagen
    echo "---"
    echo "mutagen同期:"
    mutagen sync list 2>/dev/null | grep -A5 "remote-claude" || echo "  セッションなし"
}

# ============================================================
# メイン
# ============================================================

main() {
    read_config

    local cmd="${1:-}"

    case "$cmd" in
        stop)    shift; cmd_stop "$@" ;;
        status)  cmd_status ;;
        setup)   shift; cmd_setup "$@" ;;
        -h|--help|help)
            echo "Usage:"
            echo "  remote-claude [ssh_host] [local_path]  — セッション開始"
            echo "  remote-claude setup <ssh_host>          — リモートセットアップ"
            echo "  remote-claude stop [local_path]         — 全停止"
            echo "  remote-claude status                    — 状態表示"
            ;;
        *)       cmd_start "$@" ;;
    esac
}

main "$@"
```

- [ ] **Step 3: コミット**

```bash
git add remote-claude.sh config.json
git commit -m "feat: rewrite remote-claude.sh — transparent remote Claude with local git forwarding"
```

---

### Task 5: 結合テスト

**Files:**
- Modify: `~/.claude/skills/remote-claude/config.json`

- [ ] **Step 1: config.jsonにデフォルトホストを設定**

```json
{
  "default_host": "salmon-river-kose.exe.xyz",
  "agent_port": 9999,
  "remote_base_dir": "~/remote-claude",
  "exclude_patterns": ["build/", ".dart_tool/", "node_modules/", ".gradle/", ".build/", "Pods/"]
}
```

- [ ] **Step 2: リモートセットアップ**

```bash
bash ~/.claude/skills/remote-claude/remote-claude.sh setup salmon-river-kose.exe.xyz
```

Expected: git/ghラッパーがリモートの ~/bin/ にデプロイされる

- [ ] **Step 3: エンドツーエンドテスト**

```bash
cd /Users/m66/StudioProjects/soeasy/sew_app
bash ~/.claude/skills/remote-claude/remote-claude.sh salmon-river-kose.exe.xyz
```

Expected:
1. ローカルエージェントが起動する
2. mutagen同期が開始される
3. SSH逆トンネル付きでリモートに接続される
4. tmux内でclaudeが起動する
5. claude内で `git status` を実行するとローカルのgit状態が返る

- [ ] **Step 4: git転送テスト（claudeの中で）**

claude内で以下を実行させる:
- `git status` → ローカルのリポジトリ状態が表示される
- `git log --oneline -5` → ローカルのコミット履歴が表示される
- `gh pr list` → GitHubのPR一覧が表示される

- [ ] **Step 5: ファイル変更 + ローカル同期テスト**

claude内でファイルを変更させ、ローカルで `git diff` して変更が反映されていることを確認。

- [ ] **Step 6: コミット**

```bash
git add config.json
git commit -m "feat: add default config for remote-claude"
```

---

### Task 6: SKILL.md 更新

**Files:**
- Modify: `~/.claude/skills/remote-claude/SKILL.md`

- [ ] **Step 1: SKILL.mdを最終状態に更新**

新しいアーキテクチャ（ローカルエージェント + 逆トンネル + mutagen）を反映したSKILL.mdに書き直す。

コマンド一覧:
- `remote-claude [host] [path]` — セッション開始
- `remote-claude setup <host>` — リモートセットアップ（初回のみ）
- `remote-claude stop [path]` — 全停止
- `remote-claude status` — 状態表示

- [ ] **Step 2: コミット**

```bash
git add SKILL.md
git commit -m "docs: update SKILL.md for new remote-claude architecture"
```

---

### Task 7: cc-sandboxにコピー＆push

**Files:**
- Copy all to: `/Users/m66/vscode/cc-sandbox/research/remote-claude/`

- [ ] **Step 1: ファイルコピー**

```bash
mkdir -p /Users/m66/vscode/cc-sandbox/research/remote-claude
cp ~/.claude/skills/remote-claude/* /Users/m66/vscode/cc-sandbox/research/remote-claude/
```

- [ ] **Step 2: コミット＆push**

```bash
cd /Users/m66/vscode/cc-sandbox
git add research/remote-claude/
git commit -m "feat: add remote-claude system — transparent remote Claude with local git forwarding"
git push
```
