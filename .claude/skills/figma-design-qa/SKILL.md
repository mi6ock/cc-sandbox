---
name: figma-design-qa
description: >
  FigmaデザインからUIを実装する際に、細部の精度を担保するためのスキル。
  以下の場合に必ずこのスキルを使用すること:
  - Figmaデザインからコードを実装する時
  - UIの見た目がデザインと合っているか確認する時
  - 「Figma」「デザイン通り」「ピクセルパーフェクト」「UI実装」に言及がある時
  - スクリーンショットとデザインの差分を確認する時
---

# Figma Design QA

Figmaデザインの細部を正確に実装し、実装結果を検証するワークフロー。

## なぜこのスキルが必要か

マルチモーダルLLMには画像認識の物理的限界がある:
- 画像は内部で最大1,568pxにリサイズされる
- border幅(1px vs 2px)、border-radius(4px vs 8px)、shadow パラメータの区別はほぼ不可能
- padding/margin の正確な値（8px vs 12px）は画像から推測できない
- アイコンの欠落、Card/Container の選択ミスが頻発する

**スクリーンショットから推測してはいけない。構造化データの数値を使え。**

## Phase 1: デザインデータの取得

### Figma-Context-MCP を使う場合

Figma-Context-MCP は公式MCPと異なり、構造化YAMLで正確なプロパティ値を返す。
`get_design_context` の失敗→スクリーンショットフォールバック問題がない。

```
1. get_figma_data でノードの構造化YAMLを取得
2. borderRadius, effects(shadow), strokes, fills の数値を確認
3. download_figma_images でアイコン/画像アセットを取得
```

### Figma公式MCPを使う場合

`get_design_context` が失敗する場合がある（5-6kトークン超のコンテナ）。
失敗時は `get_metadata` + `get_variable_defs` を個別に取得し、
**`get_screenshot` にフォールバックしない**。

```
1. get_metadata でノードID・名前・タイプ・サイズを取得
2. get_variable_defs でデザイントークン（色・スペーシング）を取得
3. get_design_context で詳細スタイリングを取得（セクション単位で分割）
4. get_screenshot は「補助参照」としてのみ使用（数値の推測には使わない）
```

### どちらも使えない場合

Figma Raw プラグインでJSONエクスポートし、プロンプトに貼り付ける。
あるいは手動でプロパティ値を記述する。

## Phase 2: DESIGN.md の参照

プロジェクトルートの `DESIGN.md` を読み、以下を確認:
- 使用可能なWidget・コンポーネントの一覧
- デザイントークン（色、角丸、影、スペーシング）
- Widget選択ルール（Card vs Container 等）

**DESIGN.md が存在しない場合、Phase 2.5 でユーザーに作成を提案する。**

## Phase 3: コンポーネント単位での実装

**画面全体を一括で実装しない。コンポーネント単位に分割する。**

研究（DCGen, FSE 2025）により、分割実装で視覚的類似度が15%向上することが確認されている。

```
1. デザインをコンポーネント（カード、ヘッダー、リスト項目等）に分解
2. 各コンポーネントについて:
   a. Figmaの構造化データから数値を読み取る
   b. DESIGN.md のWidget選択ルールに従う
   c. コードを生成する
3. コンポーネントを組み合わせて画面を構築
```

### 実装時の必須チェック

各コンポーネント生成時に以下を自問する:

- [ ] **アイコン**: Figmaにアイコンがあるか？あればIcon/SvgPictureを使ったか？
- [ ] **角丸**: borderRadius の値はFigmaデータの数値と一致しているか？
- [ ] **影**: DROP_SHADOW のパラメータ（offset, blur, spread, color）を正確に変換したか？
- [ ] **ボーダー**: strokes の幅・色・位置（inside/center/outside）は正しいか？
- [ ] **パディング**: paddingTop/Bottom/Left/Right の値は一致しているか？
- [ ] **色**: fills の色はFigmaデータのHEX/RGBA値と一致しているか？推測していないか？
- [ ] **Widget選択**: DESIGN.md のルールに従っているか？（Card vs Container 等）

## Phase 4: 数値ベースの差分検証（反復修正）

スクリーンショットの目視比較ではなく、数値で検証する。

### 検証方法

1. **Widget Test でプロパティ抽出**:
   ```dart
   final decoration = tester.widget<Container>(find.byKey(Key('card')));
   final boxDeco = (decoration.decoration as BoxDecoration);
   // borderRadius, boxShadow, color, border を数値で取得
   ```

2. **Figmaスペックと数値比較**:
   ```
   { element: "Card", property: "borderRadius", figma: 12, actual: 8, diff: -4 }
   { element: "Card", property: "shadow.blur", figma: 8, actual: 0, diff: -8 }
   ```

3. **差分をLLMに伝えて修正**:
   「borderRadiusが12のはずが8になっている。修正して」
   「影のblurRadiusが8のはずが設定されていない。追加して」

### 反復ルール

- **最大5ラウンド**で収束させる
- Round 1 で約50%の差分を修正、Round 2 で累積75%
- **6ラウンド以降は逆効果**（正しい部分を壊すリスクが修正利益を超える）
- 収束しない場合はコンポーネントをさらに小さく分割する

## 参考: LLMの画像認識精度

| プロパティ | 画像からの認識精度 | 対策 |
|-----------|------------------|------|
| レイアウト（上下左右） | 高い | 画像参照OK |
| テキスト内容 | 高い | 画像参照OK |
| 正確なHEXカラー | 低い | **数値データ必須** |
| border幅 | 非常に低い | **数値データ必須** |
| border-radius | 低い | **数値データ必須** |
| box-shadow | 低い | **数値データ必須** |
| padding/margin | 低い | **数値データ必須** |
| アイコンの種類 | 中〜低 | **アセット名必須** |
