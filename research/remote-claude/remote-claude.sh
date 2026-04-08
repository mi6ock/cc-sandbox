#!/bin/bash
#
# remote-claude — リモートClaudeセッションの透過的な起動
#
# Usage:
#   remote-claude [ssh_host] [local_path]
#   remote-claude stop [local_path]
#   remote-claude status
#   remote-claude setup <ssh_host>
#   remote-claude install              — シェルにコマンド登録
#
# Install:
#   bash remote-claude.sh install
#   → "remote-claude" コマンドが使えるようになる

set -euo pipefail

# シンボリックリンクを解決して実体のディレクトリを取得
SELF="$0"
if [ -L "$SELF" ]; then
    SELF="$(readlink "$SELF")"
fi
SCRIPT_DIR="$(cd "$(dirname "$SELF")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.json"
PID_FILE="/tmp/remote-claude-agent.pid"
TOKEN_FILE="/tmp/remote-claude-token"
TMUX_SESSION="claude"

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
    local sync_name
    sync_name="rc-$(echo "$project_name" | tr '_' '-' | tr '[:upper:]' '[:lower:]')"
    local token
    token=$(generate_token)

    log "=== remote-claude 起動 ==="
    log "Host: $host"
    log "Local: $local_path"

    # 1. SSH接続テスト＆リモートHOME取得
    log "SSH接続テスト..."
    local remote_home
    remote_home=$(ssh -o ConnectTimeout=5 "$host" "echo \$HOME" 2>/dev/null)
    if [ -z "$remote_home" ]; then
        err "SSH接続失敗: $host"
        exit 1
    fi
    # remote_pathの~をリモートの実際のHOMEに展開
    remote_path="${remote_home}/remote-claude/${project_name}"
    log "Remote: $remote_path"

    # 2. ローカルエージェント起動
    if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        log "ローカルエージェント: 既に起動中 (PID $(cat "$PID_FILE"))"
        token=$(cat "$TOKEN_FILE")
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

    # 3. mutagen同期
    # リモートディレクトリを事前作成（mutagenは自動作成しない）
    ssh -o ConnectTimeout=5 "$host" "mkdir -p $remote_path"
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
            "$local_path" "$host:$remote_path"

        log "初回同期待ち..."
        local wait_count=0
        while true; do
            if mutagen sync list "$sync_name" 2>/dev/null | grep -q "Watching for changes"; then
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

    # 4. クリーンアップ設定
    cleanup() {
        log ""
        log "=== セッション終了 ==="
        if [ -d "$local_path/.git" ]; then
            log "ローカルの変更:"
            git -C "$local_path" diff --stat 2>/dev/null || true
        fi
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

    # 5. SSH接続（逆トンネル付き）→ リモートでclaude起動
    log "リモートClaudeに接続中..."
    ssh -R "${AGENT_PORT}:localhost:${AGENT_PORT}" \
        -t "$host" "
        export COMMAND_AGENT_PORT=${AGENT_PORT}
        export COMMAND_AGENT_TOKEN=${token}
        export PATH=\"\$HOME/bin:\$PATH\"
        cd ${remote_path}
        claude --dangerously-skip-permissions
    "
}

cmd_setup() {
    local host="${1:-$DEFAULT_HOST}"
    if [ -z "$host" ]; then
        err "ssh_hostを指定してください"
        exit 1
    fi
    bash "$SCRIPT_DIR/remote-setup.sh" "$host"
}

cmd_stop() {
    local local_path="${1:-$(pwd)}"
    local project_name
    project_name=$(basename "$local_path")
    local sync_name
    sync_name="rc-$(echo "$project_name" | tr '_' '-' | tr '[:upper:]' '[:lower:]')"

    if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        kill "$(cat "$PID_FILE")"
        rm -f "$PID_FILE" "$TOKEN_FILE"
        log "ローカルエージェント停止"
    else
        log "ローカルエージェント: 起動していません"
    fi

    if mutagen sync list 2>/dev/null | grep -q "Name: ${sync_name}"; then
        mutagen sync terminate "$sync_name"
        log "mutagen同期停止: $sync_name"
    else
        log "mutagen同期: セッションなし"
    fi

    log "停止完了"
}

cmd_status() {
    echo "=== remote-claude status ==="
    if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        echo "ローカルエージェント: 起動中 (PID $(cat "$PID_FILE"))"
    else
        echo "ローカルエージェント: 停止"
    fi
    echo "---"
    echo "mutagen同期:"
    mutagen sync list 2>/dev/null | grep -A5 "remote-claude" || echo "  セッションなし"
}

cmd_install() {
    local self
    self="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
    local bin_dir="$HOME/.local/bin"
    local target="$bin_dir/remote-claude"

    mkdir -p "$bin_dir"

    if [ -f "$target" ] || [ -L "$target" ]; then
        echo "既にインストール済み: $target"
        echo "再インストール: rm $target && bash $0 install"
        return
    fi

    ln -s "$self" "$target"
    echo "完了! シンボリックリンク: $target → $self"

    # PATHに~/.local/binがなければ追加
    if ! echo "$PATH" | tr ':' '\n' | grep -qx "$bin_dir"; then
        local shell_rc=""
        if [ -f "$HOME/.zshrc" ]; then
            shell_rc="$HOME/.zshrc"
        elif [ -f "$HOME/.bashrc" ]; then
            shell_rc="$HOME/.bashrc"
        fi
        if [ -n "$shell_rc" ] && ! grep -q "$bin_dir" "$shell_rc" 2>/dev/null; then
            echo "" >> "$shell_rc"
            echo "# remote-claude" >> "$shell_rc"
            echo "export PATH=\"\$HOME/.local/bin:\$PATH\"" >> "$shell_rc"
            echo "PATHに追加しました: $shell_rc"
            echo "反映するには: source $shell_rc"
        fi
    fi

    echo ""
    echo "使い方:"
    echo "  remote-claude setup <ssh_host>          — 初回セットアップ"
    echo "  remote-claude <ssh_host> [project_path] — セッション開始"
    echo "  remote-claude stop [project_path]       — 停止"
    echo "  remote-claude status                    — 状態確認"
}

main() {
    local cmd="${1:-}"

    # installはconfig不要
    if [ "$cmd" = "install" ]; then
        cmd_install
        return
    fi

    read_config

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
            echo "  remote-claude install                   — コマンド登録"
            ;;
        *)       cmd_start "$@" ;;
    esac
}

main "$@"
