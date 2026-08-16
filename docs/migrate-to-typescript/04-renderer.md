# 04 — Renderer: AnnotationRender の Canvas 2D 移植

## 目的

`Sources/AnnotationRender/Renderer.swift` を純粋関数群 `src/render/` に移植する。画面描画とエクスポートが同一の `render()` を通る WYSIWYG 構造を維持し、6 種のアノテーション描画・テキスト折り返し・ピクセレート・flatten・PNG/JPEG エンコードを実装する。Canvas 2D はモデル空間と同じ y-down / top-left 原点なので、Swift 版の `withYFlip` 機構は全て削除する。

## 前提

- `02-project-setup.md` 完了(Vite + strict TS + vitest + ESLint 境界ルール)。
- `03-model.md` 完了。本ドキュメントは `src/model/` の以下を import する:
  - `geometry.ts`: `Point`, `Size`, `Rect`, `RGBAColor`, `FontSpec`
  - `elements.ts`: `SegmentElement`, `ShapeElement`, `TextElement`, `RedactionElement`, `arrowOutline()`
  - `annotation.ts`: `Annotation`, `ElementID`, `boundingBox()`
  - `document.ts`: `Document`, `ExportBounds`, `outputRectFor(doc, bounds)`
- Inter フォントのバンドルと `@font-face` 登録は**本ステップの手順 0 で行う**(02 は `public/fonts/inter/.gitkeep` の配置のみ)。

## 作成・変更ファイル

| パス | 内容 |
|---|---|
| `kakico-web/public/fonts/inter/Inter-Regular.woff2` ほか | Inter フォント本体(Regular / Bold)+ `LICENSE.txt`(手順 0) |
| `kakico-web/src/ui/theme.css` | `@font-face` 宣言 2 件を追記(手順 0) |
| `kakico-web/src/render/renderer.ts` | `render()` 本体 + 要素別描画 |
| `kakico-web/src/render/text.ts` | `wrapLines()` / `suggestedSize()` / `fontString()` / `TextMeasurer` |
| `kakico-web/src/render/effects.ts` | `drawPixelate()`(blur は判別子予約のみ、実装しない) |
| `kakico-web/src/render/flatten.ts` | `flatten()`(OffscreenCanvas 出力、256 MP ガード) |
| `kakico-web/src/render/encode.ts` | `encode()`(canvas → Blob) |
| `kakico-web/dev/preview.html` | dev 専用の目視確認ページ(ビルド対象外) |
| `kakico-web/src/dev/preview.ts` | ハードコード Document を描画するスクリプト |
| `kakico-web/tests/render/text.test.ts` | node 環境、スタブ measurer |
| `kakico-web/tests/render/renderer.browser.test.ts` | browser mode、実 Canvas |
| `kakico-web/tests/render/effects.browser.test.ts` | browser mode |
| `kakico-web/tests/render/flatten.browser.test.ts` | browser mode |
| `kakico-web/tests/render/encode.browser.test.ts` | browser mode |
| `kakico-web/vite.config.ts` | vitest projects に browser mode(playwright provider)を追加 |
| `kakico-web/package.json` | devDependencies: `@vitest/browser`, `playwright` |
| `.github/workflows/kakico-web-ci.yml` | 変更: Playwright ブラウザの install + `actions/cache`(手順 9) |

ESLint 境界: `src/render/` は `src/model/` のみ import 可。`document`/`window`/`navigator` への参照禁止(引数で受け取る ctx / ImageBitmap / OffscreenCanvas 型のみ許可)。

## 実装手順

### 0. Inter フォントの配置(`public/fonts/inter/` + `theme.css`)

`text.ts` の決定的計測とテキスト描画全体の前提。最初に行う。

1. [rsms/inter](https://github.com/rsms/inter) の GitHub リリースから公式配布物(SIL Open Font License 1.1)をダウンロードし、woff2 を 2 ウェイト分だけコミットする:
   - `public/fonts/inter/Inter-Regular.woff2`(weight 400)
   - `public/fonts/inter/Inter-Bold.woff2`(weight 700)
   - `public/fonts/inter/LICENSE.txt`(OFL 全文、配布物に同梱)
2. `src/ui/theme.css` に `@font-face` を 2 宣言追加する:

```css
@font-face {
  font-family: 'Inter';
  src: url('/fonts/inter/Inter-Regular.woff2') format('woff2');
  font-weight: 400;
  font-display: block;
}
@font-face {
  font-family: 'Inter';
  src: url('/fonts/inter/Inter-Bold.woff2') format('woff2');
  font-weight: 700;
  font-display: block;
}
```

§9 の browser テスト冒頭 `await document.fonts.load('bold 28px Inter')` はこの登録が前提。

### 1. 共通型とヘルパー(`renderer.ts`)

```ts
import type { Document, Annotation, ElementID, RGBAColor } from '../model';

export type Ctx2D = CanvasRenderingContext2D | OffscreenCanvasRenderingContext2D;

export interface RenderOptions {
  baseBitmap?: ImageBitmap;
  skipElement?: ElementID;   // 編集中テキストの非表示用(Swift に対応物なし、アーキ決定 §5)
}

export function cssColor(c: RGBAColor): string {
  return `rgba(${c.r * 255}, ${c.g * 255}, ${c.b * 255}, ${c.a})`;
}

function setStroke(ctx: Ctx2D, color: RGBAColor, width: number): void {
  ctx.strokeStyle = cssColor(color);
  ctx.lineWidth = width;
  ctx.lineCap = 'round';    // Renderer.swift:106
  ctx.lineJoin = 'round';   // Renderer.swift:107
}
```

明示的な負の仕様(実装してはならないもの):
- shadow 系(`shadowColor`/`shadowOffsetX/Y`/`shadowBlur`)は一切設定しない。Swift 版に `setShadow` 呼び出しは存在しない。
- テキストの縁取り(`strokeText`)・背景・ハイライターなし。
- stamp / blur は描画しない。codec の判別子予約のみ(03 で対応済み)。パリティ後の追加。
- 選択ハンドル・クロップオーバーレイ(マーチングアンツ・45% 減光)は renderer の責務外。06 の engine 層が画面上にのみ描く。エクスポートには決して含めない。

### 2. `render()` — 唯一の描画関数

```ts
export function render(
  doc: Document,
  ctx: Ctx2D,
  scale: number,
  opts?: RenderOptions,
): void;
```

セマンティクス(`Renderer.draw`、Renderer.swift:18-26 の移植):

1. `ctx.save()`; `ctx.scale(scale, scale)`。以後モデル座標(画像ピクセル空間)で描く。y 反転は不要 — Canvas 2D はモデル空間と同じ y-down。
2. `opts?.baseBitmap` があれば `ctx.drawImage(baseBitmap, 0, 0, doc.canvasSize.width, doc.canvasSize.height)`(rect にフィット、Renderer.swift:97-101 相当。y-flip 削除)。
3. `doc.elements` を配列順に描画(配列順 = 描画順、後勝ち)。`opts?.skipElement === element.id` の要素は skip。
4. `ctx.restore()`。

DPR / crop / pan は `render()` の関知外。呼び出し側(flatten、06 の CanvasHost)が事前に `ctx.translate` / `ctx.setTransform(dpr,…)` を設定する。`render()` 自体は `devicePixelRatio` を絶対に読まない。

### 3. 要素別描画(`renderer.ts` 内 private)

kind ごとの dispatch(Renderer.swift:74-83):

- **line** (`drawLine`): `setStroke(ctx, e.color, e.width)`; `beginPath → moveTo(start) → lineTo(end) → stroke()`。
- **arrow** (`drawArrow`): `arrowOutline(e)`(model 側、03 で移植済みの 6 点ポリゴン)。空配列なら何も描かない(length ≤ 0.5)。`fillStyle = cssColor(e.color)`; moveTo(第 1 点) → 各点 lineTo → `closePath()` → `fill()`(既定 nonzero)。**stroke は一切しない**(塗りポリゴンのみ)。
- **rectangle** (`drawRect`): `e.fill` が非 undefined なら先に `fillStyle = cssColor(e.fill)`; `fillRect(e.rect)`。次に `setStroke(ctx, e.color, e.width)`; `strokeRect(e.rect)`。ストロークは辺の中心線に width/2 ずつ内外に乗る(Canvas 既定 = CG 既定と同じ)。
- **ellipse** (`drawEllipse`): rect に内接する楕円。`ctx.ellipse(rect.x + w/2, rect.y + h/2, w/2, h/2, 0, 0, 2 * Math.PI)`。fill(あれば)→ stroke の順、rectangle と同様。
- **text** (`drawText`): §4 参照。`e.string === ''` なら何も描かない。
- **pixelate**: `drawPixelate(ctx, e.rect, e.amount, opts?.baseBitmap, doc.canvasSize)`(§5、`effects.ts`)。

### 4. テキスト(`text.ts`)— 単一の折り返しアルゴリズム

CoreText の代替。ここで定義する関数群は 06 の textarea エディタと**必ず共有**する(折り返し不一致の防止、アーキ決定 §6)。

```ts
export interface TextMeasurer {
  /** fontString(font) を適用した状態での text の advance width (px) */
  measure(text: string, font: FontSpec): number;
}

/** ctx.measureText ベースの実装。render() が内部で生成。 */
export function canvasMeasurer(ctx: Ctx2D): TextMeasurer;

export function fontString(font: FontSpec): string;
export function lineHeight(font: FontSpec): number;
export function wrapLines(str: string, width: number, font: FontSpec, m: TextMeasurer): string[];
export function suggestedSize(e: TextElement, m: TextMeasurer): Size;
```

**フォント解決** (`fontString`): 判定的メトリクスのためバンドル Inter を唯一の実フォントとする。

```ts
const FONT_FAMILY_MAP: Record<string, string> = { 'Helvetica Neue': 'Inter' };
// fontString: `${bold ? 'bold ' : ''}${pointSize}px ${css族}`
// css族 = `"${mapped}", "Helvetica Neue", Helvetica, Arial, sans-serif`
```

**行メトリクス定数**(Inter の hhea テーブル値。unitsPerEm 2048、ascender 1984、descender −494):

```ts
export const TEXT_ASCENT_RATIO = 0.96875;                       // 1984 / 2048
export const TEXT_DESCENT_RATIO = 0.24121;                      // 494 / 2048 (丸め)
export const LINE_HEIGHT_RATIO = TEXT_ASCENT_RATIO + TEXT_DESCENT_RATIO; // 1.20996
// lineHeight(font) = font.pointSize * LINE_HEIGHT_RATIO
```

ブラウザの `fontBoundingBox*` は環境依存なので使わない。定数計算のみで行送りを決める(決定性優先。Swift 版は CoreText の Helvetica Neue メトリクスだったため数 px の差は許容 — web 内で renderer とエディタが一致することが要件)。

**`wrapLines` アルゴリズム**(貪欲法):

1. `str.split('\n')` でハード改行分割。空行は `''` として 1 行出力。
2. 各ハード行を `' '` で語分割し、貪欲に詰める: `candidate = current === '' ? word : current + ' ' + word`; `m.measure(candidate, font) <= width` なら継続、超えたら `current` を確定して `word` から新行。
3. 単語単体が `width` を超える場合は文字単位で分割(1 行最低 1 文字 — 無限ループ防止)。
4. 戻り値は折り返し済み行の配列。トリムしない(空白は保持)。

**`wrapLines` のメモ化(必須)**: `render()` は 06 の Layer B で毎フレーム(pan / zoom / ドラッグ / ants tick ごと)全テキストを描画するため、無メモ化だと語ごとの `measureText` が O(総単語数)/フレームで走る。モジュールレベルの `Map<string, string[]>` に `` `${fontString(font)}|${width}|${str}` `` をキーとして結果をキャッシュし、エントリ数上限 512(超過時は `Map` の挿入順先頭から削除)。measurer が同一フォント登録下で決定的であることが前提(手順 0 の同梱 Inter)。テスト用に `clearWrapCache()` を export する。

**`suggestedSize`**(Renderer.swift:169-179 の移植):

```ts
if (e.string === '') return { width: e.size.width, height: e.font.pointSize + 8 };
const lines = wrapLines(e.string, e.size.width, e.font, m);
const h = Math.max(Math.ceil(lines.length * lineHeight(e.font)) + 2, e.font.pointSize + 8);
return { width: e.size.width, height: h };   // width は折り返し制約 — 絶対に変えない
```

**`drawText`**(renderer.ts):

1. `ctx.font = fontString(e.font)`; `ctx.fillStyle = cssColor(e.color)`; `ctx.textBaseline = 'alphabetic'`; `ctx.textAlign = 'left'`。
2. `lines = wrapLines(e.string, e.size.width, e.font, canvasMeasurer(ctx))`。
3. 行 `i` のベースライン `y = e.origin.y + i * lineHeight + e.font.pointSize * TEXT_ASCENT_RATIO`。
4. **オーバーフロー行は破棄**(CTFrame と同じ drop 挙動): `(i + 1) * lineHeight <= e.size.height + 0.5` を満たす行のみ `ctx.fillText(line, e.origin.x, y)`。アプリ層は編集のたび `suggestedSize` で箱を広げるので通常は全行描画される。

### 5. ピクセレート(`effects.ts`)— ブロック平均化

```ts
export function drawPixelate(
  ctx: Ctx2D,
  rect: Rect,
  amount: number,
  base: ImageBitmap | undefined,
  canvasSize: Size,
): void;
```

アルゴリズム(縮小→拡大方式。縮小時の drawImage がボックスフィルタ相当のブロック平均を行う):

1. **フォールバック**: `base` が無い、または `rect.width <= 1 || rect.height <= 1` なら `fillStyle = 'rgba(128, 128, 128, 1)'` で `fillRect(rect)` して終了(Renderer.swift:194-198。0.5 × 255 = 127.5 → 128)。
2. `blockSize = Math.max(2, amount)`(Renderer.swift:207)。
3. **キャンバス固定グリッドへスナップ**(アーキ決定 §6 — Swift の rect 中心アンカー CIPixellate からの意図的変更。ドラッグ中にブロックが揺れない):

```ts
const gx0 = Math.max(0, Math.floor(rect.x / blockSize) * blockSize);
const gy0 = Math.max(0, Math.floor(rect.y / blockSize) * blockSize);
const gx1 = Math.min(canvasSize.width,  Math.ceil((rect.x + rect.width)  / blockSize) * blockSize);
const gy1 = Math.min(canvasSize.height, Math.ceil((rect.y + rect.height) / blockSize) * blockSize);
if (gx1 <= gx0 || gy1 <= gy0) { /* 手順1のグレー塗りにフォールバック */ return; }
const cols = Math.max(1, Math.ceil((gx1 - gx0) / blockSize));
const rows = Math.max(1, Math.ceil((gy1 - gy0) / blockSize));
```

4. **縮小(= ブロック平均)**: スクラッチ用 `OffscreenCanvas` を**モジュールレベルで 1 枚保持して使い回す**(render は毎フレーム走るため、呼び出しごとの `new OffscreenCanvas` は pixelate 要素 × フレーム数の確保 = GC 圧になる)。現在サイズが `cols × rows` に満たないときだけ拡大リサイズ(grow-only)、`sctx.clearRect(0, 0, cols, rows)` で使用領域を消去してから `sctx.imageSmoothingEnabled = true; sctx.imageSmoothingQuality = 'high'`; `sctx.drawImage(base, gx0, gy0, gx1 - gx0, gy1 - gy0, 0, 0, cols, rows)`(clearRect は base に透過がある場合の前回描画の残留防止に必須)。**ソースは base 画像のみ** — 先に描かれたアノテーションはサンプルしない(Renderer.swift:201。pixelate の下の注釈は base のピクセレートで置き換わって見える)。
5. **拡大(ブロック復元)**: `ctx.save(); ctx.beginPath(); ctx.rect(rect.x, rect.y, rect.width, rect.height); ctx.clip(); ctx.imageSmoothingEnabled = false; ctx.drawImage(small, 0, 0, cols, rows, gx0, gy0, cols * blockSize, rows * blockSize); ctx.restore()`。クリップにより rect 外へはみ出さない。端の部分ブロックは端の平均値が伸びる(CIPixellate の `clampedToExtent` 相当の不透明エッジ)。

CIImage の y-flip 変換(Renderer.swift:202-203)は不要 — 全て y-down で完結。ブロックの色は縮小 drawImage の補間結果であり CIPixellate と厳密一致しないため、テストは「ブロック内の全ピクセルが同一色」「グリッドがキャンバス固定」を検証する(色値の完全一致は求めない)。

blur: 実装しない。`ctx.filter = 'blur(Npx)'` + 3×radius パディング方式をパリティ後に追加(アーキ決定 §6)。`effects.ts` に TODO コメントのみ。

### 6. `flatten()`(`flatten.ts`)— Renderer.swift:29-58 の移植

```ts
export const MAX_PIXEL_COUNT = 256 * 1024 * 1024;   // 268435456

export function flatten(
  doc: Document,
  baseBitmap: ImageBitmap | null,
  scale = 1,
  bounds: ExportBounds = 'clipToImage',
): OffscreenCanvas | null;
```

1. `out = outputRectFor(doc, bounds)`(model 側、03 §5。`clipToImage` → `crop ?? 全キャンバス`、`expandToFit` → 全要素 boundingBox との union を `.integral`)。
2. `pixelW = Math.round(out.width * scale)`; `pixelH = Math.round(out.height * scale)`。
3. ガード: `pixelW > 0 && pixelH > 0 && pixelW <= MAX_PIXEL_COUNT && pixelH <= MAX_PIXEL_COUNT && pixelW * pixelH <= MAX_PIXEL_COUNT` でなければ `null`(Renderer.swift:35-36 と同一。次元チェックもピクセル数定数を流用する点まで同じ)。
4. `canvas = new OffscreenCanvas(pixelW, pixelH)`; `ctx = canvas.getContext('2d')!`。y 反転 CTM(Swift 版 46-49 行)は**全部不要**。
5. `bounds === 'expandToFit'` なら `ctx.fillStyle = 'rgba(255, 255, 255, 1)'; ctx.fillRect(0, 0, pixelW, pixelH)`(Renderer.swift:51-54。ビットマップ全域 = out 矩形なので等価)。`clipToImage` は透明のまま。
6. `ctx.translate(-out.x * scale, -out.y * scale)`; `render(doc, ctx, scale, { baseBitmap: baseBitmap ?? undefined })`。
7. `canvas` を返す。

画面側(06 の CanvasHost)も同じ `flatten`/`render` を使う。画面は Swift 同様 `doc.crop = null` のコピーを描き、クロップ中オーバーレイは engine が別描画。

### 7. `encode()`(`encode.ts`)— Renderer.swift:61-70 の移植

```ts
export type EncodeType = 'image/png' | 'image/jpeg';

export async function encode(
  canvas: OffscreenCanvas,
  type: EncodeType,
  jpegQuality = 0.9,
): Promise<Blob>;
```

- `canvas.convertToBlob({ type, quality: type === 'image/jpeg' ? jpegQuality : undefined })`。
- `convertToBlob` 非対応環境向けフォールバック: 同サイズの hidden `HTMLCanvasElement` に転写して `toBlob`(このフォールバック関数のみ DOM 依存を許可、`encode.ts` 内に隔離しコメントで明示)。
- ESLint 対応: このフォールバックの `document.createElement` は 02 の境界ルール(`src/render/**` で `no-restricted-globals` により `document` 禁止)に抵触するため、該当行に `// eslint-disable-next-line no-restricted-globals` を付ける(または `eslint.config.js` に `encode.ts` のフォールバック関数のみ許可する override を追加する)。これがないと受け入れ基準の `npx eslint` が通らない。
- 失敗時は reject(Swift の nil 返しに相当。呼び出し側でトースト)。

### 8. dev プレビューページ(`dev/preview.html` + `src/dev/preview.ts`)

- `EndToEndArtifactTest.swift` と同一構成のハードコード Document を描画する(base はチェッカーパターンをコードで生成)。値は Swift テストと厳密一致させる:
  - arrow: start (80,320) → end (250,150)、red、width 8
  - rectangle: rect (300,60,200,150)、blue、width 6、fill なし
  - ellipse: rect (60,60,200,140)、green、width 6
  - line: (60,240) → (540,240)、yellow、width 5
  - text: origin (70,20)、size 400×40、`"Kakico — native arm64"`、pointSize 30、bold、black
  - pixelate: rect (100,250,120,80)、amount 14
- `flatten` 結果を `<img>` に、`render` 直描きを `<canvas>` に並べて表示。`expandToFit`/`clipToImage`/crop(40,10,480,360) の切り替えボタン付き。
- vite の追加エントリとして `dev/preview.html` を dev サーバでのみ提供(`vite build` の `rollupOptions.input` に含めない)。

### 9. vitest browser mode の設定

`vite.config.ts` の `test.projects` に追加:

```ts
{
  test: {
    name: 'browser',
    include: ['tests/render/**/*.browser.test.ts'],
    browser: { enabled: true, provider: 'playwright', headless: true,
               instances: [{ browser: 'chromium' }] },
  },
}
```

- node プロジェクト側は `tests/render/**/*.browser.test.ts` を exclude。
- browser テストは冒頭で `await document.fonts.load('bold 28px Inter')` を実行(フォント未ロードでの計測ブレ防止)。
- **CI 更新(必須)**: 本ステップから CI の `vitest run` が chromium を要求する。02 の `kakico-web-ci.yml` は `npm ci` のみでブラウザ install が無いため、そのままでは browser プロジェクトが落ちる。`npm ci` の直後に以下を追加する(ブラウザ ~150 MB を毎 run ダウンロードしないよう `actions/cache` とセット):

```yaml
      - name: Cache Playwright browsers
        uses: actions/cache@v4
        with:
          path: ~/.cache/ms-playwright
          key: playwright-${{ runner.os }}-${{ hashFiles('kakico-web/package-lock.json') }}
      - run: npx playwright install --with-deps chromium
        # キャッシュヒット時はブラウザ再ダウンロードがスキップされ OS deps のみ入る
```
- ピクセル検証ヘルパーを `tests/render/helpers.ts` に用意: `samplePixel(canvas, x, y): [r,g,b,a]`(`getImageData`)、`pixelHash(canvas): string`、`solidBitmap(w, h, cssColor): Promise<ImageBitmap>`、`topRedBottomBlueBitmap(w, h)`。

## 定数・仕様表

| 項目 | 値 | Swift 参照 |
|---|---|---|
| maxPixelCount | `256 * 1024 * 1024` = 268435456(各次元・総数とも) | Renderer.swift:35-36 |
| flatten 出力サイズ | `Math.round(out.width * scale)` × `Math.round(out.height * scale)` | Renderer.swift:33-34 |
| flatten 既定 bounds | `'clipToImage'` | Renderer.swift:31 |
| expandToFit 背景 | 不透明白 (1,1,1,1) を全域塗り | Renderer.swift:51-54 |
| clipToImage 背景 | 透明(塗らない) | Renderer.swift:51(条件外) |
| jpegQuality 既定 | `0.9`(PNG では無視) | Renderer.swift:61 |
| lineCap / lineJoin | `'round'` / `'round'`(line, rect, ellipse の全ストローク) | Renderer.swift:106-107 |
| ストローク位置 | パス中心(Canvas 既定 = CG 既定) | Renderer.swift:140,149 |
| arrow 描画 | 塗りポリゴンのみ、stroke なし | Renderer.swift:122-132 |
| arrow 長さ下限 | `length > 0.5` でなければ何も描かない | Elements.swift:41 |
| arrow shaftHalf | `max(1, width * 0.5)` | Elements.swift:46 |
| arrow headHalf | `max(shaftHalf * 2.4, width * 1.8)` | Elements.swift:47 |
| arrow headLen | `min(max(width * 4.0, 14), length * 0.85)` | Elements.swift:48 |
| arrow notch | `headLen * 0.30` | Elements.swift:49 |
| 空テキスト最小高 | `pointSize + 8`(非空時の下限も同じ) | Renderer.swift:171,178 |
| テキスト高さ余白 | `Math.ceil(必要高) + 2` | Renderer.swift:178 |
| suggestedSize の width | 入力 width をそのまま返す(折り返し制約) | Renderer.swift:171,178 |
| オーバーフロー行 | クリップでなく **drop**(描かない) | CTFrame 挙動、Renderer.swift:164-166 コメント |
| FontSpec 既定 | family "Helvetica Neue" → Inter にマップ、28px、bold | Geometry.swift:33 |
| pixelate blockSize | `Math.max(2, amount)`、amount 既定 14 | Renderer.swift:207 / Elements.swift:134 |
| pixelate ソース | base 画像のみ(注釈は含めない) | Renderer.swift:201 |
| pixelate グリッド | **キャンバス原点固定**(Swift は rect 中心アンカー — 意図的変更) | Renderer.swift:208 / アーキ決定 §6 |
| pixelate フォールバック | base なし or `width <= 1` or `height <= 1` → `rgba(128,128,128,1)` 塗り | Renderer.swift:194-198 |
| PNG マジック | `89 50 4E 47` | AnnotationRenderTests.swift:53 |
| LINE_HEIGHT_RATIO | `1.20996`(Inter hhea: 1984/2048 + 494/2048) | web 独自(決定性のための固定値) |
| TEXT_ASCENT_RATIO | `0.96875` | web 独自 |
| RGBAColor→CSS | `rgba(r*255, g*255, b*255, a)`(丸めはブラウザ任せ) | Geometry.swift:8-26 |

## 受け入れ基準

- [ ] `cd kakico-web && npx tsc --noEmit` が成功する。
- [ ] `cd kakico-web && npx eslint src tests` が成功し、`src/render/` に `document`/`window`/`navigator` 参照がない(境界ルールで検出): `grep -rnE '\b(document\.|window\.|navigator\.)' kakico-web/src/render/` のヒットが `encode.ts` のフォールバック関数内のみ。
- [ ] `cd kakico-web && npx vitest run tests/render` が node・browser 両プロジェクトで全件パスする。
- [ ] `src/render/` から `src/state|engine|ui|platform` への import がゼロ: `grep -rn "from '\.\./\(state\|engine\|ui\|platform\)" kakico-web/src/render/` が空。
- [ ] shadow 系 API 未使用: `grep -rn 'shadow' kakico-web/src/render/` が空。
- [ ] `withYFlip` 相当の座標反転コードが存在しない: `grep -rni 'flip' kakico-web/src/render/` が空(コメント除く)。
- [ ] `cd kakico-web && npx vite build` が成功し、`dist/` に `preview.html` が含まれない。
- [ ] 手動: Mac 側リファレンスを生成 — サンプル画像を `/tmp/claude/sample.png` に置き `swift test --filter EndToEndArtifactTest` を実行すると `/tmp/claude/annotated.png` と `/tmp/claude/annotated-cropped.png` が生成される。`npx vite dev` で `dev/preview.html` を開き、この 2 画像と並べて目視一致(矢印形状・線幅・テキスト折り返し・ピクセレートのブロック感)。
- [ ] 手動: preview の crop(40,10,480,360) 切り替えで出力が 480×360 になる(`<img>` の naturalWidth/Height を DevTools で確認)。

## テスト

### `tests/render/text.test.ts`(node、スタブ measurer: `measure = (t) => t.length * 10`)

| テスト名 | 検証内容 |
|---|---|
| `suggestedSize keeps width as the wrap constraint` | width 220 入力 → 出力 width 220(長短どちらの文字列でも) |
| `suggestedSize grows with content` | `"wrap me around ".repeat(10)` の height > `"Hi"` の height、かつ > 44(AnnotationRenderTests:149-159 の移植) |
| `suggestedSize for empty string is pointSize + 8` | 空文字 → height === 36(28 + 8)ちょうど(同 161-167) |
| `suggestedSize floor is pointSize + 8` | 1 行の短文でも height >= pointSize + 8 |
| `wrapLines is deterministic` | 同一入力 2 回で同一配列 |
| `wrapLines respects hard newlines` | `"a\n\nb"` → 3 行(中央は空行) |
| `wrapLines breaks over-wide words per character` | width 25(= 2 文字分)で `"abcdef"` → `["ab","cd","ef"]`、最低 1 文字/行 |
| `wrapLines greedy fill` | width 100 で `"aa bb cc dd"`(各語 20 + 空白 10)→ 貪欲詰めの期待行 |
| `dropped lines rule` | `(i+1)*lineHeight <= size.height + 0.5` の判定関数が境界値で正しい |
| `wrapLines memoizes per (string, width, font)` | spy 付き measurer で同一入力を 2 回 → 2 回目は `measure` 呼出ゼロ; width か font を変えると再計測; `clearWrapCache()` 後も再計測 |

### `tests/render/flatten.browser.test.ts`(browser mode)

| テスト名 | 検証内容(AnnotationRenderTests の移植元) |
|---|---|
| `flatten produces full canvas image` | 100×80 base → OffscreenCanvas 100×80(:19-26) |
| `flatten honors crop` | crop(10,10,40,20) → 40×20(:28-35) |
| `flatten scale doubles pixels` | 50×50, scale 2 → 100×100(:37-43) |
| `flatten preserves base orientation` | 上赤/下青 bitmap → (20,5) が赤・(20,35) が青(:72-82) |
| `element position matches orientation` | 黒 rect y=2..10 → (20,6) が暗い、(20,35) は青のまま(:86-96) |
| `expandToFit expands canvas` | arrow end x=100 / canvas 50 / width 6 → 出力 width 106(bbox maxX = 106、:109-116) |
| `expandToFit fills white background` | 拡張域右上 1px の r,g,b すべて > 240(:118-128) |
| `clipToImage and default keep size` | 同構成で 50×50(:130-147) |
| `flatten rejects over 256MP` | canvasSize を巨大化(例 20000×20000, scale 1)→ `null` |
| `flatten rejects zero size` | out 幅 0 → `null` |

### `tests/render/renderer.browser.test.ts`

| テスト名 | 検証内容 |
|---|---|
| `arrow changes pixels` | arrow 追加前後で pixelHash が異なる(:98-105) |
| `arrow is filled polygon without stroke halo` | 白地に red arrow → 軸上サンプルが red、tip === end 位置に着色 |
| `line draws with round caps` | 端点の外側 width/2 円内に着色(cap=round の証跡) |
| `filled rectangle paints interior` | fill 指定 rect の中心が fill 色、辺上が stroke 色 |
| `ellipse stays inside rect` | rect 四隅(角の外)は背景色のまま、楕円上は stroke 色 |
| `overflowing text renders after resize` | `size = suggestedSize(...)` 適用後、rows 10..54 と 54..(10+height) の双方に赤ピクセル(:172-205) |
| `text overflow lines are dropped` | size を 1 行分に固定した長文 → 2 行目領域に赤ピクセルなし |
| `skipElement hides only that element` | text を skipElement 指定 → text 領域は base 色、他要素は描画される |
| `empty string draws nothing` | 空 text 追加前後で pixelHash 一致 |

### `tests/render/effects.browser.test.ts`

| テスト名 | 検証内容 |
|---|---|
| `pixelate produces flat blocks` | 1px 縞 base に amount 14 → 任意ブロック内の全サンプル点が同一色 |
| `pixelate grid is canvas-anchored` | rect を +5px 動かして 2 回描画 → ブロック境界の x 座標(色が変わる位置)が両者で一致(blockSize の倍数) |
| `pixelate clamps amount to 2` | amount 1 → blockSize 2 として動作(2px 格子) |
| `pixelate falls back to gray without base` | base 省略 → rect 全域が (128,128,128,255) |
| `pixelate falls back to gray for degenerate rect` | width 1 の rect → グレー塗り |
| `pixelate stays inside rect` | rect 外 1px は base 色のまま(クリップ検証) |
| `pixelate samples base only` | pixelate の下に赤 rect を重ねる → pixelate 領域は base 由来の色(赤が透けない) |
| `pixelate scratch canvas has no stale pixels` | 透過 base で大きい rect → 小さい rect の順に描画 → 2 回目の出力に 1 回目の残像が混入しない(clearRect 回帰ガード) |

### `tests/render/encode.browser.test.ts`

| テスト名 | 検証内容 |
|---|---|
| `PNG encode yields magic bytes` | Blob 先頭 4 バイト === `[0x89,0x50,0x4E,0x47]`(:45-54) |
| `JPEG encode yields JPEG SOI` | 先頭 2 バイト === `[0xFF,0xD8]`、`type === 'image/jpeg'` |
| `PNG round-trips through ImageBitmap` | encode → createImageBitmap → 元と同サイズ |
