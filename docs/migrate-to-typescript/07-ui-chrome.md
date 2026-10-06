# 07 — UI クローム（ToolPalette / ColorPresetPanel / ActionBar / ZoomControl / Toast / ショートカット / テーマ）

## 目的

`Sources/Kakico/UI.swift`（526 行）と `Sources/Kakico/Theme.swift`（210 行）を Preact + CSS カスタムプロパティに移植し、macOS 版と視覚的に一致するアプリクロームを完成させる。メニューバーの代替としてキーボードショートカットを `src/keyboard/shortcuts.ts` に一本化する。この時点で「画像を開く → 注釈 → クロップ → エクスポート」のフル操作が、Mac 版と同じ見た目・同じキー操作で行えるようになる。

## 前提

- `02-project-setup.md` 完了（`theme.css` の基本トークン、ドットグリッド背景、EmptyState の骨格、ESLint 境界ルール）。
- `03-model.md` 完了（`RGBAColor`、`integral`（geometry.ts）、`outputRectFor`（document.ts））。
- `05-state-controller.md` 完了（`canvasStore` の `tool / strokeColor / strokeWidth / selection / toast / exportBounds / effectiveZoomScale / isEditingText / dirty`、アクション `setTool / selectStrokeColor / setStrokeWidth / undo / redo / canUndo / canRedo / flashToast`、画像 open / PNG ダウンロードエクスポート）。
- `06-canvas-interactions.md` 完了（`applyCrop / cancelCanvas 相当の cancelCrop / zoomIn / zoomOut / zoomToFit / setZoom / beginInteraction / commitInteraction`、テキスト編集オーバーレイ）。

## 作成・変更ファイル

すべて `kakico-web/` 配下。

| パス | 種別 | 内容 |
|---|---|---|
| `src/ui/theme.css` | 変更 | 全テーマトークン確定（§定数・仕様表のとおり）、パネル/タイル/ボタン/ポップオーバーのクラス、dark / reduced-motion 対応 |
| `src/ui/icons.tsx` | 新規 | オリジナル SVG アイコンセット（SF Symbols の置き換え） |
| `src/ui/chrome.tsx` | 新規（01 のツリーへの追加、ui/ 層内なので境界違反なし） | 共有プリミティブ: `FloatingPanel` / `TileButton` / `PrimaryButton` / `SecondaryButton` / `PaletteDivider` |
| `src/ui/App.tsx` | 変更 | ContentView 相当のレイアウト（オーバーレイ配置）に置き換え |
| `src/ui/ToolPalette.tsx` | 新規 | 左フローティングパレット（8 ツール + スウォッチ + 線幅ボタン） |
| `src/ui/ColorPresetPanel.tsx` | 新規 | Skitch 風 8 プリセット + `<input type="color">` フォールバック |
| `src/ui/StrokeWidthPopover.tsx` | 新規 | 線幅ポップオーバー + `MiroSlider` 移植 |
| `src/ui/ActionBar.tsx` | 新規 | 右上: Undo/Redo（web 追加）+ ドラッグアウト枠（08 で実装）+ コピー + エクスポート |
| `src/ui/CropActionBar.tsx` | 新規 | 下部中央 Apply Crop / Cancel |
| `src/ui/ZoomControl.tsx` | 新規 | ズーム % + プリセットメニュー + Fit |
| `src/ui/ImageSizeBadge.tsx` | 変更 | `W × H` バッジ（クロップ保留中は元サイズ併記）。ファイルは 05 で新規作成済み、ラベルは 05 の `imageSizeLabel` を再利用。本ステップでは正規スタイル適用のみ |
| `src/ui/Toast.tsx` | 新規 | 下部中央カプセルトースト |
| `src/ui/ConfirmDialog.tsx` | 新規 | `<dialog>` ベースの破棄確認（NSAlert 相当） |
| `src/ui/EmptyState.tsx` | 変更 | ボタン配線（Open / Paste）と正規スタイル適用 |
| `src/keyboard/shortcuts.ts` | 新規 | capture-phase keydown ディスパッチャ（Cmd/Ctrl マッピング込み） |
| `src/main.tsx` | 変更 | `installShortcuts()` の呼び出し |
| `tests/ui/*.test.tsx`, `tests/keyboard/shortcuts.test.ts` | 新規 | §テスト参照 |

dev dependency 追加: `@testing-library/preact`、`happy-dom`（未導入の場合。インストールコマンドと `test.projects` 設定は §18）。ランタイム依存は増やさない。

## 実装手順

### 1. `theme.css` — トークン確定

`Theme.swift` のトークンを `--kk-` プレフィックスで 1:1 定義（§定数・仕様表に全値）。トークン名は 02 の theme.css が定めた kebab-case（`--kk-miro-board` など。01 §9「Theme.swift のトークン名と 1:1 対応」— Swift の camelCase 名を CSS 慣習の kebab-case へ機械変換したもの）をそのまま使う。セマンティックトークンは `prefers-color-scheme: dark` で切り替える。

```css
:root {
  /* raw tokens (Theme.swift:8-29) */
  --kk-miro-board: #F5F5F7;
  --kk-miro-grid: #D7D7DE;
  --kk-miro-surface-gray: #F1F1F4;
  --kk-miro-surface-pressed: #E6E6EB;
  --kk-miro-divider: #E3E3E8;
  --kk-miro-dark-board: #202024;
  --kk-miro-dark-grid: #38383F;
  --kk-miro-dark-surface2: #313138;
  --kk-miro-ink: #050038;
  --kk-miro-text-secondary: #6B6B7B;
  --kk-miro-dark-text-primary: #ECECEF;
  --kk-miro-yellow: #FFD02F;
  --kk-miro-blue: #4262FF;
  --kk-miro-success: #2EA56A;

  /* semantic (MiroTheme, Theme.swift:38-56) — light */
  --kk-board: var(--kk-miro-board);
  --kk-grid: var(--kk-miro-grid);
  --kk-text-primary: var(--kk-miro-ink);
  --kk-text-secondary: var(--kk-miro-text-secondary);
  --kk-surface: var(--kk-miro-surface-gray);
  --kk-surface-pressed: var(--kk-miro-surface-pressed);
  /* 02 の .kk-panel の式を変数化。--kk-board 経由で dark に自動追従するため dark 側の再定義は不要 */
  --kk-material-bg: color-mix(in srgb, var(--kk-board) 78%, transparent);
  /* NSColor.textBackgroundColor の近似。engine/textEditor.ts（06 §7）がインラインテキストエディタの
     背景に alpha 0.9 で使用（CanvasView.swift:660）— 例: color-mix(in srgb, var(--kk-text-background) 90%, transparent) */
  --kk-text-background: #FFFFFF;

  /* typography (Theme.swift:61-64; semibold=600, bold=700) */
  --kk-font-family: system-ui, -apple-system, "Segoe UI", Roboto, "Helvetica Neue", sans-serif;
  --kk-font-body: 400 16px/1.35 var(--kk-font-family);
  --kk-font-control: 600 15px/1.2 var(--kk-font-family);
  --kk-font-button: 700 15px/1.2 var(--kk-font-family);
  --kk-font-caption: 600 12px/1.2 var(--kk-font-family);

  /* radii */
  --kk-radius-swatch: 7px;    /* UI.swift:197 */
  --kk-radius-button: 10px;   /* Theme.swift:123,141 */
  --kk-radius-tile: 11px;     /* Theme.swift:159, UI.swift:138 */
  --kk-radius-panel: 16px;    /* Theme.swift:196 */

  /* elevation (Theme.swift:191-198; SwiftUI shadow radius 16 ≈ CSS blur 32px) */
  --kk-shadow-panel: 0 14px 32px rgba(0, 0, 0, 0.22);
  --kk-panel-border: color-mix(in srgb, var(--kk-miro-divider) 50%, transparent);
}

@media (prefers-color-scheme: dark) {
  :root {
    --kk-board: var(--kk-miro-dark-board);
    --kk-grid: var(--kk-miro-dark-grid);
    --kk-text-primary: var(--kk-miro-dark-text-primary);
    /* Theme.swift:51 — dark の secondary は #6B6B7B ではなく darkTextPrimary の 65% */
    --kk-text-secondary: color-mix(in srgb, var(--kk-miro-dark-text-primary) 65%, transparent);
    --kk-surface: var(--kk-miro-dark-surface2);
    --kk-surface-pressed: var(--kk-miro-dark-grid);
    --kk-text-background: #1E1E1E;  /* NSColor.textBackgroundColor (dark) の近似 */
  }
}
```

ボード背景 + ドットグリッド（Theme.swift:71,85 — 28pt タイル、左上に 1.5×1.5 のドット。ウィンドウ固定でパン・ズームに追従しない）:

```css
.kk-board {
  position: fixed;
  inset: 0;
  background-color: var(--kk-board);
  background-image: radial-gradient(circle at 0.75px 0.75px,
      var(--kk-grid) 0.75px, transparent 0.75px);
  background-size: 28px 28px;
}
```

フローティングパネルクロームと reduced-motion:

```css
.kk-panel {
  padding: 8px;
  border-radius: var(--kk-radius-panel);
  background: var(--kk-material-bg);
  backdrop-filter: blur(20px) saturate(1.8);
  -webkit-backdrop-filter: blur(20px) saturate(1.8);
  box-shadow: var(--kk-shadow-panel), inset 0 0 0 1px var(--kk-panel-border);
}
.kk-panel--capsule { border-radius: 9999px; }   /* Toast 用 Capsule */

@media (prefers-reduced-motion: reduce) {
  .kk-board *, .kk-board { transition: none !important; animation: none !important; }
}
```

### 2. `icons.tsx` — オリジナル SVG アイコン

SF Symbols は使用不可（Apple ライセンス）。すべて 24×24 viewBox の `stroke="currentColor"`, `stroke-width="1.8"`, `fill="none"`, `stroke-linecap="round"`, `stroke-linejoin="round"` で自作する（fill 指定のものは個別記載）。

```tsx
export type IconName =
  | 'select' | 'arrow' | 'line' | 'rectangle' | 'ellipse' | 'text' | 'pixelate' | 'crop'
  | 'lineweight' | 'copy' | 'export' | 'share' | 'undo' | 'redo'
  | 'check-circle' | 'chevron-down' | 'photo-empty';

export function Icon(props: { name: IconName; size?: number }): JSX.Element;
// size 省略時 20。svg に width/height={size}, aria-hidden="true" を付与。
```

| name | 元 SF Symbol | 描画内容（オリジナル作画の指示） |
|---|---|---|
| `select` | cursorarrow | マウスカーソル型の矢印ポインタ輪郭（左上から右下へ） |
| `arrow` | arrow.up.right | 左下→右上の斜め矢印（線 + 先端の V 字ヘッド） |
| `line` | line.diagonal | 左下 (5,19) → 右上 (19,5) の 1 本線 |
| `rectangle` | rectangle | 角丸 2px の横長矩形輪郭 (4,6)-(20,18) |
| `ellipse` | circle | 中心 (12,12) 半径 8 の円輪郭 |
| `text` | textformat | 大文字 T（横棒 (6,6)-(18,6) + 縦棒 (12,6)-(12,18)） |
| `pixelate` | squareshape.split.3x3 | 3×3 グリッド（外枠矩形 + 内部の縦横各 2 本線） |
| `crop` | crop | クロップフレーム（左上向き L と右下向き L の交差） |
| `lineweight` | lineweight | 太さの異なる横線 3 本（stroke-width 1 / 2.5 / 4、上から細→太） |
| `copy` | doc.on.clipboard | クリップボード + 前面に重なる書類 |
| `export` | square.and.arrow.down | 下向き矢印 + 下辺の受け皿（上辺が開いた矩形） |
| `share` | square.and.arrow.up | 上向き矢印 + 下の箱（08 のドラッグアウト枠用。今回定義のみ） |
| `undo` | —（web 追加） | 左へ曲がる円弧矢印 |
| `redo` | —（web 追加） | `undo` の左右反転 |
| `check-circle` | checkmark.circle.fill | 塗り円（`fill="currentColor"`）+ 白抜きチェック |
| `chevron-down` | chevron.down | 下向き山形 1 本 |
| `photo-empty` | photo.on.rectangle.angled | 写真フレーム + 山と太陽のモチーフ（EmptyState 用、56px で表示） |

### 3. `chrome.tsx` — 共有プリミティブ

```tsx
export function FloatingPanel(props: { class?: string; capsule?: boolean; children: ComponentChildren }): JSX.Element;
// <div class="kk-panel"> ラッパ。capsule 時は kk-panel--capsule + padding は呼び出し側指定（Toast）。

export function TileButton(props: {
  label: string;            // title 属性（ツールチップ）+ aria-label
  size: 40 | 36;            // palette=40 / actionbar=36 (UI.swift:133-138, 337)
  iconSize: 20 | 16;
  selected?: boolean;       // ツールタイルの選択状態
  disabled?: boolean;
  onClick: () => void;
  children: ComponentChildren; // Icon
}): JSX.Element;

export function PrimaryButton(props: { title: string; label?: string; onClick: () => void }): JSX.Element;
export function SecondaryButton(props: { title: string; onClick: () => void }): JSX.Element;
export function PaletteDivider(props: { width: 28 | 22; verticalPadding: 4 | 2 }): JSX.Element;
// 高さ 1px、背景 var(--kk-miro-divider) (UI.swift:142-147)
```

対応 CSS（ホバー/押下は §定数・仕様表「状態スタイル」の値）:

```css
.kk-tile {
  display: grid; place-items: center;
  border: 0; background: transparent; color: var(--kk-text-secondary);
  border-radius: var(--kk-radius-tile);
  transition: background-color 0.12s ease-out, transform 0.15s ease-out;
}
.kk-tile:hover:not(:disabled) { background: var(--kk-surface); }
.kk-tile:active:not(:disabled) { background: var(--kk-surface-pressed); transform: scale(0.96); }
.kk-tile:disabled { opacity: 0.4; }
.kk-tile--selected { background: var(--kk-miro-yellow); color: var(--kk-miro-ink); }
.kk-tile--selected:hover { background: var(--kk-miro-yellow); }  /* 選択中はホバー変化なし */

.kk-btn-primary {
  font: var(--kk-font-button); color: var(--kk-miro-ink);
  padding: 10px 20px; background: var(--kk-miro-yellow);
  border: 0; border-radius: var(--kk-radius-button);
  transition: transform 0.15s ease-out;
}
.kk-btn-primary:active { transform: scale(0.98); }
.kk-btn-secondary { /* 同上、font: var(--kk-font-control); color: var(--kk-text-primary); background: var(--kk-surface); */ }
```

### 4. `App.tsx` — ContentView レイアウト（UI.swift:30-84）

```tsx
export function App() {
  const s = useStore();
  const hasDoc = s.document !== null;
  return (
    <div class="kk-board">
      {hasDoc ? <CanvasMount /> : <EmptyState />}
      {hasDoc && <div class="kk-overlay-palette"><ToolPalette /></div>}
      {hasDoc && <div class="kk-overlay-actionbar"><ActionBar /></div>}
      {hasDoc && s.document!.crop && <div class="kk-overlay-cropbar"><CropActionBar /></div>}
      {hasDoc && (
        <div class="kk-overlay-bottomright">
          <ZoomControl />
          <ImageSizeBadge />
        </div>
      )}
      {s.toast && <Toast message={s.toast.message} />}
    </div>
  );
}
```

配置 CSS（UI.swift:41-79 の値をそのまま）:

```css
.kk-canvas-mount { position: absolute; inset: 24px 24px 24px 76px; } /* leading 76 / trailing 24 / vertical 24 */
.kk-overlay-palette { position: absolute; left: 16px; top: 50%; transform: translateY(-50%); }
.kk-overlay-actionbar { position: absolute; top: 16px; right: 16px; }
.kk-overlay-cropbar { position: absolute; bottom: 20px; left: 50%; transform: translateX(-50%); }
.kk-overlay-bottomright { position: absolute; bottom: 16px; right: 16px; display: flex; gap: 8px; align-items: center; }
.kk-overlay-toast { position: absolute; bottom: 24px; left: 50%; transform: translateX(-50%); pointer-events: none; }
```

表示アニメーション: クロップバーは opacity 0.12s ease-out、トーストは opacity + translateY(8px) 0.18s ease-out（UI.swift:78-83）。Preact ではマウント直後に `.kk-shown` クラスを付ける CSS トランジションで実現。

### 5. `ToolPalette.tsx`（UI.swift:152-232）

構造: 横並び `display:flex; gap:8px; align-items:center` — [パレットパネル] + [開いていれば ColorPresetPanel]。

パレットパネル（`FloatingPanel` 内 `display:flex; flex-direction:column; gap:4px`）、上から順に:

1. **8 ツールボタン** — `TOOLS`（`state/tool.ts`、Tool.swift の宣言順: select, arrow, line, rectangle, ellipse, text, pixelate, crop）を `TileButton size=40 iconSize=20` で描画。`selected = s.tool === t.id`。クリックで `setTool(t.id)`。tooltip/aria-label = `` `${t.label} (${t.shortcutKey.toUpperCase()})` `` 例 "Select (V)"。
2. **区切り線** — `PaletteDivider width=28 verticalPadding=4`。
3. **カラースウォッチボタン** — 40×40 タイル内に 22×22 の角丸 7px 矩形。塗り = 現在の `strokeColor`、枠 1px `--kk-miro-divider`。クリックで ColorPresetPanel の開閉をトグル（ローカル `useState`）。tooltip "Stroke color"。
4. **線幅ボタン** — `TileButton` + `Icon name="lineweight"`。tooltip "Stroke width"。StrokeWidthPopover を開く。

ColorPresetPanel は Mac 同様「開いたまま維持」（色選択やキャンバス操作で閉じない）ため、ポップオーバーではなく flex の兄弟要素としてインライン描画する。出現トランジション: `transform: scale(0.95); transform-origin: left center; opacity: 0` → 1、0.1s ease-out（UI.swift:164-167）。

RGBAColor → CSS 変換ヘルパ（`ui/` 内に置く。model へは追加しない）:

```ts
export function cssColor(c: RGBAColor): string {
  const to255 = (v: number) => Math.round(v * 255);
  return `rgba(${to255(c.r)}, ${to255(c.g)}, ${to255(c.b)}, ${c.a})`;
}
```

### 6. `ColorPresetPanel.tsx`（UI.swift:285-329）

```ts
export const COLOR_PRESETS: ReadonlyArray<{ readonly name: string; readonly color: RGBAColor }> = [
  { name: 'Red',    color: { r: 0.90, g: 0.16, b: 0.22, a: 1 } },
  { name: 'Orange', color: { r: 0.98, g: 0.55, b: 0.10, a: 1 } },
  { name: 'Yellow', color: { r: 1.0,  g: 0.80, b: 0.0,  a: 1 } },
  { name: 'Green',  color: { r: 0.16, g: 0.70, b: 0.30, a: 1 } },
  { name: 'Blue',   color: { r: 0.0,  g: 0.48, b: 1.0,  a: 1 } },
  { name: 'Pink',   color: { r: 0.96, g: 0.40, b: 0.68, a: 1 } },
  { name: 'White',  color: { r: 1,    g: 1,    b: 1,    a: 1 } },
  { name: 'Black',  color: { r: 0,    g: 0,    b: 0,    a: 1 } },
];
```

順序は **White が Black より先**（UI.swift:289-292 のとおり。RGBAColor の宣言順とは異なる）。

- 各スウォッチ: `FloatingPanel` 内 `flex-direction:column; gap:6px; padding:2px`。ボタン = 直径 22px の円（塗り = プリセット色、枠 1px `--kk-miro-divider`）+ 周囲 3px パディング。選択リング: `rgbaEquals(s.strokeColor, preset.color)`（r/g/b/a の厳密一致）のとき外周に 2px の `--kk-miro-blue` 円環。ホバー/押下の背景フィルなし（Mac は `.plain`）。tooltip = 色名。クリックで `selectStrokeColor(preset.color)`。
- 区切り線: `PaletteDivider width=22 verticalPadding=2`。
- **ピッカーフォールバック**: `<input type="color" title="Custom color…">`。`input` イベントで hex → RGBAColor（a=1）に変換し `setStrokeColor(color)`（Mac の直接代入経路。`selectStrokeColor` ではない — UI.swift:296-297。05 の 500ms デバウンス合流が効く）。表示は 22×22 円にクリップ（`input[type=color]` を `appearance:none` + 円形 `clip-path` でスタイル）。制約: HTML の color input はアルファ非対応 → a は常に 1（Mac は `supportsOpacity: true`。許容する差分として記録）。

### 7. `StrokeWidthPopover.tsx`（UI.swift:208-281）

線幅ボタンに `popovertarget` を付け、native Popover API（`popover="auto"`）で開く。位置決め: CSS Anchor Positioning は Chrome 限定のため、`toggle` イベントで JS 配置 — アンカー右端 + 8px、垂直中央揃え（Mac の `arrowEdge: .trailing` 相当）。

中身: `padding:12px` の `FloatingPanel` 内に `flex; gap:8px` — `Icon name="lineweight"`（`--kk-text-secondary`）+ `MiroSlider`。

`MiroSlider`（カスタムスライダー、UI.swift:238-281 の数式を厳守）:

```tsx
interface MiroSliderProps {
  value: number;
  range: readonly [number, number];   // [1, 40]
  width: number;                      // 140
  onChange(value: number): void;
  onEditingChanged(editing: boolean): void;
}
const KNOB = 16;   // px (UI.swift:242)
const TRACK = 4;   // px (UI.swift:243)
```

- ジオメトリ: `span = upper - lower`; `clamped = min(max(value, lower), upper)`; `fraction = span > 0 ? (clamped - lower) / span : 0`; `usable = width - KNOB`。
- トラック: 全幅カプセル（高さ 4px、`--kk-miro-divider`）。フィル: 幅 `KNOB / 2 + fraction * usable` のカプセル（`--kk-miro-blue`）。
- ノブ: 白い 16×16 円、枠 `rgba(0,0,0,0.12)` 0.5px、影 `0 0.5px 1px rgba(0,0,0,0.25)`、`translateX(fraction * usable)`。
- 入力: `pointerdown` で `setPointerCapture` + `onEditingChanged(true)`、move/down で `x = min(max(0, offsetX - KNOB / 2), usable)`; `f = usable > 0 ? x / usable : 0`; `onChange(lower + f * span)`。`pointerup` で `onEditingChanged(false)`。連続値（スナップなし）。
- 配線: `onEditingChanged(true)` → `beginInteraction()`、`(false)` → `commitInteraction()`（ドラッグ全体を 1 undo ステップに合流）。`onChange` → `setStrokeWidth(v)`。範囲 **1–40**、幅 **140**。

### 8. `ActionBar.tsx`（UI.swift:333-362）

`FloatingPanel` 内 `flex; gap:4px`。タイルは `TileButton size=36 iconSize=16`、`disabled = !hasDocument`。並び順（左→右）:

1. **Undo タイル**（web 追加）— `Icon name="undo"`、tooltip "Undo (⌘Z)"、`disabled = !canUndo`、クリックで `undo()`。
2. **Redo タイル**（web 追加）— tooltip "Redo (⇧⌘Z)"、`disabled = !canRedo`、`redo()`。
3. `PaletteDivider` の縦向き変種（幅 1px、高さ 24px）。
4. **ドラッグアウト枠のスロット** — 08 で `platform/dragOut.ts` と接続。本ステップでは 36×36 の `Icon name="share"` タイルを `disabled` 固定で置く。tooltip "Drag out to share as PNG"。
5. **コピー** — `Icon name="copy"`、tooltip "Copy image to clipboard"。props `onCopy?: () => void` 未指定なら `disabled`（08 で配線）。
6. **エクスポート** — `Icon name="export"`、tooltip "Export image"。05 の PNG ダウンロードアクションを配線（08 でピッカー付きに差し替え）。

Undo/Redo タイルは Mac 版に存在しない（Edit メニューのみ）。PWA にはメニューバーがないため、その代替としてここに置く。**Mac 版との視覚差分として 10-parity-checklist に「意図的な差分」と記録すること。** Mac との厳密一致比較時はこの 2 タイル + 区切り線を除外して比較する。

Export Bounds 切り替え（Mac: File メニューの "Expand to Fit Annotations" / "Clip at Image Boundary"）は 08 のエクスポートフローに置くため本ステップでは UI を作らない。

### 9. `CropActionBar.tsx`（UI.swift:368-384）

`FloatingPanel` 内 `flex; gap:8px`:

- `PrimaryButton title="Apply Crop"` → `applyCrop()`。tooltip "Apply the crop (Return)"。
- プレーンな "Cancel" ボタン — `font: var(--kk-font-control)`、色 `--kk-text-secondary`、padding 10px 12px、背景なし → `cancelCrop()`。tooltip "Cancel the crop (Esc)"。

表示条件は App.tsx 側（`document.crop != null`）。

### 10. `ZoomControl.tsx`（UI.swift:390-416）

- トリガーボタン: `FloatingPanel` 内、`flex; gap:3px` — store 由来の `zoomPercentText`（05 §3）のテキスト（`font: var(--kk-font-caption)`、色 `--kk-text-secondary`）+ `Icon name="chevron-down" size={8}`。tooltip "Zoom"。
- ズーム % ラベルは **store 経由**で取得する。`ui/` は `engine/` を import できない（02 の ESLint 境界ルール3。例外は CanvasMount.tsx のみ）ため、`engine/zoomMath.ts` の `percentLabel` を直接呼ばず、`CanvasStore` が公開する派生値 `zoomPercentText`（= `percentLabel(effectiveZoomScale)` を store 側で算出。05 §3）を表示する。
- メニュー: native Popover API（`popover="auto"`）。JS 配置でボタン上端 − 8px に下端を揃え右端揃え。項目:
  1. プリセット `[0.25, 0.5, 1.0, 2.0, 4.0]`（ZoomMath.swift:14）の各項目。ラベルはハードコード文字列 `'25%' '50%' '100%' '200%' '400%'`（`engine/` を import しないため。プリセット値と表示の対応は 05 の ZoomMath テストが担保）。クリックで `setZoom(preset)` + 閉じる。
  2. 区切り線。
  3. "Fit to Window" → `zoomToFit()`。
- メニュー項目スタイル: `font: var(--kk-font-control)`、hover で `--kk-surface` フィル、`role="menu"` / `role="menuitem"`。

### 11. `ImageSizeBadge.tsx`（UI.swift:422-441）

ラベル生成関数は 07 で重複定義しない。05 が `state/canvasStore.ts` に公開する純関数 `imageSizeLabel(document, bounds)`（05 §11）をそのまま再利用する（`ui/` → `state/` の import は境界ルール適合）:

```ts
import { imageSizeLabel } from '../state/canvasStore';
// imageSizeLabel(document: Document, bounds: ExportBounds): string
//   = integral(outputRectFor(document, bounds)) を "W × H"（区切りは U+00D7、値は Math.trunc）で整形。
//     pending crop 中（document.crop !== null）は元サイズを " (origW × origH)" で併記。
//   ※ integral は geometry.ts、outputRectFor は document.ts（03-model.md）。
```

`ImageSizeBadge.tsx` は 05 で新規作成済み。本ステップは上記ラベルを右下 `FloatingPanel` に表示するスタイル適用のみ（= 変更）。表示: `font: var(--kk-font-caption)`、色 `--kk-text-secondary`。値は**画像ピクセル（モデル空間）**で、現在の `exportBounds` を反映する。

### 12. `Toast.tsx`（UI.swift:90-104）

- `FloatingPanel capsule` 内 `flex; gap:8px; padding:10px 16px` — `Icon name="check-circle"`（色 `--kk-miro-success`）+ メッセージ（`font: var(--kk-font-control)`、色 `--kk-text-primary`）。
- ラッパに `pointer-events: none`（クリックはキャンバスへ素通し）。
- 自動消滅はストア側 `flashToast`（1.8 秒、CanvasController.swift:58-64）が担う。コンポーネントは `s.toast` の有無で描画するだけ。`toast.id` を key にして連続表示でもトランジションが再生されるようにする。

### 13. `EmptyState.tsx` 配線（UI.swift:108-126）

- 中央 `flex-direction:column; gap:16px; align-items:center`、全面（`position:absolute; inset:0`）:
  1. `Icon name="photo-empty" size={56}`、色 `--kk-text-secondary`。
  2. テキスト **"Open or drop an image to start annotating"**（verbatim）、`font: var(--kk-font-body)`、色 `--kk-text-secondary`。
  3. `flex; gap:12px` — `PrimaryButton title="Open Image…"`（U+2026）→ `platform/files.ts` の open（05 実装）; `SecondaryButton title="Paste from Clipboard"` → `navigator.clipboard.read()` があれば読み取り、なければ `flashToast('Press ⌘V to paste')`（08 で `platform/clipboard.ts` に置換）。

### 14. `ConfirmDialog.tsx`（NSAlert 置換、ExportService.swift:72-80）

```ts
export function confirmDiscard(
  message: string,       // 見出し
  info: string,          // 説明文
  confirmTitle: string,  // 破壊的確認ボタン
): Promise<boolean>;     // confirm = true / Cancel = false（08-io-export.md と同じ位置引数シグネチャ）
```

- `<dialog>` を動的生成して `showModal()`。ボタンは [confirmTitle]（`PrimaryButton` 相当）と ["Cancel"]（`SecondaryButton` 相当）。Esc = Cancel（dialog の `cancel` イベント）。
- 08 で使う文字列（本ステップで定数としてエクスポート）:
  - 貼り付け置換: message **"Replace the current image?"** / info **"Pasting will replace the image you are editing. Unsaved annotations will be lost."** / confirm **"Replace"**（ExportService.swift:92-95）。
  - Mac の終了確認 "Quit Kakico?" は web では `beforeunload` ガード（08）に対応させるため移植しない。
- スタイル: `background: var(--kk-material-bg)` + blur、`border-radius: var(--kk-radius-panel)`、`::backdrop { background: rgba(0,0,0,0.3) }`。

### 15. `keyboard/shortcuts.ts` — ショートカット一本化

06 で `engine/input.ts` に仮置きした Return / Esc / Delete のキー処理がある場合はここへ移設し、**キーボード処理の入口を本モジュールの 1 リスナーに統一する**（textarea 内の Esc / Return は `textEditor.ts` が textarea 自身のイベントで処理するため対象外）。

```ts
export interface ShortcutHandlers {
  openImage(): void;
  openDocument?(): void;     // 08
  saveDocument?(): void;     // 08
  exportImage(): void;       // 05 の PNG ダウンロード → 08 で差し替え
  copyImage?(): void;        // 08
  pasteImage?(): void;       // 08 (⇧⌘V の明示ペースト)
}
export function installShortcuts(
  store: CanvasStore,
  handlers: ShortcutHandlers,
  opts?: { isMac?: boolean },   // テスト注入用
): () => void;                  // 解除関数
```

実装規則:

1. `window.addEventListener('keydown', onKeyDown, { capture: true })`（capture-phase。KakicoApp.swift のローカル NSEvent モニタ相当）。
2. **プライマリ修飾キー判定**（Cmd/Ctrl マッピング）:
   ```ts
   const isMac = opts?.isMac ??
     /Mac|iPhone|iPad/i.test(
       (navigator as { userAgentData?: { platform: string } }).userAgentData?.platform
         ?? navigator.platform);
   const mod = (e: KeyboardEvent) => (isMac ? e.metaKey : e.ctrlKey);
   // Mac では ctrlKey を、他 OS では metaKey を「押されていたら不成立」として扱う
   ```
3. **抑制条件**（Mac の「first responder が NSTextView なら素通し」相当）: `store.getSnapshot().isEditingText` が true、または `(e.target as Element).closest('input, textarea, select, [contenteditable="true"]')` が非 null なら即 return（何も consume しない）。
4. マッチしたら `e.preventDefault()` + `e.stopPropagation()`（表内 PD=yes のもの）。文字比較は `e.key.toLowerCase()`。
5. ⌘V は keydown で**扱わない**。`paste` イベント（05/08 実装）が唯一の経路（ブラウザのネイティブ paste 権限モデルに乗るため）。
6. ⌘W / ⌘N / ⌘T / ⌘Q はブラウザ予約でインターセプト不可。クローズ保護は 08 の `beforeunload`（`dirty` 時のみ）が担う。

**ショートカット表（完全版）:**

| Mac | Windows/Linux | 動作 | 条件 | preventDefault | Swift 原典 |
|---|---|---|---|---|---|
| V | V | `setTool('select')` | !isEditingText | no | Tool.swift:31 |
| A | A | `setTool('arrow')` | 同上 | no | Tool.swift:32 |
| L | L | `setTool('line')` | 同上 | no | Tool.swift:33 |
| R | R | `setTool('rectangle')` | 同上 | no | Tool.swift:34 |
| O | O | `setTool('ellipse')` | 同上 | no | Tool.swift:35 |
| T | T | `setTool('text')` | 同上 | no | Tool.swift:36 |
| P | P | `setTool('pixelate')` | 同上 | no | Tool.swift:37 |
| C | C | `setTool('crop')` | 同上 | no | Tool.swift:38 |
| 0–7（修飾なし） | 0–7 | `setTool(TOOLS[digit].id)`（0=select … 7=crop） | 修飾キーなし・!isEditingText | no | KakicoApp.swift:90-99 |
| ⌘Z | Ctrl+Z | `undo()` | canUndo | yes | KakicoApp.swift:240 |
| ⇧⌘Z | Ctrl+Shift+Z | `redo()` | canRedo | yes | KakicoApp.swift:243 |
| ⌘C | Ctrl+C | `copyImage()`（平坦化画像コピー） | hasDocument && selection === null。それ以外は素通し | consume 時のみ yes | KakicoApp.swift:76-84 |
| ⌘V | Ctrl+V | 画像貼り付け | keydown では扱わない — `paste` イベント経由 | — | KakicoApp.swift:64-71 |
| ⇧⌘V | Ctrl+Shift+V | `pasteImage()`（明示ペースト、clipboard.read） | handlers.pasteImage あり | yes | KakicoApp.swift:211 |
| ⌘O | Ctrl+O | `openImage()` | — | yes | KakicoApp.swift:205 |
| ⇧⌘O | Ctrl+Shift+O | `openDocument()`（.kakico） | handlers あり | yes | KakicoApp.swift:207 |
| ⌘S | Ctrl+S | `saveDocument()`（.kakico） | hasDocument && handlers あり | yes（ブラウザの「ページを保存」を抑止） | KakicoApp.swift:221 |
| ⌘E | Ctrl+E | `exportImage()` | hasDocument | yes | KakicoApp.swift:224 |
| ⇧⌘C | Ctrl+Shift+C | `copyImage()` | hasDocument | yes | KakicoApp.swift:227 |
| ⌘+ (`=` / `+`) | Ctrl+`=` / `+` | `zoomIn()` | hasDocument | yes（ページズーム抑止） | KakicoApp.swift:251 |
| ⌘− (`-`) | Ctrl+`-` | `zoomOut()` | hasDocument | yes | KakicoApp.swift:254 |
| ⌘0 | Ctrl+0 | `zoomToFit()` | hasDocument | yes | KakicoApp.swift:257 |
| Return | Enter | `applyCrop()` | document.crop != null | yes | UI.swift:374 (help) / CanvasView |
| Esc | Esc | crop あり → `cancelCrop()`; なければ選択解除 | — | consume 時のみ | UI.swift:381 (help) / CanvasView |
| Delete / Backspace | Delete / Backspace | 選択要素の削除 | selection !== null | yes | CanvasView（06 で移植済みのアクション） |
| ⌘W | — | 移植不可（ブラウザ予約）。`beforeunload` ガードで代替（08） | — | — | KakicoApp.swift:218 |

### 16. `main.tsx` 更新

`installShortcuts(store, { openImage, exportImage })` をマウント後に 1 回呼ぶ。返り値の解除関数は HMR dispose で呼ぶ。

### 17. アクセシビリティ最低線

- 全アイコンボタンに `aria-label`（tooltip と同文言）、ツールタイルに `aria-pressed={selected}`。
- パレット/アクションバーのコンテナに `role="toolbar"` + `aria-label="Tools"` / `"Actions"`。
- SVG は `aria-hidden="true"`。フォーカスリングを消さない（`:focus-visible` に `outline: 2px solid var(--kk-miro-blue)`）。

### 18. Vitest projects — happy-dom 環境（`tests/ui`, `tests/keyboard`）

02 の `vite.config.ts` は `test.environment: 'node'` のみ、04 は `tests/render/**/*.browser.test.ts` 用の browser project を `test.projects` に追加した。07 の UI/キーボードテストは DOM（`@testing-library/preact` の `render`/`fireEvent`）を要するため、`test.projects` に happy-dom の `ui` エントリを追加し、同じ glob を node project の include から除外する（二重実行の防止）。

devDependency 追加:

```bash
npm i -D happy-dom @testing-library/preact
```

`vite.config.ts` の `test.projects` へ追記（04 で projects 化済み。既存 node / browser エントリは保持）:

```ts
test: {
  projects: [
    {
      test: {
        name: 'node',
        environment: 'node',
        include: ['tests/**/*.test.{ts,tsx}'],
        // 07: UI/keyboard は happy-dom project へ回すため node からは除外
        exclude: ['tests/ui/**/*.test.{ts,tsx}', 'tests/keyboard/**/*.test.ts'],
      },
    },
    // …04 で追加した browser project（tests/render/**/*.browser.test.ts）…
    {
      test: {
        name: 'ui',
        environment: 'happy-dom',
        include: ['tests/ui/**/*.test.{ts,tsx}', 'tests/keyboard/**/*.test.ts'],
      },
    },
  ],
},
```

## 定数・仕様表

### カラートークン（sRGB。Swift の 0–1 値 → hex 換算済み）

| CSS 変数 | 値 | Swift 原典 |
|---|---|---|
| `--kk-miro-board` | `#F5F5F7` | Theme.swift:8 |
| `--kk-miro-grid` | `#D7D7DE` | Theme.swift:9 |
| `--kk-miro-surface-gray` | `#F1F1F4` | Theme.swift:10 |
| `--kk-miro-surface-pressed` | `#E6E6EB` | Theme.swift:11 |
| `--kk-miro-divider` | `#E3E3E8` | Theme.swift:12 |
| `--kk-miro-dark-board` | `#202024` | Theme.swift:15 |
| `--kk-miro-dark-grid` | `#38383F` | Theme.swift:16 |
| `--kk-miro-dark-surface2` | `#313138` | Theme.swift:17 |
| `--kk-miro-ink` | `#050038` | Theme.swift:20 |
| `--kk-miro-text-secondary` | `#6B6B7B` | Theme.swift:21 |
| `--kk-miro-dark-text-primary` | `#ECECEF` | Theme.swift:22 |
| `--kk-miro-yellow` | `#FFD02F` | Theme.swift:25 |
| `--kk-miro-blue` | `#4262FF` | Theme.swift:26（選択クローム用 NSColor も同値、Theme.swift:33-34） |
| `--kk-miro-success` | `#2EA56A` | Theme.swift:29 |

### セマンティックトークン（light / dark）

| CSS 変数 | light | dark | Swift 原典 |
|---|---|---|---|
| `--kk-board` | `#F5F5F7` | `#202024` | Theme.swift:39-41 |
| `--kk-grid` | `#D7D7DE` | `#38383F` | Theme.swift:42-44 |
| `--kk-text-primary` | `#050038` | `#ECECEF` | Theme.swift:45-47 |
| `--kk-text-secondary` | `#6B6B7B` | `#ECECEF` の 65% 不透明 | Theme.swift:48-52 |
| `--kk-surface`（ホバー） | `#F1F1F4` | `#313138` | Theme.swift:53-55 / Theme.swift:167-170 |
| `--kk-surface-pressed` | `#E6E6EB` | `#38383F` | Theme.swift:163-166 |
| `--kk-material-bg` | `color-mix(in srgb, var(--kk-board) 78%, transparent)` | 同左（`--kk-board` 経由で dark に自動追従） | `.regularMaterial` の近似（Theme.swift:191）。§1・02 の `.kk-panel` と一致。**02 の暫定値 `rgba(…, 0.72)` を上書き**（正典は color-mix 78%） |
| `--kk-text-background` | `#FFFFFF` | `#1E1E1E` | `NSColor.textBackgroundColor` の近似（CanvasView.swift:660、alpha 0.9 適用）。engine/textEditor.ts（06 §7）がインラインテキストエディタ背景に消費 |

### タイポグラフィ

| CSS 変数 | 値 | Swift 原典 |
|---|---|---|
| `--kk-font-body` | 400 16px | Theme.swift:61 |
| `--kk-font-control` | 600 15px | Theme.swift:62 |
| `--kk-font-button` | 700 15px | Theme.swift:63 |
| `--kk-font-caption` | 600 12px | Theme.swift:64 |

### 角丸・影・グリッド

| 項目 | 値 | Swift 原典 |
|---|---|---|
| `--kk-radius-swatch` | 7px | UI.swift:197 |
| `--kk-radius-button` | 10px | Theme.swift:123,141 |
| `--kk-radius-tile` | 11px | Theme.swift:159 / UI.swift:138 |
| `--kk-radius-panel` | 16px | Theme.swift:196 |
| パネル影 | `0 14px 32px rgba(0,0,0,0.22)`（SwiftUI radius 16, y 14 → CSS blur ≈ 2×radius） | Theme.swift:191-193 |
| パネル枠線 | 1px、`--kk-miro-divider` の 50% 不透明 | Theme.swift:198 |
| パネル内パディング | 8px（Toast/プリセットは個別指定） | Theme.swift:195 |
| ドットグリッド | 28px タイル、タイル左上に 1.5×1.5px ドット、ウィンドウ固定 | Theme.swift:71,85 |
| バックドロップ | `blur(20px) saturate(1.8)`（`.regularMaterial` 近似、web 側決定値） | Theme.swift:191 |

### 状態スタイル（hover / active / disabled / selected）

| 対象 | 状態 | 値 | Swift 原典 |
|---|---|---|---|
| タイルボタン | hover | 背景 `--kk-surface`（light `#F1F1F4` / dark `#313138`） | Theme.swift:167-170 |
| タイルボタン | pressed | 背景 `--kk-surface-pressed`（light `#E6E6EB` / dark `#38383F`）+ `scale(0.96)` | Theme.swift:163-166,177 |
| タイルボタン | disabled | `opacity: 0.4`（Mac の自動ディム相当。DragOutWell は alpha 0.3 — UI.swift:475） | — |
| ツールタイル | selected | 背景 `--kk-miro-yellow`、アイコン `--kk-miro-ink`、hover 変化なし | UI.swift:181-185 |
| Primary/Secondary ボタン | pressed | `scale(0.98)`（hover 効果なし — Mac に存在しない） | Theme.swift:105-107 |
| プリセットスウォッチ | selected | 外周 2px `--kk-miro-blue` リング（r/g/b/a 厳密一致時） | UI.swift:310-313 |
| ばね近似 | — | `transition: transform 0.15s ease-out`（spring(0.25, 0.7) の近似。reduced-motion で無効） | Theme.swift:106-107 |

### レイアウト定数

| 項目 | 値 | Swift 原典 |
|---|---|---|
| キャンバスインセット | left 76 / right 24 / top・bottom 24 | UI.swift:41-43 |
| パレット左オフセット | 16（垂直中央） | UI.swift:50-51 |
| ActionBar オフセット | top/right 16、タイル間 gap 4 | UI.swift:57,337 |
| CropActionBar | bottom 20、gap 8、Cancel padding 10px 12px | UI.swift:63,372,379-380 |
| Zoom+バッジ | bottom/right 16、gap 8 | UI.swift:68,72 |
| Toast | bottom 24、padding 10px 16px、gap 8、出現 translateY(8px)+opacity 0.18s | UI.swift:78-79,83,94,101 |
| クロップバー出現 | opacity 0.12s ease-out | UI.swift:82 |
| ツール選択切替 | 0.12s ease-out | UI.swift:177 |
| プリセットパネル出現 | scale 0.95（origin left）+ opacity、0.1s ease-out | UI.swift:164-167 |
| パレットタイル | 40×40、アイコン 20px | UI.swift:133-137 |
| ActionBar タイル | 36×36、アイコン 16px | UI.swift:357 |
| パレット縦 gap | 4、区切り線 幅28/pad4（パレット）・幅22/pad2（プリセット） | UI.swift:171,192,320 |
| スウォッチ | 22×22 角丸 7、枠 1px divider、40×40 タイル内 | UI.swift:197-202 |
| プリセット円 | 直径 22 + pad 3、リング 2px、縦 gap 6、パネル pad 2 | UI.swift:300-315,326 |
| スライダー | 幅 140、ノブ 16、トラック 4、範囲 1–40、ポップオーバー pad 12 | UI.swift:220-224,242-243,227 |
| EmptyState | アイコン 56px、縦 gap 16、ボタン gap 12 | UI.swift:112-119 |
| ズームプリセット | `[0.25, 0.5, 1.0, 2.0, 4.0]` | ZoomMath.swift:14 |
| ズームラベル | store の `zoomPercentText`（= `Math.round(scale * 100) + '%'`、05 §3） | ZoomMath.swift:17-19 |
| chevron | 8px 相当 | UI.swift:404-405 |
| トースト表示時間 | 1.8 s（ストア側） | CanvasController.swift:62 |
| 最小ウィンドウ相当 | 720×520（web では最小レイアウト検証幅として使用） | KakicoApp.swift:22 |

### 文字列（verbatim）

| 用途 | 文字列 |
|---|---|
| EmptyState 本文 | `Open or drop an image to start annotating` |
| EmptyState ボタン | `Open Image…`（U+2026） / `Paste from Clipboard` |
| クロップバー | `Apply Crop` / `Cancel` |
| ズームメニュー | `25%` `50%` `100%` `200%` `400%` / `Fit to Window` |
| tooltip | `Select (V)` ほかツール 8 種 / `Stroke color` / `Stroke width` / 色名 8 種 / `Custom color…` / `Drag out to share as PNG` / `Copy image to clipboard` / `Export image` / `Apply the crop (Return)` / `Cancel the crop (Esc)` / `Zoom` |
| 置換確認 | `Replace the current image?` / `Pasting will replace the image you are editing. Unsaved annotations will be lost.` / `Replace` / `Cancel` |
| トースト | `Copied to clipboard`（ExportService.swift:41、08 で使用） |
| サイズバッジ | `W × H` / `W × H (origW × origH)`（区切りは U+00D7、値は `Math.trunc`） |

## 受け入れ基準

- [ ] `cd kakico-web && npx tsc --noEmit && npx eslint . && npx vitest run && npx vite build` がすべて成功。
- [ ] 「作成・変更ファイル」の全パスが存在する（`ls` で確認）。
- [ ] `grep -c -- '--kk-miro-' src/ui/theme.css` が 14 以上（raw トークン全定義）。
- [ ] `grep -n 'FFD02F\|4262FF\|050038\|2EA56A\|E3E3E8' src/ui/theme.css` で 5 色すべてヒット（値の書き間違い検出）。
- [ ] `grep -rn 'sf-symbols\|SF Pro\|apple.com' src/ui/icons.tsx` がゼロ件（オリジナル SVG のみ）。
- [ ] `npm run dev` で画像を開き、Mac 版 `build/Kakico.app`（`bash scripts/build-app.sh` でビルド）とスクリーンショットを並べて比較: パレット位置（左端 16px・垂直中央）、選択ツールの黄色タイル、右上アクションバー、右下ズーム%+サイズバッジの並びが一致（ActionBar の Undo/Redo + 区切り線のみ意図的差分）。
- [ ] プリセットパネル: スウォッチを上から Red, Orange, Yellow, Green, Blue, Pink, White, Black の順で表示。DevTools で各円の背景色が `rgb(230,41,56) / rgb(250,140,26) / rgb(255,204,0) / rgb(41,179,77) / rgb(0,122,255) / rgb(245,102,173) / rgb(255,255,255) / rgb(0,0,0)`。
- [ ] プリセットパネルは色選択・キャンバス操作をしても開いたまま。スウォッチボタン再クリックで閉じる。
- [ ] 線幅ポップオーバー: スライダーを 1→40 にドラッグして選択中要素の線幅がライブ更新され、ドラッグ全体が ⌘Z 1 回で戻る（begin/commitInteraction 合流）。
- [ ] キーボード: `v a l r o t p c` と `0`–`7` でツール切替、テキスト編集中は無効。`Mod+Z` / `Shift+Mod+Z` で undo/redo。`Mod+0` / `Mod+=` / `Mod+-` でズーム操作かつブラウザのページズームが発動しない。
- [ ] Windows/Linux（または `opts.isMac=false` の手動確認）: Ctrl 系で同一動作。
- [ ] クロップ保留中のみ下部バーが表示され、Return で適用・Esc でキャンセル。サイズバッジが `W × H (origW × origH)` 形式になる。
- [ ] トーストが 1.8 秒で自動消滅し、表示中もキャンバスをクリックできる（pointer-events: none）。
- [ ] DevTools の Rendering → prefers-color-scheme: dark でダークテーマに切り替わる（ボード `#202024`、テキスト `#ECECEF`、パネルがダーク材質）。
- [ ] Rendering → prefers-reduced-motion: reduce でトランジションが無効化される。
- [ ] EmptyState の本文・ボタン文言が §文字列と一字一句一致（`…` は U+2026）。
- [ ] 全アイコンボタンに `title` と `aria-label` があり、Tab フォーカスで `--kk-miro-blue` のフォーカスリングが見える。

## テスト

配置: `tests/ui/`、`tests/keyboard/`。環境は happy-dom（§18 で追加する `vite.config.ts` の `test.projects` の `ui` エントリに従う）。`@testing-library/preact` の `render`/`fireEvent` を使用。

| ファイル | テスト名 | アサーション |
|---|---|---|
| `tests/ui/toolPalette.test.tsx` | `renders 8 tool buttons in Tool.allCases order` | aria-label が `Select (V)`, `Arrow (A)`, …, `Crop (C)` の順に 8 個 |
| 〃 | `clicking a tool tile sets store.tool` | Arrow タイルクリック → `store.getSnapshot().tool === 'arrow'` |
| 〃 | `only the active tool tile has selected style` | `aria-pressed="true"` が現在ツールのタイルにのみ付く |
| 〃 | `swatch button toggles ColorPresetPanel` | クリックでパネル出現、再クリックで消滅 |
| `tests/ui/colorPresetPanel.test.tsx` | `presets match Swift order and values` | `COLOR_PRESETS` が Red…Pink, White, Black の順で §6 の RGBA 値と deep-equal |
| 〃 | `clicking a preset calls selectStrokeColor` | Blue クリック → strokeColor が `{r:0, g:0.48, b:1, a:1}` |
| 〃 | `selection ring only on exact color match` | strokeColor を Red に設定 → Red スウォッチのみリング要素を持つ |
| 〃 | `color input sets strokeColor directly with a=1` | input へ `#ff0000` を fire → strokeColor `{r:1,g:0,b:0,a:1}`（selectStrokeColor 経由でないことをスパイで確認） |
| `tests/ui/miroSlider.test.ts` | `fill width formula` | value=1,width=140 → fill 幅 8px; value=40 → 132px（`KNOB/2 + fraction*(width-KNOB)`） |
| 〃 | `drag math clamps and maps` | offsetX=0 → value 1; offsetX=148 → value 40; 中央 70 → `1 + (62/124)*39` |
| 〃 | `onEditingChanged brackets a drag` | pointerdown で `(true)` 1 回、pointerup で `(false)` 1 回 |
| `tests/ui/sizeBadge.test.ts` | `renders imageSizeLabel without crop` | 800×600 doc → 表示テキスト `"800 × 600"`（U+00D7 を charCode で確認）。ラベル生成の単体テストは 05 の `canvasStore.test.ts`（`imageSizeLabel`） |
| 〃 | `renders pending-crop label` | crop 400×300 + expandToFit → `"400 × 300 (800 × 600)"` |
| `tests/ui/zoomControl.test.tsx` | `label reflects store.zoomPercentText` | effectiveZoomScale=0.333 → `"33%"`; 2.0 → `"200%"` |
| 〃 | `menu lists 5 presets then Fit to Window` | 項目文言が `25% 50% 100% 200% 400%` + `Fit to Window` |
| `tests/ui/cropActionBar.test.tsx` | `visible only while doc.crop exists` | crop=null → 非描画; crop 設定 → `Apply Crop` と `Cancel` を描画 |
| `tests/ui/toast.test.tsx` | `toast auto-dismisses after 1.8s` | fake timers: `flashToast('x')` → 描画 → `advanceTimersByTime(1800)` → 消滅 |
| 〃 | `toast is click-through` | ラッパの computed `pointer-events` が `none` |
| `tests/ui/emptyState.test.tsx` | `verbatim copy` | 本文とボタン 2 つの textContent が §文字列と厳密一致 |
| `tests/keyboard/shortcuts.test.ts` | `letter keys select tools` | `keydown 'a'` → tool `'arrow'`; `'c'` → `'crop'` |
| 〃 | `digit keys map Tool.allCases order` | `'0'` → select, `'3'` → rectangle, `'7'` → crop |
| 〃 | `suppressed while editing text` | isEditingText=true で `'a'` → tool 不変; textarea を target にした `'a'` も不変 |
| 〃 | `mod+z / shift+mod+z` | isMac=true で metaKey+z → undo 呼び出し + defaultPrevented; shift 付き → redo |
| 〃 | `ctrl mapping on non-mac` | isMac=false で ctrlKey+z → undo、metaKey+z → 何もしない |
| 〃 | `mod+c consumes only when nothing selected` | selection=null → copyImage 呼び出し + defaultPrevented; selection あり → 未呼び出し + !defaultPrevented |
| 〃 | `mod+0 / mod+= / mod+- zoom with preventDefault` | zoomToFit/zoomIn/zoomOut が呼ばれ defaultPrevented=true |
| 〃 | `Return applies crop, Esc cancels` | doc.crop あり: Enter → applyCrop; Esc → cancelCrop |
| 〃 | `uninstall removes listener` | 解除関数呼び出し後 `'a'` → tool 不変 |
