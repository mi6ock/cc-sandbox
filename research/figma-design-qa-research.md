# Figma デザイン QA 調査レポート

LLMがFigmaデザインの細部を正確に実装できない問題の原因分析、解決策、関連ツール・研究の包括的調査。

調査日: 2026-04-06
調査規模: 約200件のリソース（重複除去後約150件）、10件のOSSソースコード調査

---

## 目次

1. [問題の根本原因](#1-問題の根本原因)
2. [LLMの画像認識の物理的限界](#2-llmの画像認識の物理的限界)
3. [Figma MCPの実態と問題点](#3-figma-mcpの実態と問題点)
4. [解決策: 構造化データの取得](#4-解決策-構造化データの取得)
5. [解決策: デザインシステムをLLMに教える](#5-解決策-デザインシステムをllmに教える)
6. [解決策: 画像前処理でLLMの認識を補強](#6-解決策-画像前処理でllmの認識を補強)
7. [解決策: 数値ベースの差分検証パイプライン](#7-解決策-数値ベースの差分検証パイプライン)
8. [解決策: 反復修正ループ](#8-解決策-反復修正ループ)
9. [Figmaプロパティ → Flutter 変換ルール（ソースコード調査）](#9-figmaプロパティ--flutter-変換ルールソースコード調査)
10. [ピクセル比較ライブラリ（コアエンジン）](#10-ピクセル比較ライブラリコアエンジン)
11. [知覚的品質メトリクス](#11-知覚的品質メトリクス)
12. [ビジュアルリグレッションテストフレームワーク](#12-ビジュアルリグレッションテストフレームワーク)
13. [Flutter固有のビジュアルテストツール](#13-flutter固有のビジュアルテストツール)
14. [AI/MLベースの比較手法](#14-aimlベースの比較手法)
15. [Design-to-Code プロダクトの手法](#15-design-to-code-プロダクトの手法)
16. [ブログ記事・事例（日本語）](#16-ブログ記事事例日本語)
17. [ブログ記事・事例（英語）](#17-ブログ記事事例英語)
18. [学術研究・ベンチマーク](#18-学術研究ベンチマーク)
19. [全リソース一覧](#19-全リソース一覧)

---

## 1. 問題の根本原因

LLMがUIデザインの細部を正確に実装できない原因は3層に分かれる。

### 1.1 LLMの画像認識の物理的限界

マルチモーダルLLMは画像を内部的にリサイズして処理する。Claudeは最大1,568px。4Kスクリーンショットの1px borderや2px shadowはリサイズで消失する。

### 1.2 デザインシステムの文脈欠如

monday.comの分析によると、LLMは:
- どのWidgetが存在するか知らない（Card vs Container）
- どのpropsが有効か知らない（elevation vs 手書きbox-shadow）
- どのデザイントークンを使うべきか知らない
- 結果として色をハードコード、Widget選択を間違い、CSSを手書きする

出典: https://engineering.monday.com/how-we-use-ai-to-turn-figma-designs-into-production-code/

### 1.3 画像のみの入力では数値情報が伝わらない

DesignBench（arXiv 2506.06251）の重要な発見:

> コードのみの入力が画像のみの入力を一貫して上回る。マルチモーダル入力は最小限の追加改善しかもたらさない。

LLMに画像を見せるだけでは本質的に不十分。構造化されたデータ（数値）を渡す必要がある。

---

## 2. LLMの画像認識の物理的限界

### 解像度制約

| モデル | 最大入力解像度 | 内部処理解像度 | トークン計算 |
|--------|--------------|--------------|------------|
| Claude | 8,000px（長辺） | 1,568px | (width * height) / 750 |
| GPT-4o | 制限なし | タイル分割処理 | タイル数に依存 |

出典:
- https://platform.claude.com/docs/en/build-with-claude/vision
- https://platform.openai.com/docs/guides/vision

### プロパティ別認識精度

| プロパティ | 画像からの認識精度 | 備考 |
|-----------|------------------|------|
| テキスト内容 | 高い | OCR的処理が得意 |
| 大まかなレイアウト | 中〜高 | 上下左右の配置は概ね正確 |
| 色の大まかな名前 | 中程度 | 「青いボタン」程度は認識 |
| 正確なHEXカラー値 | 低い | #3B82F6 と #2563EB の区別は困難 |
| フォントサイズ (px) | 低い | 14px vs 16px の区別は困難 |
| border幅 | 非常に低い | 1px vs 2px の区別はほぼ不可能 |
| border-radius | 低い | 4px vs 8px の区別は困難 |
| box-shadow | 低い | 影の有無は認識できるがパラメータ推定は不正確 |
| padding/margin | 低い | 8px vs 12px の区別は困難 |
| アイコンの種類 | 中〜低 | 標準的なアイコンは認識、カスタムは見落としやすい |

### 関連研究

- MIT CSAIL "A Vision Check-up for Language Models" (2024): LLMはテクスチャ、正確な形状、表面の接触関係が苦手。生成はできても認識・検証が困難という非対称性がある
  - https://vision-checkup.csail.mit.edu/
  - https://arxiv.org/abs/2401.01862
- MME-RealWorld (ICLR 2025): GPT-4o, Gemini 1.5 Pro, Claude 3.5 Sonnetでも60%未満の精度。高解像度の実世界画像理解は未解決課題
- ICLR 2025 "MLLMs Know Where to Look": LLMは小さい物体の「位置」は正しく把握しているが「詳細の認識」に失敗する。クロップでTextVQA精度 +8〜12pt向上
  - https://arxiv.org/abs/2502.17422

---

## 3. Figma MCPの実態と問題点

### Figma公式MCPの既知の問題

| 問題 | 詳細 | 出典 |
|------|------|------|
| `get_design_context` の失敗 | 5-6kトークン超のコンテナで動作しなくなる | [Figma Forum](https://forum.figma.com/report-a-problem-6/get-design-context-does-not-work-local-remote-mcp-server-47246) |
| スクリーンショットフォールバック | `get_design_context` 失敗時に `get_screenshot` に頼り、画像推測になる | 複数報告 |
| スタイリング精度 | 85-90%が間違うケースあり | [Figma Forum](https://forum.figma.com/report-a-problem-6/figma-mcp-can-t-get-good-results-have-tried-many-things-41861) |
| Code Connect欠落 | レスポンスに含まれないケースがある | ユーザー報告 |
| SVGアセット | インポート文が変わりほぼ使えない形式に | ユーザー報告 |
| レート制限 | Starterプランで月6リクエスト程度 | [Figma Forum](https://forum.figma.com/report-a-problem-6/figma-mcp-rate-limit-exceeded-please-try-again-tomorrow-51927) |
| 相互運用性 | 事前承認クライアントのみ（Claude Code, Cursor, VS Code, Codex） | [Figma Forum](https://forum.figma.com/share-your-feedback-26/figma-s-approach-breaks-the-core-promise-of-mcp-52507) |

### 公式MCP vs Figma-Context-MCP 比較

| 観点 | Figma-Context-MCP (GLips) | 公式 Figma MCP |
|------|--------------------------|----------------|
| データ形式 | YAML (デフォルト) / JSON | XML / React+Tailwind コード |
| データ圧縮 | Figma APIレスポンスを99.5%削減 | トークン量多め |
| 角丸・影・ボーダー | CSS互換形式で正確な数値 | `get_design_context` で取得（失敗リスクあり） |
| Code Connect | 非対応 | 対応（Organization/Enterpriseのみ） |
| キャンバス書き込み | 非対応 | 対応 |
| 認証 | Figma APIトークン（制限緩い） | OAuth（承認済みクライアントのみ） |
| ホスティング | セルフホスト（Node / Docker） | Figma提供 |
| Stars | ~5,000 | 公式 |

出典:
- https://github.com/GLips/Figma-Context-MCP
- https://github.com/GLips/Figma-Context-MCP/issues/178
- https://cianfrani.dev/posts/a-better-figma-mcp/

---

## 4. 解決策: 構造化データの取得

### 4.1 Figma-Context-MCP（ソースコード調査済み）

**リポジトリ**: https://github.com/GLips/Figma-Context-MCP

SimplifiedNode に変換し、99.5%のデータ削減を実現。

#### 細部プロパティの扱い方（ソースコードから確認）

| プロパティ | 実装ファイル | 処理内容 |
|---|---|---|
| 角丸 | `built-in.ts:137-142` | `cornerRadius` → `"8px"`, `rectangleCornerRadii` → `"8px 4px 0px 0px"` (CSS shorthand) |
| 影 | `effects.ts:17-58` | DROP_SHADOW → CSS `box-shadow`形式, INNER_SHADOW → `inset`, LAYER_BLUR → `filter: blur()` |
| ボーダー | `style.ts:231-257` | strokes → CSS形式, `individualStrokeWeights` → CSS shorthand |
| 色 | `style.ts:265-329` | SOLID → `#HEX`/`rgba()`, IMAGE → `SimplifiedImageFill`, GRADIENT → CSS gradient |
| レイアウト | `layout.ts` | AutoLayout → flexbox変換 (mode, justifyContent, alignItems, gap, padding, sizing) |
| アイコン | `built-in.ts:234-296` | VECTOR系子要素のみの FRAME/GROUP → `IMAGE-SVG` に折りたたみ |

#### 出力フォーマット（YAML）

```yaml
metadata:
  name: "ファイル名"
nodes:
  - id: "1:234"
    name: "Card"
    type: "FRAME"
    borderRadius: "12px"
    fills: "Surface/White"
    effects: "shadow_elevated"
    layout: "layout_vertical"
    children:
      - id: "1:235"
        name: "Icon"
        type: "IMAGE-SVG"
globalVars:
  styles:
    shadow_elevated:
      boxShadow: "0px 2px 8px 0px rgba(0, 0, 0, 0.12)"
```

### 4.2 Figma Raw プラグイン

選択したFigma要素をLLM向け構造化JSONにエクスポート。Flat JSON/Nested JSONの2形式。
- https://www.figma.com/community/plugin/1491678546144854232/figma-raw-export-design-data-for-ai-llm-agents

### 4.3 その他のFigma→構造化データツール

| ツール | 概要 | URL |
|--------|------|-----|
| Figma to AI JSON | AI/LLMコード生成に最適化されたJSON | https://www.figma.com/community/plugin/1587577656366372788 |
| fig4ai | Figma設計データをAI向けに構造化 | https://github.com/f/fig4ai |
| fig2json | .figファイルをLLMフレンドリーなJSONに変換するCLI | https://github.com/kreako/fig2json |
| Figma REST API Spec | API型定義 | https://github.com/figma/rest-api-spec |

### 4.4 Figma MCP Server 実装一覧（ソースコード調査済み）

| リポジトリ | アプローチ | 影の扱い | アイコンの扱い |
|---|---|---|---|
| **GLips/Figma-Context-MCP** | REST API → YAML/JSON | CSS box-shadow形式 | SVGコンテナ折りたたみ |
| **sonnylazuardi/cursor-talk-to-figma-mcp** | Plugin API (WebSocket) | **欠落（フィルタで除外）** | VECTORスキップ |
| **Figma公式MCP** | 独自API → React+Tailwind | コードに埋込 | Code Connect |
| **thirdstrandstudio/mcp-figma** | REST API全ラッパー | 生データそのまま | 生データそのまま |
| **mhmzdev/figma-flutter-mcp** | Figma→Flutter専用MCP | - | - |

---

## 5. 解決策: デザインシステムをLLMに教える

### 5.1 DESIGN.md（Google Stitch由来）

プロジェクトルートに配置するだけでAIエージェントが参照する。
- Google Stitch: https://stitch.withgoogle.com/
- awesome-design-md: https://github.com/VoltAgent/awesome-design-md（55+サイトの事例集、3日で4,385 star）

### 5.2 Hardik Pandya の3層アプローチ

1. **Specファイル**: スペーシング、カラー、コンポーネントガイドラインをMarkdownで記述
2. **トークン層**: LLMが選択する閉じた値の集合（`var(--color-link)` 等）。値の捏造を防止
3. **監査層**: ハードコードされた値（hex色、ピクセル間隔）を検出

出典: https://hvpandya.com/llm-design-systems

### 5.3 Figma Code Connect

FigmaコンポーネントとコードリポジトリのWidgetを直接マッピング。
「Code Connectだけで忠実度の問題の半分が解消される」との報告。

- https://github.com/figma/code-connect
- https://help.figma.com/hc/en-us/articles/23920389749655-Code-Connect

### 5.4 Flutter固有の解決策

- Flutter GenUI SDK: カタログに登録されたWidgetのみ使用可能にする仕組み
  - https://github.com/flutter/genui
- MCPサーバーでデザイントークンをLLMからクエリ可能にする
  - https://dev.to/patrick_botkins_9aac0a7c5/why-ai-coding-tools-generate-ugly-flutter-apps-and-how-to-fix-it-3a9c

### 5.5 デザイントークン自動変換ツール（Flutter）

| ツール | 概要 | URL |
|--------|------|-----|
| figma2flutter | Tokens Studio JSON → Dart | https://pub.dev/packages/figma2flutter |
| Figma Puller | Figma API → AppColors, AppIconWidgets | https://pub.dev/packages/figma_puller |
| Design Tokens Builder | トークンJSON → Flutter ThemeData | https://github.com/simpleclub/design_tokens_builder |
| Style Dictionary | JSONトークン → Dart/Swift/Kotlin/CSS | https://amzn.github.io/style-dictionary/ |
| Tokens Studio | Figmaプラグイン + GitHub連携 | https://tokens.studio/ |

---

## 6. 解決策: 画像前処理でLLMの認識を補強

### 6.1 Set-of-Mark (SoM) Prompting

Microsoft Research発。画像にセグメンテーションモデル（SAM/SEEM）でUI要素を分割し、ラベルを重ねてLLMに渡す。GPT-4Vのvisual groundingを劇的に改善。RefCOCOgでゼロショットSOTA超え。

- 論文: https://arxiv.org/abs/2310.11441
- 公式実装: https://github.com/microsoft/SoM
- SoM-LLaVA: 30kデータでLLaVA学習に追加するだけで全ベンチマーク1-6%改善
  - https://github.com/zzxslp/SoM-LLaVA

### 6.2 OmniParser（Microsoft、ソースコード調査済み）

YOLOv8 + Florence-2/BLIP2 でUI要素を検出・キャプション生成。

- **検出**: YOLOモデルでバウンディングボックス
- **OCR**: EasyOCR/PaddleOCRでテキスト抽出
- **キャプション**: アイコン領域を64x64にリサイズ、Florence-2でキャプション（例: "a blue checkmark icon"）
- **出力**: ラベル付きアノテーション画像 + パース済みコンテンツリスト

- V2: Screen Spot Proで39.5%（GPT-4oの0.8%ベースラインから大幅向上）
- https://github.com/microsoft/OmniParser

### 6.3 Divide-and-Conquer (DCGen)

画面を分割して個別にコード生成→結合。大きな画像で視覚的類似度15%向上、コード類似度8%向上。
LLMの3つの問題: 要素の省略、要素の歪み、要素の配置ミス。小さく切り出すとこれらが軽減される。

- 論文: https://arxiv.org/abs/2406.16386
- GitHub: https://github.com/WebPAI/DCGen

### 6.4 クロッピング/ズーム研究

| 研究 | 手法 | 効果 | URL |
|------|------|------|-----|
| MLLMs Know Where to Look (ICLR 2025) | MLLMのアテンションマップで自動クロップ | TextVQA +8〜12pt | https://arxiv.org/abs/2502.17422 |
| CropVLM (2024) | 強化学習で動的ズームイン | 細部キャプチャ能力向上 | https://arxiv.org/html/2511.19820 |
| Zoom-Refine (2025) | 2段階: 予備回答 + 高解像度クロップで再評価 | MME-RealWorldで有意改善 | https://arxiv.org/abs/2506.01663 |
| ZoomEye (EMNLP 2025) | 木構造ベースの画像探索 | 人間のようなズーム行動 | https://aclanthology.org/2025.emnlp-main.335/ |

### 6.5 UI要素セグメンテーションモデル

| モデル | 開発元 | 特徴 | URL |
|--------|--------|------|-----|
| ScreenAI | Google | 5Bパラメータ。デスクトップ/モバイル/タブレット対応 | https://arxiv.org/abs/2402.04615 |
| UI-TARS | ByteDance | 2B/7B/72B。GPT-4o等を10+ベンチマークで上回る | https://github.com/bytedance/UI-TARS |
| CogAgent | 清華大学 | 高解像度(1120x1120)GUI理解 | https://github.com/THUDM/CogVLM |
| Ferret-UI | Apple | モバイルUI画面でウィジェット分類・アイコン認識 | 論文 |
| UIED | 研究 | CV + DLのハイブリッドUI要素検出 | https://github.com/MulongXie/UIED |

---

## 7. 解決策: 数値ベースの差分検証パイプライン

### 7.1 uiMatch

Figmaデザインと実装UIのピクセルレベル比較を自動化。Playwright + ΔE2000色差アルゴリズム。CI統合可能。

- https://github.com/kosaki08/uimatch
- https://dev.to/kosaki08/uimatch-figma-to-implementation-visual-diff-with-playwright-and-ci-1819

### 7.2 測定駆動型ピクセルパーフェクトループ

Playwrightで実装の測定値を自動抽出（幅、高さ、マージン、パディング、色等）→ Figmaスペックと数値比較 → LLMに「この数値が間違っている」と伝えて修正。

> 「AIは労働力、Playwrightは品質ゲート」

- https://vadim.blog/pixel-perfect-playwright-figma-mcp
- https://www.buildmvpfast.com/blog/figma-to-code-pixel-perfect-loop-ai-agent-screenshot-iterate-2026

### 7.3 Flutter Widget Testでのプロパティ抽出

```dart
final container = tester.widget<Container>(find.byType(Container));
final decoration = (container.decoration as BoxDecoration);
expect(decoration.borderRadius, BorderRadius.circular(12));

final renderBox = tester.renderObject<RenderBox>(find.byKey(Key('myWidget')));
expect(renderBox.size.width, 200.0);
```

### 7.4 Design Diff ツール

| ツール | アプローチ | 特徴 | URL |
|--------|-----------|------|-----|
| Floto Design Diff | AI + ピクセル | Smart/Exactモード。Linear連携 | https://floto.ai/design-diff |
| Baz Pixel Perfect | コンポーネント理解 | ブラインドdiffではなく意図理解 | https://baz.co/resources/pixel-perfect-by-baz |
| Applitools Eyes | Visual AI | Root Cause Analysis。Figma Plugin あり | https://applitools.com/ |

### 7.5 提案パイプライン（Flutter向け）

```
[Figma REST API / Figma Raw]
        ↓
  デザインスペックJSON
        ↓
[Flutter Widget Test]
  tester.widget() で各Widgetプロパティ抽出
  → 実装スペックJSON生成
        ↓
[差分比較エンジン]
  property-by-property で数値比較
  → { element: "Card", property: "borderRadius", figma: 12, actual: 8, delta: -4 }
        ↓
[LLMフィードバック]
  差分レポートをプロンプトに含め修正指示 → 3-5ラウンドで収束
        ↓
[CI/GitHub Actions]
  PRコメント投稿 / 閾値超過でbuild fail
```

---

## 8. 解決策: 反復修正ループ

### 8.1 収束の定量モデル

```
Acc_t = Upp - α^t × (Upp - Acc_0)

Upp（上限精度）= CS / (1 - CL + CS)
α（収束速度）= CL - CS
```

- CL (Confidence Level): 正しい部分を壊さない確率（例: 0.9）
- CS (Critique Score): エラーを修正できる確率（例: 0.4）
- CL=0.9, CS=0.4 の場合:
  - Round 1: 50%改善
  - Round 2: 累積75%改善
  - Round 3-5: 90%+に収束
  - Round 6以降: 新規エラーリスクが修正利益を超過

出典: https://dev.to/yannick555/iterative-review-fix-loops-remove-llm-hallucinations-and-there-is-a-formula-for-it-4ee8

### 8.2 関連研究

| 研究 | 手法 | URL |
|------|------|-----|
| SpecifyUI (ICSME 2025) | compile→feedback→repairループ最大3回。3レベルの修正粒度 | https://arxiv.org/abs/2509.07334 |
| LLMLOOP (ICSME 2025) | 5段階の反復ループ（コンパイル→静的解析→テスト→ミューテーション） | https://arxiv.org/pdf/2603.23613 |
| DCGen (FSE 2025) | 分割統治で15%精度向上 | https://arxiv.org/abs/2406.16386 |
| ScreenCoder | 3段階マルチエージェント（Grounding→Planning→Generation） | https://arxiv.org/abs/2507.22827 |

### 8.3 コンテキスト腐敗への対策

- 反復回数を制限（最大5ラウンド）
- 収束しない場合はコンポーネントを分割
- 生成用プロンプトとレビュー用プロンプトを分離
- 各ラウンドでは直近の変更箇所のみレビュー

---

## 9. Figmaプロパティ → Flutter 変換ルール（ソースコード調査）

bernaferrari/FigmaToCode および aloisdeniel/figma-to-flutter のソースコードを調査。

### 9.1 重要な発見

1. **Card Widget は両リポジトリとも使用しない** — shadow + cornerRadius + fills があっても常に Container + BoxDecoration で表現
2. **INNER_SHADOW は Flutter 変換で未対応** — BoxShadow に inset オプションがないため
3. **VECTOR/BOOLEAN_OPERATION は未対応** — アイコンやカスタムシェイプは警告のみ。SVG/Icon変換なし
4. Material Design のセマンティックWidget（Card, AppBar, ListTile等）への変換は行わない。ピクセル再現アプローチ

### 9.2 ノードタイプ別 Widget 選択（FigmaToCode）

| Figmaノードタイプ | Flutter Widget |
|---|---|
| RECTANGLE/ELLIPSE/STAR/POLYGON/LINE | Container + BoxDecoration/ShapeDecoration |
| GROUP | Stack |
| FRAME + AutoLayout | Row/Column/Wrap (makeRowColumnWrap) |
| FRAME + 絶対配置の子あり | Stack に強制 |
| FRAME + layoutMode NONE | Stack（フォールバック） |
| TEXT（単一スタイル） | Text + TextStyle |
| TEXT（複数スタイル） | Text.rich(TextSpan) |
| VECTOR | 非対応（警告出力） |

### 9.3 AutoLayout → Row/Column/Wrap

| 条件 | Widget |
|---|---|
| layoutWrap == WRAP + primaryAxisSizingMode == FIXED | Wrap |
| layoutMode == HORIZONTAL | Row |
| layoutMode == VERTICAL | Column |

#### Alignment マッピング

| Figma primaryAxisAlignItems | Flutter MainAxisAlignment |
|---|---|
| MIN / undefined | start |
| CENTER | center |
| MAX | end |
| SPACE_BETWEEN | spaceBetween |

| Figma counterAxisAlignItems | Flutter CrossAxisAlignment |
|---|---|
| MIN / undefined | start |
| CENTER | center |
| MAX | end |
| BASELINE | baseline |

### 9.4 サイズ制約

| Figma layoutSizing | Flutter |
|---|---|
| FILL + 親が同方向のRow/Column | Expanded |
| FILL + 親が異なる方向 | double.infinity |
| HUG | サイズ指定なし |
| FIXED | 固定値 |

### 9.5 Decoration 選択（Container vs ShapeDecoration）

| 条件 | Decoration |
|---|---|
| STAR | ShapeDecoration(shape: StarBorder) |
| POLYGON | ShapeDecoration(shape: StarBorder.polygon) |
| ELLIPSE | ShapeDecoration(shape: OvalBorder) |
| strokeWeight が存在 | ShapeDecoration(shape: RoundedRectangleBorder) |
| 上記以外 | BoxDecoration |

### 9.6 影の変換

```dart
// DROP_SHADOW → BoxShadow
BoxShadow(
  color: Color(0xAABBCCDD),
  blurRadius: 10,              // effect.radius
  offset: Offset(4, 4),        // effect.offset
  spreadRadius: 2,             // effect.spread
)
// INNER_SHADOW → Flutter非対応（スキップ）
// Material elevation へのマッピング → 行わない（常にBoxShadow）
```

### 9.7 色変換

| Figma fills | Flutter |
|---|---|
| SOLID（黒, opacity=1） | Colors.black |
| SOLID（白, opacity=1） | Colors.white |
| SOLID（その他） | Color(0xAARRGGBB) |
| GRADIENT_LINEAR | LinearGradient(begin, end, colors) |
| GRADIENT_RADIAL | RadialGradient(center, radius, colors) |
| GRADIENT_ANGULAR | SweepGradient(center, startAngle, endAngle, colors) |
| IMAGE | DecorationImage(image: NetworkImage(...), fit: BoxFit.cover) |

### 9.8 Padding

| 条件 | Flutter |
|---|---|
| 4辺同じ | EdgeInsets.all(16) |
| 左右同じ + 上下同じ | EdgeInsets.symmetric(horizontal, vertical) |
| それ以外 | EdgeInsets.only(top, left, right, bottom) |

### 9.9 アイコン検出ヒューリスティクス（FigmaToCode）

ファイル: `packages/backend/src/altNodes/iconDetection.ts`

- サイズ制限: 64px以下をアイコン候補
- SVGエクスポート設定があれば即アイコン判定
- VECTOR, BOOLEAN_OPERATION, STAR, POLYGON は無条件でアイコン
- FRAME/GROUP が64px以下で子にTEXT/FRAMEがなくVECTOR系のみならアイコンコンテナ
- TEXT, FRAME, COMPONENT, INSTANCE を子に含むコンテナはアイコンではない

---

## 10. ピクセル比較ライブラリ（コアエンジン）

### ソースコード調査済みツール

| ツール | 言語 | 比較手法 | Stars | 特徴 |
|---|---|---|---|---|
| **pixelmatch** | JS | YIQ色空間の知覚的色差 | 6.7K | デファクトスタンダード。272行、依存ゼロ |
| **looks-same** | JS | CIEDE2000（CIE76事前フィルタ付き） | 820 | Yandex製。JND=2.3で人間知覚に最も忠実 |
| **Resemble.js** | JS | チャンネル別RGB閾値 | 4.6K | BackstopJSが内部利用。5種差分可視化 |
| **odiff** | Zig/SIMD | SIMD最適化ピクセル比較 | 2.6K | ImageMagickの6倍高速 |
| **DSSIM** | Rust | マルチスケールSSIM（LAB色空間） | - | 5段階スケール。学術的に最も正確 |

### アルゴリズム詳細（ソースコードから確認）

**pixelmatch** (`index.js:209`):
- `colorDelta()`: RGB→YIQ変換後、`0.5053*Y² + 0.299*I² + 0.1957*Q²`で知覚的色差計算
- AA検出: Vysniauskas 2009論文。8近傍の輝度差からhasManySiblings()で判定

**looks-same** (`lib/same-colors.js`):
- CIE76で事前フィルタ（tolerance*6.2以上→即不一致、tolerance*0.695以下→即一致）
- 範囲内のみ高コストなCIEDE2000を計算

**DSSIM** (`dssim-core/src/dssim.rs:372-410`):
- SSIM: `(2*mu1*mu2 + C1)(2*sigma12 + C2) / ((mu1²+mu2² + C1)(sigma1²+sigma2² + C2))`
- 5段階マルチスケール重み: [0.028, 0.197, 0.322, 0.298, 0.155]
- 最終スコア: DSSIM = 1/SSIM - 1

### エコシステム依存関係

```
pixelmatch
  ├── jest-image-snapshot（デフォルト）
  ├── reg-suit / reg-cli（via img-diff-js）
  ├── Lost Pixel（選択肢の1つ）
  ├── Playwright toHaveScreenshot()（内部利用）
  └── Loki（デフォルト）

odiff
  ├── Argos CI（二段階戦略）
  └── Lost Pixel（選択肢の1つ）

Resemble.js → BackstopJS
looks-same → Creevey, Loki
```

### その他のライブラリ

| ツール | 言語 | 特徴 | URL |
|---|---|---|---|
| BlazeDiff | Rust/SIMD | odiffの3-4倍高速。SSIM/GMSDモジュールも提供 | https://github.com/teimurjan/blazediff |
| Honeydiff | Rust | 空間クラスタリング。「5つの独立領域が変化」のように報告 | https://github.com/vizzly-testing/honeydiff |
| blink-diff | JS | Yahoo製。4次元色空間ピタゴラス距離。メンテ停止 | https://github.com/yahoo/blink-diff |
| image-diff-rs | Rust/WASM | 多フォーマット対応 | https://github.com/bokuweb/image-diff-rs |
| image-compare | Rust | SSIM+RMSハイブリッド | https://github.com/ChrisRega/image-compare |
| Jimp | JS | 64ビットpHash + pixelmatch | https://github.com/jimp-dev/jimp |

---

## 11. 知覚的品質メトリクス

| 指標 | 手法 | 人間知覚との一致率 | URL |
|---|---|---|---|
| SSIMULACRA 2 | MS-SSIM + 非対称エラーマップ | 87% | https://github.com/cloudinary/ssimulacra2 |
| DSSIM | マルチスケールSSIM（LAB） | 82% | https://github.com/kornelski/dssim |
| Butteraugli | 心理視覚的差異モデル | 80% | https://github.com/google/butteraugli |
| LPIPS | CNN中間特徴量 | SSIM以上 | https://github.com/richzhang/PerceptualSimilarity |
| SSIM | 輝度+コントラスト+構造 | 標準 | scikit-image, OpenCV等 |
| PSNR | MSEベース | SSIMより低い | 全ライブラリ |
| DreamSim | DINO+CLIP+OpenCLIPアンサンブル | LPIPS以上 | https://github.com/ssundaram21/dreamsim |

---

## 12. ビジュアルリグレッションテストフレームワーク

| ツール | Stars | 内部エンジン | 特徴 |
|---|---|---|---|
| BackstopJS | 6.7K | Resemble.js | before/afterスライダーUI。Docker対応 |
| reg-suit | - | pixelmatch | 日本発。S3/GCS連携。GitHub PR通知 |
| Lost Pixel | 1.1K | pixelmatch or odiff | Percy/Chromatic OSS代替 |
| Loki | - | pixelmatch/looks-same | Storybook専用。React Native対応 |
| Argos CI | - | odiff（二段階） | Base diff + Color sensitive diff |
| Visual Regression Tracker | - | REST API型 | セルフホスト。Flutter相性良好 |
| Playwright toHaveScreenshot() | 標準 | pixelmatch | 追加依存不要。2026年のベストプラクティス |
| jest-image-snapshot | - | pixelmatch or SSIM | ブラー前処理。Jest統合 |

---

## 13. Flutter固有のビジュアルテストツール

| ツール | Stars | 状態 | 特徴 |
|---|---|---|---|
| Flutter matchesGoldenFile | 標準 | 安定 | SDK組込み。OS間レンダリング差異が課題 |
| Alchemist | 295 | 活発 | golden_toolkit後継。CI/ローカル差異自動吸収 |
| golden_toolkit | - | discontinued | 2025年にメンテ停止。Alchemistへ移行推奨 |
| Widgetbook | 919 | 活発 | Flutter版Storybook + Figma Reviews |
| Patrol | 1.2K | 活発 | Flutter-first E2E。ネイティブUI操作可 |
| Maestro | 13.4K | 活発 | YAML E2E。assertScreenshot対応 |
| Screenshotbot | SaaS | - | Flutter Golden Test連携。リポジトリにゴールデン不要 |

### Android ネイティブ

| ツール | Stars | 特徴 |
|---|---|---|
| Paparazzi (Cash App) | 2.6K | JVM上レンダリング。エミュレータ不要 |
| Roborazzi | 923 | Robolectricベース。インタラクション後キャプチャ可能 |
| Compose Preview Screenshot Testing | Google公式 | @PreviewTestアノテーション |

### iOS ネイティブ

| ツール | Stars | 特徴 |
|---|---|---|
| swift-snapshot-testing (Point-Free) | 4.2K | iOS界隈最人気 |
| iOSSnapshotTestCase (Uber) | 1.8K | スナップショットの原点 |

---

## 14. AI/MLベースの比較手法

| ツール/手法 | アプローチ | 備考 |
|---|---|---|
| Applitools Visual AI | 独自DLエンジン。意味的差分 | Fortune 500多数採用 |
| GPT-4o / Claude Vision | 2画像入力→差分レポート | 意味的差分に強い |
| ScreenAI (Google) | 5B VLM。UI理解特化 | UIタスクでSOTA |
| UI-TARS (ByteDance) | UI理解特化マルチモーダル | GPT-4o等を上回る |
| OmniParser (Microsoft) | YOLO + Florence-2 | UI要素検出+キャプション |
| Set-of-Mark | セグメンテーション + ラベル | visual grounding改善 |

---

## 15. Design-to-Code プロダクトの手法

| ツール | 手法 | Flutter対応 | URL |
|---|---|---|---|
| screenshot-to-code | 画像→マルチモーダルLLM→コード。67K+ star | なし | https://github.com/abi/screenshot-to-code |
| v0.dev (Vercel) | プロンプト→React+shadcn/ui | なし | https://v0.app/ |
| Builder.io | カスタムLLM + Mitosisコンパイラ | あり | https://www.builder.io/blog/figma-to-flutter |
| Locofy | Large Design Models。パターン認識 | なし | https://www.locofy.ai/ |
| Anima | マルチFWエクスポート | なし | https://www.animaapp.com/ |
| tldraw makeReal | スケッチ→GPT-4V→Tailwind HTML | なし | https://makereal.tldraw.com/ |
| Google Stitch | テキスト→高忠実度UI。DESIGN.md | なし | https://stitch.withgoogle.com/ |
| FigmaToCode | Figma Plugin → HTML/Flutter/SwiftUI/Compose | **あり** | https://github.com/bernaferrari/FigmaToCode |

---

## 16. ブログ記事・事例（日本語）

| タイトル | ソース | キーポイント |
|---------|--------|------------|
| 制作現場におけるビジュアルリグレッションテストの導入 | LINE Engineering | 画像UIでDOMテスト困難な場面でVRT有効 |
| 手軽に始めるビジュアルリグレッションテスト | ラクスエンジニアブログ | Playwright+reg-suitで工数2-3割削減 |
| reg-suitとCypressを使ってVRT導入 | SMARTCAMP | SaaSプロダクトでの具体的導入ステップ |
| VRTで手間と時間を節約 | SmartHR Tech Blog | ライブラリアップデート影響の網羅的検知 |
| 今さら聞けないVRTをChromaticで始める | Sansan Tech Blog | Chromatic入門 |
| スナップショットテスト→VRT移行 | CyberAgent (ABEMA) | トレードオフ分析 |
| N予備校にVRT導入 + tips | ドワンゴ | Storycap+reg-suitの設定値 |
| VRT運用Tips | リクルートテックブログ | コードレビューでVRT活用 |
| 2023年VRTツール選択肢 | Zenn/Loglass | 日本語で最も包括的なツール比較 |
| 1pxの変化も見逃さないVRT | dely (クラシル) | 具体的精度実現方法 |
| Figmaやめて、AIとコードでUI | Zenn/AIShift | デザインと実装の境界をなくす |
| AI自走型デザインコーディングプロンプト | Zenn/Kikagaku | 80点が限度。80→100は人間 |
| MCP で繋ぐ Figma とデザインシステム | Speaker Deck/kimuson | get_figma_data→list_components→get_design_tokens |
| Figma MCPでFlutterコード生成 | Zenn/ivry | Widgetごと生成で高精度 |
| Claude CodeとFigma MCPをFlutterで試す | アドグローブ | 実践レポート |
| FigmaからFlutterへのデザイントークン自動変換 | ZOZO TECH BLOG | デザイントークンワークフロー |

---

## 17. ブログ記事・事例（英語）

| タイトル | ソース | キーポイント |
|---------|--------|------------|
| How We Use AI to Turn Figma Designs into Production Code | monday.com | デザインシステムMCP構築。11ノードグラフ |
| Figma to Code Pixel-Perfect Loop | BuildMVPFast | 測定駆動反復。Playwrightが品質ゲート |
| Pixel-Perfect UI with Playwright and Figma MCP | Vadim's blog | 数値測定→差分フィードバック |
| Building a Figma-Driven MCP Production Pipeline | Francesca Tabor | 「常にMCPからUI導出。ハルシネーション禁止」 |
| Dear LLM, here's how my design system works | UX Collective | デザインシステムを構造化データとして定義 |
| Tips for getting LLMs to write good UI | Sam Pierce Lolla | Components.md。セマンティックprops優先 |
| Why AI coding tools generate ugly Flutter apps | DEV Community | MCPでデザイントークン公開が解決策 |
| Expose your design system to LLMs | Hardik Pandya | 3層アプローチ（Spec/トークン/監査） |
| From Figma to Production Code in 30 Minutes | DEV Community | 体系的ワークフロー |
| Prompt Engineering for UI: Figma Make | Medium | TC-EBC構造のプロンプト |
| Reduce Visual Testing Flakiness | visual-regression-testing.dev | 閾値適切設定で80%削減 |

---

## 18. 学術研究・ベンチマーク

| 研究 | 会議/年 | 内容 | URL |
|------|---------|------|-----|
| Design2Code | NAACL 2025 | 484Webページ。Qwen3 VL 235Bがスコア0.934で首位 | https://llm-stats.com/benchmarks/design2code |
| DesignBench | 2025 | 900ページ。コード入力が画像入力を一貫して上回る | https://arxiv.org/abs/2506.06251 |
| Sketch2Code | 2024 | 731スケッチ + 484Webページ | https://arxiv.org/abs/2410.16232 |
| DCGen | FSE 2025 | 分割統治で15%精度向上 | https://arxiv.org/abs/2406.16386 |
| ScreenCoder | 2025 | 3段階マルチエージェント | https://arxiv.org/abs/2507.22827 |
| Widget2Code | CVPR 2026 | WidgetDSL。FW非依存DSL | https://arxiv.org/abs/2512.19918 |
| Set-of-Mark | 2023 | visual grounding劇的改善 | https://arxiv.org/abs/2310.11441 |
| OmniParser V2 | 2025 | Screen Spot Proで39.5% | https://arxiv.org/abs/2408.00203 |
| SpecifyUI | ICSME 2025 | Debug Agent。3レベル修正粒度 | https://arxiv.org/abs/2509.07334 |
| SSIM原論文 | 2004 | 構造的類似度の理論基盤 | Wang et al. |
| MLLMs Know Where to Look | ICLR 2025 | クロップでTextVQA +8〜12pt | https://arxiv.org/abs/2502.17422 |
| Vision Check-up for LMs | MIT CSAIL 2024 | テクスチャ・形状認識が苦手 | https://arxiv.org/abs/2401.01862 |

---

## 19. 全リソース一覧

### OSSリポジトリ（ソースコード調査済み: ★）

| リポジトリ | Stars | 調査 |
|---|---|---|
| mapbox/pixelmatch | 6.7K | ★ |
| gemini-testing/looks-same | 820 | ★ |
| rsmbl/Resemble.js | 4.6K | ★ |
| garris/BackstopJS | 6.7K | ★ |
| reg-viz/reg-suit | - | ★ |
| lost-pixel/lost-pixel | 1.1K | ★ |
| americanexpress/jest-image-snapshot | - | ★ |
| kornelski/dssim | - | ★ |
| argos-ci/argos | - | ★ |
| Betterment/alchemist | 295 | ★ |
| GLips/Figma-Context-MCP | ~5K | ★ |
| sonnylazuardi/cursor-talk-to-figma-mcp | - | ★ |
| bernaferrari/FigmaToCode | - | ★ |
| microsoft/OmniParser | - | ★ |
| microsoft/SoM | - | ★ |
| abi/screenshot-to-code | 67K+ | ★ |
| figma/mcp-server-guide | 公式 | ★ |
| dmtrKovalenko/odiff | 2.6K | - |
| bytedance/UI-TARS | - | - |
| figma/code-connect | 公式 | - |
| WebPAI/DCGen | - | - |
| flutter/genui | 公式 | - |
| kosaki08/uimatch | - | - |
| VoltAgent/awesome-design-md | 4.4K | - |

### Figma プラグイン

| プラグイン | 用途 |
|---|---|
| Figma Raw | LLM向け構造化JSONエクスポート |
| Figma to AI JSON | AI最適化JSON |
| Pixelay | デザインとWebのオーバーレイ比較 |
| Design Lint | デザイン不整合検出 |
| Floto | AI + ピクセルパーフェクト比較 |

### 商用プラットフォーム

| ツール | 特徴 |
|---|---|
| Applitools Eyes | Visual AI。Figma Plugin。Root Cause Analysis |
| Percy (BrowserStack) | App Percyでモバイル対応 |
| Chromatic | Storybook統合 |
| LambdaTest SmartUI | AI + Layout比較 |
| Widgetbook Cloud | Flutter専用。Figma Reviews |
| Screenshotbot | Flutter Golden Test連携 |
