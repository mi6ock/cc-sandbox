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

# 5. PATHに~/binを追加
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
ssh "$SSH_HOST" 'export PATH="$HOME/bin:$PATH"; echo "git wrapper:"; which git; echo "gh wrapper:"; which gh; echo "---"; cat ~/bin/git'

log "セットアップ完了!"
log ""
log "注意: git/ghラッパーは remote-claude セッション中（ローカルエージェント起動中）のみ動作します。"
log "セッション外でgitを使うには /usr/bin/git を直接指定してください。"
