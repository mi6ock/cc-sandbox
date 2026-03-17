# Goal/Plan Manager Hooks for Claude Code

Claude Code セッションにおけるゴール逸脱・タスク途中放棄を防止するフックシステムです。

## 背景: なぜこの仕組みが必要か

Claude Code は長いタスクの途中で「完了した」と判断して作業を中断したり、不要な質問でユーザーに制御を返してしまうことがあります。このフックシステムは、Goal（ゴール）と Plan（プラン）のチェックリストが全て完了するまで、エージェントが勝手に停止できないようにします。

## ファイル構成

```
.claude/
├── goals/
│   └── _example.md          # Goal テンプレート
├── plans/
│   └── _example.md          # Plan テンプレート
├── hooks/
│   ├── inject-context.sh    # GOAL/PLAN の再注入
│   ├── check-plan-goal.sh   # ファイル存在チェック（警告）
│   └── verify-completion.sh # 完了検証 + 停止ブロック
└── settings.json            # フック設定
```

Goal/Plan ファイルはブランチ名に対応します（例: `feature-login` ブランチなら `goals/feature-login.md`）。

## ツール実行フローとフックの介入ポイント

Claude Code がツールを呼び出す際の全体フローと、各フックが介入するタイミングを示します。

```
ユーザーのリクエスト
  │
  ▼
Claude が思考・計画
  │
  ▼
ツール呼び出し（Write, Edit, Bash 等）
  │
  ├─ [PreToolUse フック] ─── ツール実行前に発火
  │
  ▼
  ツール実行
  │
  ├─ [PostToolUse フック] ── ツール実行後に発火
  │                          → check-plan-goal.sh
  │                            Goal/Plan ファイルが無ければ警告
  ▼
Claude が次のアクションを決定
  │
  ├─ 作業を続行 → 次のツール呼び出しへ
  │
  ├─ 停止しようとする
  │   └─ [Stop フック] ── verify-completion.sh
  │       ├─ 未完了あり → exit 2 → ★ブロック（続行を強制）
  │       └─ 全完了     → exit 0 → 停止を許可
  │
  └─ 質問しようとする（AskUserQuestion）
      └─ [PreToolUse フック] ── verify-completion.sh
          ├─ 未完了あり → exit 2 → ★ブロック（質問させない）
          └─ 全完了     → exit 0 → 質問を許可
```

## Claude が作業を中断する2つの経路

Claude Code がユーザーに制御を返す方法は2つあります。

| 経路 | 説明 | ガード |
|------|------|--------|
| **Stop** | ターンを明示的に終了する | `Stop` フック |
| **AskUserQuestion** | ユーザーに質問して作業を一時停止する | `PreToolUse` フック |

両方とも `verify-completion.sh` が検証を行い、未完了タスクがあれば **exit code 2** を返してブロックします。

## 完了判定ロジック

`verify-completion.sh` は以下のルールでチェックを行います。

| 対象 | 条件 | 動作 |
|------|------|------|
| Goal `### must` セクションの `- [ ]` | 1件でも未チェック | **ブロック**（停止不可） |
| Plan 内の全 `- [ ]` | 1件でも未チェック | **ブロック**（停止不可） |
| Goal `### want` セクションの `- [ ]` | 未チェック | **警告のみ**（停止は許可） |

### 安全弁（セーフティバルブ）

エージェントが進捗できず停止もできない無限ループを防ぐため、**連続10回ブロック**されると停止を許可します。ブロック回数はブランチごとに `/tmp/claude-stop-block-{branch}` で管理されます。

```
ブロック 1/10 → 続行を強制
ブロック 2/10 → 続行を強制
  ...
ブロック 10/10 → 停止を許可（ユーザーが状況を確認すべき）
```

