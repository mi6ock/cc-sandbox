# DESIGN.md テンプレート

プロジェクトルートに配置し、LLMがUI実装時に参照するデザインルールファイル。
プロジェクトに合わせてカスタマイズすること。

---

# Design System

## Widget選択ルール

### カード風UI（角丸 + 影 + 背景色）

```dart
// OK: Card Widget を使う
Card(
  elevation: 2,
  shape: RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(12),
  ),
  child: Padding(
    padding: EdgeInsets.all(16),
    child: ...,
  ),
)

// NG: Container + BoxDecoration で模倣しない
Container(
  decoration: BoxDecoration(
    color: Colors.white,
    borderRadius: BorderRadius.circular(12),
    boxShadow: [...],
  ),
)
```

Figmaで角丸 + 影 + 背景色のフレームは `Card` Widget を使う。
ただし Card の elevation で表現できない複雑な影（複数影、内側影）の場合のみ
`Container + BoxDecoration` を使う。

### リスト項目

```dart
// OK: ListTile を使う（テキスト + アイコン/アバターの標準レイアウト）
ListTile(
  leading: Icon(Icons.person),
  title: Text('タイトル'),
  subtitle: Text('サブタイトル'),
  trailing: Icon(Icons.chevron_right),
)

// カスタムレイアウトが必要な場合のみ Row/Column で構築
```

### ボタン

```dart
// OK: Material ボタンを使う
ElevatedButton(onPressed: ..., child: Text('ボタン'))
OutlinedButton(onPressed: ..., child: Text('ボタン'))
TextButton(onPressed: ..., child: Text('ボタン'))
IconButton(onPressed: ..., icon: Icon(Icons.add))

// NG: GestureDetector + Container で模倣しない
```

### アイコン

```dart
// Material Icons がある場合
Icon(Icons.search, size: 24, color: Theme.of(context).iconTheme.color)

// カスタムSVGアイコンの場合
SvgPicture.asset('assets/icons/custom_icon.svg', width: 24, height: 24)
```

**Figmaにアイコンがあるのに実装で省略するのは禁止。**

## デザイントークン

### 色

```dart
// Theme.of(context) 経由でアクセスする
// ハードコードしない

final colorScheme = Theme.of(context).colorScheme;
colorScheme.primary      // プライマリカラー
colorScheme.surface      // カード・シートの背景
colorScheme.onSurface    // テキスト色
colorScheme.outline       // ボーダー色
```

### 角丸

| 用途 | 値 |
|------|-----|
| カード | 12px |
| ボタン | 8px |
| チップ | 16px |
| 入力フィールド | 8px |
| ボトムシート | 16px (上部のみ) |

### 影（Elevation）

| 用途 | elevation |
|------|-----------|
| カード（通常） | 1 |
| カード（浮き上がり） | 4 |
| ボトムナビゲーション | 8 |
| ダイアログ | 16 |
| FAB | 6 |

### スペーシング

| トークン名 | 値 |
|-----------|-----|
| xs | 4px |
| sm | 8px |
| md | 16px |
| lg | 24px |
| xl | 32px |

## Figmaプロパティ → Flutter 変換ルール

### AutoLayout

| Figma | Flutter |
|-------|---------|
| layoutMode: VERTICAL | `Column` |
| layoutMode: HORIZONTAL | `Row` |
| layoutWrap: WRAP | `Wrap` |
| itemSpacing: N | `spacing` パラメータ（SizedBoxではなく） |
| paddingTop/Bottom/Left/Right | `EdgeInsets` |
| primaryAxisAlignItems: SPACE_BETWEEN | `MainAxisAlignment.spaceBetween` |
| counterAxisAlignItems: CENTER | `CrossAxisAlignment.center` |

### サイズ制約

| Figma | Flutter |
|-------|---------|
| layoutSizingHorizontal: FILL（親がRow） | `Expanded(child: ...)` |
| layoutSizingHorizontal: FILL（親がColumn） | `width: double.infinity` |
| layoutSizingVertical: HUG | サイズ指定なし |
| layoutSizingVertical: FIXED | `height: 固定値` |

### 装飾

| Figma | Flutter |
|-------|---------|
| cornerRadius: N（均一） | `BorderRadius.circular(N)` |
| rectangleCornerRadii: [a,b,c,d] | `BorderRadius.only(topLeft: ..., ...)` |
| effects[DROP_SHADOW]{offset,blur,spread,color} | `BoxShadow(offset: Offset(x,y), blurRadius: blur, spreadRadius: spread, color: ...)` |
| effects[INNER_SHADOW] | Flutter非対応。代替: `ShaderMask` or カスタムペイント |
| strokes + strokeWeight（均一） | `Border.all(width: N, color: ...)` |
| individualStrokeWeights | `Border(top: BorderSide(...), ...)` |
| fills[SOLID] | `Color(0xAARRGGBB)` |
| fills[GRADIENT_LINEAR] | `LinearGradient(begin: ..., end: ..., colors: [...])` |
| fills[IMAGE] | `DecorationImage(image: ..., fit: BoxFit.cover)` |

### テキスト

| Figma | Flutter |
|-------|---------|
| fontFamily | `fontFamily: 'ファミリー名'` |
| fontSize | `fontSize: N` |
| fontWeight | `fontWeight: FontWeight.wN00` |
| lineHeight (PIXELS) | `height: lineHeight / fontSize` |
| letterSpacing | `letterSpacing: N` |
| textAlignHorizontal: CENTER | `textAlign: TextAlign.center` |
