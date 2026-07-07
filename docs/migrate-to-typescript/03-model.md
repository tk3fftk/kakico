# 03 — Model: AnnotationModel の TypeScript 移植と .kakico コーデック

## 目的

`Sources/AnnotationModel/` の 6 ファイル(Annotation / Elements / Geometry / Handle / Document / PointerTarget)を `kakico-web/src/model/` に純粋関数として移植する。DOM 依存ゼロ、すべて immutable なプレーンデータと純粋関数で構成し、Swift の `Codable` ワイヤ形状と完全互換の `.kakico` コーデックを実装する。`Tests/AnnotationModelTests/` の全 4 テストファイル(計 40 前後のアサーション)を vitest に移植し、Mac アプリが出力した golden fixture との相互運用をテストで固定する。

## 前提

- `02-project-setup` 完了済み: `kakico-web/` に Vite + strict TypeScript + vitest + ESLint(boundary ルール込み)のスキャフォールドが存在し、`npx tsc --noEmit && npx eslint . && npx vitest run` が通る状態。
- Swift 側リポジトリ(`Sources/AnnotationModel/`, `Tests/AnnotationModelTests/`)が同一リポジトリ内で参照可能(golden fixture 生成に使用)。

## 作成・変更ファイル

```
kakico-web/src/model/geometry.ts        # Point/Size/Rect/Vector, RGBAColor+presets, FontSpec, ImageRef, DefaultInitialSize, GeometryMath, Rect ヘルパ群
kakico-web/src/model/handle.ts          # HandleRole, Handle, oppositeCorner, cornerHandles, movingCorner
kakico-web/src/model/elements.ts        # ElementID, SegmentElement/ShapeElement/TextElement/RedactionElement + 各要素の幾何関数 + arrowOutline
kakico-web/src/model/annotation.ts      # Annotation 判別共用体 + kind ディスパッチャ群
kakico-web/src/model/document.ts        # Document, ExportBounds, crop 検証, hitTest, 要素操作
kakico-web/src/model/pointerTarget.ts   # PointerTarget, resolvePointer
kakico-web/src/model/codec.ts           # .kakico JSON encode/decode, base64, CodecError
kakico-web/tests/model/geometry.test.ts
kakico-web/tests/model/handle.test.ts
kakico-web/tests/model/elements.test.ts
kakico-web/tests/model/annotation.test.ts
kakico-web/tests/model/arrowOutline.test.ts
kakico-web/tests/model/defaultPlacement.test.ts
kakico-web/tests/model/document.test.ts
kakico-web/tests/model/pointerTarget.test.ts
kakico-web/tests/model/codec.test.ts
kakico-web/tests/fixtures/golden-mac.kakico          # Mac(Swift)側エンコーダで生成する golden fixture
(一時) Tests/AnnotationModelTests/GoldenFixtureExportTests.swift  # fixture 生成後に削除
```

## 実装手順

### 座標系の大前提

モデル座標は**画像ピクセル空間・左上原点・y 下向き**(`Geometry.swift:4-6`)。Canvas 2D と同一のため、モデル層に Y 反転は一切不要。全数値は float64(TS の `number`)。"top" は **y が小さい側**を指す。

### 1. `src/model/geometry.ts`

基本型。`exactOptionalPropertyTypes` 前提のため、省略可能値は optional プロパティでなく `| null` で表す。

```ts
export interface Point { readonly x: number; readonly y: number; }
export interface Size { readonly width: number; readonly height: number; }
export interface Vector { readonly dx: number; readonly dy: number; }
/** origin = min corner (top-left)。width/height は正が正常値。 */
export interface Rect {
  readonly x: number; readonly y: number;
  readonly width: number; readonly height: number;
}
```

`RGBAColor` と 8 プリセット(`Geometry.swift:8-26`)。各成分 0…1、alpha 既定 1。

```ts
export interface RGBAColor {
  readonly r: number; readonly g: number; readonly b: number; readonly a: number;
}
export const RGBAColors = {
  red:    { r: 0.90, g: 0.16, b: 0.22, a: 1 },
  orange: { r: 0.98, g: 0.55, b: 0.10, a: 1 },
  yellow: { r: 1.0,  g: 0.80, b: 0.0,  a: 1 },
  green:  { r: 0.16, g: 0.70, b: 0.30, a: 1 },
  blue:   { r: 0.0,  g: 0.48, b: 1.0,  a: 1 },
  pink:   { r: 0.96, g: 0.40, b: 0.68, a: 1 },
  black:  { r: 0, g: 0, b: 0, a: 1 },
  white:  { r: 1, g: 1, b: 1, a: 1 },
} as const satisfies Record<string, RGBAColor>;
```

`FontSpec`(`Geometry.swift:28-50`)。**既定 family はバンドルフォント `"Inter"`**(アーキテクチャ決定 §1)。Swift 既定の `"Helvetica Neue"` はデコード時に `"Inter"` へマップ(手順 8)。

```ts
export interface FontSpec {
  readonly family: string;   // 既定 'Inter'
  readonly pointSize: number; // 既定 28(画像ピクセル単位)
  readonly bold: boolean;     // 既定 true
}
export const DEFAULT_FONT_FAMILY = 'Inter';
export function makeFontSpec(init?: Partial<FontSpec>): FontSpec;
/** 新規テキストのポイントサイズ。max(18, width * 4)  (Geometry.swift:42) */
export function suggestedPointSize(strokeWidth: number): number;
/** 逆写像。pointSize / 4(クランプなし) (Geometry.swift:48) */
export function strokeWidthForPointSize(pointSize: number): number;
```

`ImageRef`(`Geometry.swift:54-57`)。

```ts
export type ImageRef =
  | { readonly kind: 'file'; readonly path: string }      // 絶対パス(レガシー .kakico 互換用)
  | { readonly kind: 'pngData'; readonly data: Uint8Array }; // 埋め込み PNG バイト列
```

`DefaultInitialSize`(`Geometry.swift:60-74`)。

```ts
export const DefaultInitialSize = {
  degenerateThreshold: 3,                       // strict `<` 比較
  segment: { dx: 100, dy: 70 } as Vector,       // tail→head(右下方向)
  size: { width: 120, height: 90 } as Size,
  rectCenteredOn(point: Point): Rect {          // クリック点中心の 120×90
    return { x: point.x - 60, y: point.y - 45, width: 120, height: 90 };
  },
};
```

`GeometryMath`(`Geometry.swift:76-96`)。

```ts
export function distance(p: Point, q: Point): number;  // Math.hypot(q.x-p.x, q.y-p.y)
/** 線分 a–b への最短距離。射影パラメータ t を [0,1] にクランプ。 */
export function distanceToSegment(p: Point, a: Point, b: Point): number;
// dx=b.x-a.x; dy=b.y-a.y; L2=dx*dx+dy*dy
// if (L2 === 0) return Math.hypot(p.x-a.x, p.y-a.y)
// t = clamp(((p.x-a.x)*dx + (p.y-a.y)*dy) / L2, 0, 1)
// return Math.hypot(p.x - (a.x + t*dx), p.y - (a.y + t*dy))
```

Rect ヘルパ。CoreGraphics のセマンティクスを厳密に再現する(下記コメントが仕様):

```ts
/** 任意の 2 コーナーから正規化 Rect を作る(逆向きドラッグ対応)。 Geometry.swift:100-105 */
export function rectFromCorners(a: Point, b: Point): Rect;
// { x: min(a.x,b.x), y: min(a.y,b.y), width: |b.x-a.x|, height: |b.y-a.y| }

/** topLeft=(minX,minY), topRight=(maxX,minY), bottomLeft=(minX,maxY), bottomRight=(maxX,maxY) */
export function corners(r: Rect): {
  topLeft: Point; topRight: Point; bottomLeft: Point; bottomRight: Point;
};

/** CGRect.insetBy。dx 負で拡大。結果の width/height が負になっても算術のまま返す
 *  (containsPoint が負サイズで常に false になるため CG の null-rect と挙動等価)。 */
export function insetBy(r: Rect, dx: number, dy: number): Rect;
// { x: r.x+dx, y: r.y+dy, width: r.width-2*dx, height: r.height-2*dy }

export function offsetBy(r: Rect, dx: number, dy: number): Rect;

/** CGRect.contains(point): 半開区間。max 辺は排他。width/height <= 0 なら常に false。 */
export function containsPoint(r: Rect, p: Point): boolean;
// r.x <= p.x && p.x < r.x + r.width && r.y <= p.y && p.y < r.y + r.height

/** CGRect.contains(rect): 辺は包含(a が b を完全に含む)。 */
export function containsRect(a: Rect, b: Rect): boolean;
// a.x <= b.x && a.y <= b.y && a.x+a.width >= b.x+b.width && a.y+a.height >= b.y+b.height

export function union(a: Rect, b: Rect): Rect;
// x=min(minX), y=min(minY), 幅高は max(maxX)-x / max(maxY)-y

/** CGRect.intersection。交差なし(結果サイズが負)なら null。辺接触は幅 0 の Rect を返す。 */
export function intersection(a: Rect, b: Rect): Rect | null;

/** CGRect.integral。origin を floor、max 辺を ceil(外側へ拡大)。 */
export function integral(r: Rect): Rect;
// x=floor(r.x); y=floor(r.y); width=ceil(r.x+r.width)-x; height=ceil(r.y+r.height)-y
```

### 2. `src/model/handle.ts`

`Handle.swift` の移植。

```ts
export type HandleRole =
  | 'move' | 'start' | 'end'
  | 'topLeft' | 'topRight' | 'bottomLeft' | 'bottomRight';

/** リサイズ時のアンカーとなる対角コーナー。非コーナーは null。 Handle.swift:16-25 */
export function oppositeCorner(role: HandleRole): HandleRole | null;
// topLeft↔bottomRight, topRight↔bottomLeft; move/start/end → null

export interface Handle { readonly role: HandleRole; readonly position: Point; }

/** 順序固定: [topLeft, topRight, bottomLeft, bottomRight]。 Handle.swift:73-81 */
export function cornerHandles(rect: Rect): Handle[];

/** 指定コーナーを point へ移動した Rect。対角コーナーをアンカーに rectFromCorners で再構築。
 *  対角越えのドラッグは正規化で自然に反転。非コーナー role は rect をそのまま返す。 Handle.swift:84-93 */
export function movingCorner(rect: Rect, role: HandleRole, point: Point): Rect;
// topLeft → rectFromCorners(point, corners(rect).bottomRight)
// topRight → rectFromCorners(point, corners(rect).bottomLeft)
// bottomLeft → rectFromCorners(point, corners(rect).topRight)
// bottomRight → rectFromCorners(point, corners(rect).topLeft)
```

### 3. `src/model/elements.ts`

`ElementID` はブランド付き文字列(UUID)。

```ts
export type ElementID = string & { readonly __brand: 'ElementID' };
export function newElementID(): ElementID;  // crypto.randomUUID()(小文字)
export function asElementID(s: string): ElementID; // デコード時: s.toLowerCase() を付与
```

4 つの要素構造体。stored properties = シリアライズ形状(手順 8)。

```ts
// SegmentElement — arrow と line が共有 (Elements.swift:8-78)
export interface SegmentElement {
  readonly id: ElementID;
  readonly start: Point;      // tail
  readonly end: Point;        // head(矢印の先端)
  readonly color: RGBAColor;  // 既定 RGBAColors.red
  readonly width: number;     // 既定 6
}
export function makeSegmentElement(init: {
  id?: ElementID; start: Point; end: Point; color?: RGBAColor; width?: number;
}): SegmentElement;

// ShapeElement — rectangle と ellipse が共有 (Elements.swift:82-104)
export interface ShapeElement {
  readonly id: ElementID;
  readonly rect: Rect;
  readonly color: RGBAColor;        // ストローク色。既定 red
  readonly width: number;           // 既定 6
  readonly fill: RGBAColor | null;  // 既定 null(枠線のみ)
}
export function makeShapeElement(init: {
  id?: ElementID; rect: Rect; color?: RGBAColor; width?: number; fill?: RGBAColor | null;
}): ShapeElement;

// TextElement (Elements.swift:108-128) — origin/size が保存表現(rect は導出)
export interface TextElement {
  readonly id: ElementID;
  readonly origin: Point;     // テキストボックス左上
  readonly size: Size;        // 既定 { width: 160, height: 40 }
  readonly string: string;    // 既定 ''
  readonly font: FontSpec;    // 既定 makeFontSpec()
  readonly color: RGBAColor;  // 既定 red
}
export function makeTextElement(init: {
  id?: ElementID; origin: Point; size?: Size; string?: string;
  font?: FontSpec; color?: RGBAColor;
}): TextElement;
export function textRect(e: TextElement): Rect;  // { ...origin, ...size }

// RedactionElement — pixelate (Elements.swift:132-143)
export const defaultPixelateAmount = 14;
export interface RedactionElement {
  readonly id: ElementID;
  readonly rect: Rect;
  readonly amount: number;    // ピクセルブロックサイズ。既定 14
}
export function makeRedactionElement(init: {
  id?: ElementID; rect: Rect; amount?: number;
}): RedactionElement;
```

要素ごとの幾何関数(annotation.ts のディスパッチャから呼ばれる。エクスポートして直接テストも可能に):

```ts
// --- Segment (Elements.swift:21-31, 66-77) ---
export function segmentBoundingBox(e: SegmentElement): Rect;
// insetBy(rectFromCorners(e.start, e.end), -e.width, -e.width)
export function segmentHitTest(e: SegmentElement, p: Point, tolerance: number): boolean;
// distanceToSegment(p, e.start, e.end) <= Math.max(tolerance, e.width)
export function segmentHandles(e: SegmentElement): Handle[];
// [{ role: 'start', position: e.start }, { role: 'end', position: e.end }] — この順
export function segmentMoveHandle(e: SegmentElement, role: HandleRole, p: Point): SegmentElement;
// 'start'/'end' のみ更新。他 role は e をそのまま返す
export function segmentTranslate(e: SegmentElement, d: Vector): SegmentElement;

// --- Shape (Elements.swift:95-103) ---
export function shapeBoundingBox(e: ShapeElement): Rect;   // insetBy(e.rect, -e.width, -e.width)
export function shapeHitTest(e: ShapeElement, p: Point, tolerance: number): boolean;
// fill !== null: containsPoint(insetBy(e.rect, -tolerance, -tolerance), p)
// fill === null: t = max(tolerance, e.width);
//   containsPoint(insetBy(e.rect, -t, -t), p) && !containsPoint(insetBy(e.rect, t, t), p)
//   ※ ellipse でも RECT のエッジバンド判定(曲線判定はしない)。inner が負サイズに潰れる
//     ケース(t > rect の半分)は containsPoint が false を返すため CG と同挙動。

// --- Rect 系共通デフォルト (Handle.swift:56-70) — Text/Redaction はこれをそのまま使う ---
export function rectGeometryHitTest(rect: Rect, p: Point, tolerance: number): boolean;
// containsPoint(insetBy(rect, -tolerance, -tolerance), p)
// boundingBox = rect そのまま(インセットなし)、handles = cornerHandles(rect)、
// moveHandle = movingCorner、translate = offsetBy
```

`arrowOutline`(`Elements.swift:38-64`)は**逐語移植**。6 点の塗りつぶしポリゴン、巻き順 `[tip, barbUpper, notchUpper, tail, notchLower, barbLower]`:

```ts
export function arrowOutline(e: SegmentElement): Point[] {
  const dx = e.end.x - e.start.x, dy = e.end.y - e.start.y;
  const length = Math.hypot(dx, dy);
  if (length <= 0.5) return [];                        // rendering floor(length > 0.5 のガード)

  const ux = dx / length, uy = dy / length;            // 軸方向単位ベクトル
  const px = -uy, py = ux;                             // 垂直単位ベクトル("upper" 側)

  const shaftHalf = Math.max(1, e.width * 0.5);
  const headHalf = Math.max(shaftHalf * 2.4, e.width * 1.8);
  const headLen = Math.min(Math.max(e.width * 4.0, 14), length * 0.85);
  const notch = headLen * 0.30;
  const baseX = length - headLen;
  const notchX = baseX + notch;

  const pt = (t: number, o: number): Point =>
    ({ x: e.start.x + ux * t + px * o, y: e.start.y + uy * t + py * o });

  return [
    pt(length, 0),           // 0: tip == end
    pt(baseX, headHalf),     // 1: upper barb
    pt(notchX, shaftHalf),   // 2: upper notch
    pt(0, 0),                // 3: tail == start(尖った尾。幅ゼロ)
    pt(notchX, -shaftHalf),  // 4: lower notch
    pt(baseX, -headHalf),    // 5: lower barb
  ];
}
```

### 4. `src/model/annotation.ts`

判別共用体。判別子フィールド名は常に `kind`(命名規約 §9)。

```ts
export type Annotation =
  | { readonly kind: 'arrow';     readonly element: SegmentElement }
  | { readonly kind: 'line';      readonly element: SegmentElement }
  | { readonly kind: 'rectangle'; readonly element: ShapeElement }
  | { readonly kind: 'ellipse';   readonly element: ShapeElement }
  | { readonly kind: 'text';      readonly element: TextElement }
  | { readonly kind: 'pixelate';  readonly element: RedactionElement };
export type AnnotationKind = Annotation['kind'];
```

ディスパッチャ(すべて純粋。「変更」系は kind を保存した新しい `Annotation` を返す):

```ts
export function annotationId(a: Annotation): ElementID;   // a.element.id
export function boundingBox(a: Annotation): Rect;
// arrow/line → segmentBoundingBox; rectangle/ellipse → shapeBoundingBox;
// text → textRect(そのまま、インセットなし); pixelate → element.rect

export function hitTest(a: Annotation, p: Point, tolerance: number): boolean;
// arrow/line → segmentHitTest; rectangle/ellipse → shapeHitTest;
// text → rectGeometryHitTest(textRect(e), …); pixelate → rectGeometryHitTest(e.rect, …)

export function handles(a: Annotation): Handle[];
// arrow/line → segmentHandles([start, end] の順);
// text/pixelate/rectangle/ellipse → cornerHandles(rect)([TL, TR, BL, BR] の順)

export function moveHandle(a: Annotation, role: HandleRole, p: Point): Annotation;
export function translate(a: Annotation, d: Vector): Annotation;

/** arrow/line/rectangle/ellipse → width。text/pixelate → null。 Annotation.swift:34-52 */
export function strokeWidth(a: Annotation): number | null;
/** width === null、または text/pixelate には no-op(a をそのまま返す)。 */
export function withStrokeWidth(a: Annotation, width: number | null): Annotation;

/** pixelate のみ null。rectangle/ellipse への set は stroke 色のみ(fill 不変)。 Annotation.swift:56-76 */
export function color(a: Annotation): RGBAColor | null;
export function withColor(a: Annotation, c: RGBAColor | null): Annotation;

/** クリック配置(Skitch 流)。 Annotation.swift:82-108 */
export function applyingDefaultInitialSize(a: Annotation): Annotation;
```

`applyingDefaultInitialSize` の正確な規則(退化判定は **生の幾何**で行う。boundingBox は width 分膨らむため使わない):

- **arrow / line**: `distance(start, end) < 3`(strict `<`)なら `end = { x: start.x + 100, y: start.y + 70 }`。それ以外は不変。
- **rectangle / ellipse / pixelate**: `Math.max(rect.width, rect.height) < 3` なら `rect = DefaultInitialSize.rectCenteredOn({ x: rect.x, y: rect.y })`(クリック点=退化 rect の origin を中心とする 120×90)。片軸だけ細長い場合(例 2×200)は意図的な形として不変。ちょうど 3 は不変。
- **text**: 常に不変(アプリ層が既定 160×40 で配置済み)。
- kind は常に保存。

### 5. `src/model/document.ts`

```ts
export type ExportBounds = 'expandToFit' | 'clipToImage';  // Document.swift:4-7 の rawValue と同一文字列

export interface Document {
  readonly baseImage: ImageRef;
  readonly canvasSize: Size;                  // ベース画像の全体サイズ(px)
  readonly elements: readonly Annotation[];   // 配列順 == 描画順(末尾が最前面)
  readonly crop: Rect | null;                 // 画像ピクセル空間。null = crop なし
}
export function makeDocument(init: {
  baseImage: ImageRef; canvasSize: Size;
  elements?: readonly Annotation[]; crop?: Rect | null;
}): Document;
```

純粋関数群(変更系はすべて新しい `Document` を返す。要素配列は共有可):

```ts
export function outputRect(doc: Document): Rect;
// doc.crop ?? { x: 0, y: 0, ...doc.canvasSize }

export function expandedOutputRect(doc: Document): Rect;
// elements が空 → outputRect(doc) をそのまま(integral しない)。
// 非空 → outputRect から始めて全要素の boundingBox を union し、最後に integral()。
// crop の有無に関わらず全要素を union。注釈が左上にはみ出せば origin は負になり得る。

export function outputRectFor(doc: Document, bounds: ExportBounds): Rect;
// 'clipToImage' → outputRect; 'expandToFit' → expandedOutputRect

export function indexOf(doc: Document, id: ElementID): number | null;

/** 最前面ヒット: elements を末尾から走査し、最初に hitTest が真の要素の id。なければ null。 */
export function hitTest(doc: Document, p: Point, tolerance: number): ElementID | null;

/** id の要素に body を適用した新 Document。id 不在なら doc をそのまま返す。 */
export function mutateElement(doc: Document, id: ElementID,
                              body: (a: Annotation) => Annotation): Document;

/** crop 妥当性の単一情報源。 Document.swift:69-73
 *  rect を (0,0,canvasSize) と intersection。結果が null、または width < 2 || height < 2 なら null。 */
export function clampedCrop(doc: Document, rect: Rect): Rect | null;

/** doc.crop === null なら null。それ以外は clampedCrop の結果に integral() を適用(退化なら null)。 */
export function integralCrop(doc: Document): Rect | null;

export function addElement(doc: Document, element: Annotation): Document;    // 末尾に追加(最前面)
export function removeElement(doc: Document, id: ElementID): Document;       // 不在なら no-op
export function bringToFront(doc: Document, id: ElementID): Document;        // 取り除いて末尾へ。不在なら no-op
```

**undo/redo モデル**: このモジュールに undo スタックは存在しない(Swift 同様)。`Document` は immutable なプレーンデータ木であり、スナップショット=参照コピーで undo が成立する。履歴管理(`beginInteraction`/`commitInteraction`/500ms デバウンス)は doc 05 の `state/history.ts` の責務。ここでは「全操作が新しい `Document` を返し、旧値は不変のまま」という規約だけを守る。

### 6. `src/model/pointerTarget.ts`

```ts
export type PointerTarget =
  | { readonly kind: 'handle'; readonly id: ElementID; readonly role: HandleRole }
  | { readonly kind: 'body';   readonly id: ElementID }
  | { readonly kind: 'empty' };

export function resolvePointer(
  doc: Document, point: Point, selection: ElementID | null,
  bodyTolerance: number, handleTolerance: number,
): PointerTarget;
```

優先順位(`PointerTarget.swift:20-40` の逐語移植):

1. **選択中要素のハンドル**: `selection` が既存要素を指すなら、その `handles()` を**定義順**(segment: [start, end] / rect 系: [TL, TR, BL, BR])に走査し、`distance(handle.position, point) <= handleTolerance`(ユークリッド距離、円形判定)を満たす**最初の**ハンドルで `{ kind: 'handle', id, role }`。ハンドルは現在の選択にのみ属する — 未選択要素のコーナーは決してハンドルにならない。
2. **本体ヒット**: `hitTest(doc, point, bodyTolerance)` が非 null → `{ kind: 'body', id }`(最前面優先)。
3. **選択フレームのフォールバック**: 選択中要素が存在し `containsPoint(boundingBox(element), point)` → `{ kind: 'body', id: element.id }`。枠線のみ(unfilled)の shape の空洞内部をクリックしても選択中なら移動できる規則。現在の選択にのみ適用。
4. それ以外 → `{ kind: 'empty' }`(アプリ層は作成開始)。

トレランスはすべて呼び出し側(アプリ層)が渡す。モデルは値をハードコードしない(テスト代表値: body 8 / handle 8)。

### 7. `src/model/codec.ts` — .kakico ワイヤ形状

Swift の synthesized `Codable` + `JSONEncoder` の出力形状を**逐語再現**する。カスタム coding key なし。

```ts
export const KAKICO_FORMAT_VERSION = 1;
export class CodecError extends Error {}

export function encodeDocument(doc: Document): string;   // JSON 文字列
export function decodeDocument(json: string): Document;  // 不正入力は CodecError を throw

// base64(atob/Buffer に依存しない純実装。node/browser 双方で決定的)
export function bytesToBase64(bytes: Uint8Array): string;
export function base64ToBytes(s: string): Uint8Array;    // 不正文字は CodecError
```

ワイヤ形状の完全仕様(`AnnotationModelTests.swift` の legacy fixture と round-trip テストで固定済み):

| 型 | JSON 表現 |
|---|---|
| `CGPoint` | `[x, y]`(2 要素配列) |
| `CGSize` | `[width, height]` |
| `CGRect` | `[[x, y], [width, height]]`(origin 配列 + size 配列のネスト) |
| `UUID` | 文字列 `8-4-4-4-12`。Swift は大文字で emit、デコードは大小無視。**TS はデコード時に小文字へ正規化して保持、エンコードは保持値をそのまま出力** |
| `Data` | base64 文字列 |
| enum + associated value | 1 キーのオブジェクト。キー = case 名、値 = `{"_0": …}`(無ラベル)またはラベル名キー |
| `RGBAColor` | `{"r": 0.9, "g": 0.16, "b": 0.22, "a": 1}`(キー順不問) |
| `FontSpec` | `{"family": "…", "pointSize": 28, "bold": true}` |

要素・ドキュメントの形状:

```jsonc
// Annotation(6 種 + 予約 2 種)
{"arrow":     {"_0": { /* SegmentElement */ }}}
{"line":      {"_0": { /* SegmentElement */ }}}
{"rectangle": {"_0": { /* ShapeElement */ }}}
{"ellipse":   {"_0": { /* ShapeElement */ }}}
{"text":      {"_0": { /* TextElement */ }}}
{"pixelate":  {"_0": { /* RedactionElement */ }}}
// 予約(post-parity 拡張。v1 デコーダは CodecError("unsupported annotation kind: …") を throw):
// {"blur": …}, {"stamp": …}

// SegmentElement
{"id": "<uuid>", "start": [1, 2], "end": [3, 4],
 "color": {"r": 0.9, "g": 0.16, "b": 0.22, "a": 1}, "width": 6}

// ShapeElement — fill が null のときは "fill" キーを完全に省略(null を書かない)
{"id": "<uuid>", "rect": [[0, 0], [100, 100]], "color": {…}, "width": 6, "fill": {…}}

// TextElement — "origin"/"size" キー必須(テストで固定)。導出 rect は決して書かない
{"id": "<uuid>", "origin": [7, 9], "size": [120, 30], "string": "hello",
 "font": {"family": "Helvetica Neue", "pointSize": 28, "bold": true}, "color": {…}}

// RedactionElement
{"id": "<uuid>", "rect": [[0, 0], [50, 50]], "amount": 14}

// ImageRef
{"file": {"path": "/abs/path.png"}}          // ラベル付き associated value
{"pngData": {"_0": "<base64>"}}

// Document — crop が null なら "crop" キー省略。version は Web 版が追加
// (Swift の JSONDecoder は未知キーを無視するため Mac 互換を壊さない)
{"version": 1, "baseImage": {…}, "canvasSize": [640, 480],
 "elements": [ {…Annotation…} ], "crop": [[5, 5], [100, 100]]}
```

デコード規則:

1. `version` キーは**任意**(Mac アプリ出力には存在しない)。存在すれば数値、`> 1` なら `CodecError`。
2. `crop` / `fill`: キー欠落と `null` の両方を null として受理(Swift の `decodeIfPresent` 互換)。
3. 数値は float64 として読む。整数形(`6`)・小数形(`6.0`)双方を受理。
4. `font.family === "Helvetica Neue"` → `"Inter"` にマップ(レガシーフォント移行。それ以外の family は素通し)。
5. UUID は小文字化して `ElementID` へ。形式不正(`8-4-4-4-12` 16 進でない)は `CodecError`。
6. 未知の annotation case キー(`blur`/`stamp` 含む)・未知の `ImageRef` case は `CodecError`。
7. 必須キー欠落・型不一致は `CodecError`(メッセージにキーパスを含める)。

エンコード規則: `version: 1` を必ず書く。`crop === null` / `fill === null` はキー省略。キー順は任意(比較は常に値で行う)。

### 8. Golden fixture の生成(Swift 側・一時作業)

Mac アプリのエンコーダが実際に出力するバイト列をテストデータとして確保する。**コーデックは fixture に対して書く。推測で書かない。**

1. `Tests/AnnotationModelTests/GoldenFixtureExportTests.swift` を一時作成:

```swift
import XCTest
@testable import AnnotationModel

/// 一時テスト: Web 版コーデック検証用の golden fixture を出力する。
/// 実行後にこのファイルは削除する(fixture はコミットして残す)。
final class GoldenFixtureExportTests: XCTestCase {
    func testWriteGoldenFixture() throws {
        let png = Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
        func uuid(_ s: String) -> UUID { UUID(uuidString: s)! }
        let doc = Document(
            baseImage: .pngData(png),
            canvasSize: CGSize(width: 640, height: 480),
            elements: [
                .arrow(SegmentElement(id: uuid("AAAAAAAA-0000-0000-0000-000000000001"),
                                      start: CGPoint(x: 10, y: 20), end: CGPoint(x: 110, y: 90))),
                .line(SegmentElement(id: uuid("AAAAAAAA-0000-0000-0000-000000000002"),
                                     start: CGPoint(x: 5, y: 6), end: CGPoint(x: 7, y: 8),
                                     color: .blue, width: 3)),
                .rectangle(ShapeElement(id: uuid("AAAAAAAA-0000-0000-0000-000000000003"),
                                        rect: CGRect(x: 30, y: 40, width: 120, height: 90),
                                        color: .green, width: 4, fill: .yellow)),
                .ellipse(ShapeElement(id: uuid("AAAAAAAA-0000-0000-0000-000000000004"),
                                      rect: CGRect(x: 200, y: 100, width: 80, height: 60))),
                .text(TextElement(id: uuid("AAAAAAAA-0000-0000-0000-000000000005"),
                                  origin: CGPoint(x: 12, y: 34), size: CGSize(width: 160, height: 40),
                                  string: "hello", font: FontSpec(), color: .black)),
                .pixelate(RedactionElement(id: uuid("AAAAAAAA-0000-0000-0000-000000000006"),
                                           rect: CGRect(x: 5, y: 6, width: 50, height: 40), amount: 14)),
            ],
            crop: CGRect(x: 5, y: 5, width: 600, height: 400))
        let data = try JSONEncoder().encode(doc)
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // AnnotationModelTests/
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("kakico-web/tests/fixtures/golden-mac.kakico")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: url)
    }
}
```

2. `cd /Users/hiroki.takatsuka/github.com/kakico && swift test --filter GoldenFixtureExportTests` を実行。
3. `kakico-web/tests/fixtures/golden-mac.kakico` が生成されたことを確認し、コミット対象に含める。
4. `Tests/AnnotationModelTests/GoldenFixtureExportTests.swift` を削除(Swift 側テストスイートを元の状態に戻す)。

### 9. テストスイートの移植

「テスト」セクションの表どおりに 9 ファイルを作成。すべて vitest node 環境(`import { describe, it, expect } from 'vitest'`)。浮動小数比較は `expect(x).toBeCloseTo(v, 4)`(Swift の `accuracy: 0.0001` 相当)。

### 10. ゲート確認

```
cd kakico-web && npx tsc --noEmit && npx eslint . && npx vitest run
```

ESLint boundary ルール(02 で設定済み)が `src/model/**` の DOM import ゼロを機械検証することを確認。`crypto.randomUUID` はグローバル(Web Crypto)であり import 不要のため違反にならない。

## 定数・仕様表

| 名前 | 値 | Swift 出典 |
|---|---|---|
| `SegmentElement` 既定 `color` / `width` | `.red` / `6` | Sources/AnnotationModel/Elements.swift:16 |
| Segment boundingBox | `rectFromCorners(start,end)` を全辺 `-width` インセット(拡大) | Sources/AnnotationModel/Elements.swift:22 |
| Segment ヒット帯 | `distanceToSegment <= max(tolerance, width)` | Sources/AnnotationModel/Elements.swift:26 |
| Segment ハンドル順 | `[start, end]` | Sources/AnnotationModel/Elements.swift:30 |
| arrow 描画下限 | `length > 0.5`、以下は `[]` | Sources/AnnotationModel/Elements.swift:41 |
| `shaftHalf` | `max(1, width * 0.5)` | Sources/AnnotationModel/Elements.swift:46 |
| `headHalf` | `max(shaftHalf * 2.4, width * 1.8)` | Sources/AnnotationModel/Elements.swift:47 |
| `headLen` | `min(max(width * 4.0, 14), length * 0.85)` | Sources/AnnotationModel/Elements.swift:48 |
| `notch` | `headLen * 0.30` | Sources/AnnotationModel/Elements.swift:49 |
| Segment moveHandle | `start`/`end` のみ変更、他 role は no-op | Sources/AnnotationModel/Elements.swift:66-71 |
| `ShapeElement` 既定 `color`/`width`/`fill` | `.red` / `6` / `nil` | Sources/AnnotationModel/Elements.swift:90 |
| Shape boundingBox | rect を全辺 `-width` インセット(拡大) | Sources/AnnotationModel/Elements.swift:95 |
| Stroked shape ヒット帯 | `t = max(tolerance, width)`; outer=`insetBy(-t)` 内 かつ inner=`insetBy(+t)` 外 | Sources/AnnotationModel/Elements.swift:100-101 |
| `TextElement` 既定 `size`/`string`/`color` | `160×40` / `""` / `.red` | Sources/AnnotationModel/Elements.swift:123-124 |
| `defaultPixelateAmount` | `14` | Sources/AnnotationModel/Elements.swift:134 |
| `RGBAColors.red` | `(0.90, 0.16, 0.22, 1)` | Sources/AnnotationModel/Geometry.swift:18 |
| `RGBAColors.orange` | `(0.98, 0.55, 0.10, 1)` | Sources/AnnotationModel/Geometry.swift:19 |
| `RGBAColors.yellow` | `(1.0, 0.80, 0.0, 1)` | Sources/AnnotationModel/Geometry.swift:20 |
| `RGBAColors.green` | `(0.16, 0.70, 0.30, 1)` | Sources/AnnotationModel/Geometry.swift:21 |
| `RGBAColors.blue` | `(0.0, 0.48, 1.0, 1)` | Sources/AnnotationModel/Geometry.swift:22 |
| `RGBAColors.pink` | `(0.96, 0.40, 0.68, 1)` | Sources/AnnotationModel/Geometry.swift:23 |
| `RGBAColors.black` / `.white` | `(0,0,0,1)` / `(1,1,1,1)` | Sources/AnnotationModel/Geometry.swift:24-25 |
| `FontSpec` 既定(Swift) | `"Helvetica Neue"`, `28`, `bold: true` | Sources/AnnotationModel/Geometry.swift:33 |
| `FontSpec` 既定(Web) | family のみ `"Inter"` に置換(アーキ決定 §1)。decode 時に旧名をマップ | — |
| `suggestedPointSize(w)` | `max(18, w * 4)` | Sources/AnnotationModel/Geometry.swift:42 |
| `strokeWidthForPointSize(p)` | `p / 4`(クランプなし) | Sources/AnnotationModel/Geometry.swift:48 |
| `degenerateThreshold` | `3`(strict `<`) | Sources/AnnotationModel/Geometry.swift:63 |
| `DefaultInitialSize.segment` | `(dx: 100, dy: 70)` | Sources/AnnotationModel/Geometry.swift:65 |
| `DefaultInitialSize.size` | `120 × 90`(クリック点中心) | Sources/AnnotationModel/Geometry.swift:67 |
| コーナーハンドル順 | `[topLeft, topRight, bottomLeft, bottomRight]` | Sources/AnnotationModel/Handle.swift:73-81 |
| `oppositeCorner` | TL↔BR, TR↔BL; move/start/end → null | Sources/AnnotationModel/Handle.swift:16-25 |
| crop 最小サイズ | `width >= 2 && height >= 2`、未満は null | Sources/AnnotationModel/Document.swift:71 |
| `ExportBounds` 文字列 | `"expandToFit"` / `"clipToImage"` | Sources/AnnotationModel/Document.swift:4-7 |
| Document hitTest | 末尾(最前面)から走査、最初のヒット | Sources/AnnotationModel/Document.swift:55-60 |
| resolvePointer 優先順 | handle(選択中のみ) → body → 選択フレーム → empty | Sources/AnnotationModel/PointerTarget.swift:20-40 |
| テスト代表トレランス | body `8` / handle `8` | Tests/AnnotationModelTests/PointerTargetTests.swift:25 ほか |
| `containsPoint` | 半開区間(max 辺排他)、非正サイズは false | CGRect.contains 互換 |
| `integral` | origin floor、max 辺 ceil | CGRect.integral 互換 |

## 受け入れ基準

- [ ] `cd kakico-web && npx tsc --noEmit` がエラーゼロで通る。
- [ ] `cd kakico-web && npx eslint .` がエラーゼロ。`grep -rE "\bdocument\.|window\.|HTMLElement|navigator\." kakico-web/src/model/` がノーヒット(DOM 依存ゼロの粗い確認)。
- [ ] `cd kakico-web && npx vitest run tests/model` が全件グリーン(下記テスト表の全ケース、40 件以上)。
- [ ] `kakico-web/tests/fixtures/golden-mac.kakico` が存在し、Swift の `JSONEncoder` 出力そのものである(手順 8 で生成)。
- [ ] `Tests/AnnotationModelTests/GoldenFixtureExportTests.swift` がリポジトリに**残っていない**(`ls Tests/AnnotationModelTests/` で確認)。
- [ ] Swift 側が無傷: `cd /Users/hiroki.takatsuka/github.com/kakico && swift test` が従来どおり全件パス。
- [ ] `decodeDocument(encodeDocument(doc))` が任意の Document で deep-equal(codec.test.ts で機械検証)。
- [ ] `encodeDocument` の出力 JSON に `crop: null` / `fill: null` が**現れない**(省略される)ことをテストで検証。
- [ ] `src/model/*.ts` の 7 ファイルすべてが存在し、`src/model/` 以外への import が `src/model/` 内部間のみ(相互参照は geometry ← handle ← elements ← annotation ← document ← pointerTarget/codec の一方向)。

## テスト

vitest(node 環境)。`acc = 4`(`toBeCloseTo` の桁数、Swift の accuracy 0.0001 相当)。各行が Swift テスト 1 件との 1:1 対応(追加ケースは「追加」と明記)。

### tests/model/geometry.test.ts

| Swift テスト | TS テスト名 | アサーション |
|---|---|---|
| `testDistanceToSegment` | `distanceToSegment: perpendicular and beyond-endpoint clamp` | `distanceToSegment((5,5),(0,0),(10,0))` ≈ 5; `distanceToSegment((20,0),(0,0),(10,0))` ≈ 10 |
| `testRectFromCornersHandlesNegativeDrag` | `rectFromCorners normalizes negative drag` | `rectFromCorners((10,10),(0,0))` = `{x:0,y:0,width:10,height:10}` |
| `testSuggestedFontPointSizeScalesWithStrokeWidth` | `suggestedPointSize scales with stroke width` | `suggestedPointSize(6)` = 24; `suggestedPointSize(2)` = 18(下限クランプ); `suggestedPointSize(10)` = 40 |
| `testStrokeWidthForPointSizeInvertsSuggestedPointSize` | `strokeWidthForPointSize inverts suggestedPointSize` | width ∈ [4.5, 6, 10, 40] で `strokeWidthForPointSize(suggestedPointSize(w))` = w; `strokeWidthForPointSize(18)` = 4.5 |
| (追加) | `containsPoint is half-open` | rect (0,0,10,10): `(0,0)` true, `(10,5)` false, `(5,10)` false; 負サイズ rect は常に false |
| (追加) | `intersection returns null when disjoint` | (0,0,10,10) ∩ (20,20,5,5) = null; (0,0,10,10) ∩ (5,5,10,10) = (5,5,5,5) |
| (追加) | `integral floors origin and ceils max edges` | `integral({x:0.4,y:0.6,width:9.2,height:8.8})` = `{x:0,y:0,width:10,height:10}` |

### tests/model/handle.test.ts

| Swift テスト | TS テスト名 | アサーション |
|---|---|---|
| `testCornerHandlesAndMovingCorner` | `cornerHandles order and movingCorner anchors opposite corner` | rect (0,0,10,20): roles = `['topLeft','topRight','bottomLeft','bottomRight']`; `handles[1].position` = (10,0); `movingCorner(r,'topLeft',(-5,-5))` = (-5,-5,15,25); `movingCorner(r,'bottomRight',(30,40))` = (0,0,30,40); `movingCorner(r,'move',(0,0))` = r |
| `testCornerRoleOpposite` | `oppositeCorner mapping` | TL→BR, TR→BL, BL→TR, BR→TL; `move`/`start` → null |

### tests/model/elements.test.ts

| Swift テスト | TS テスト名 | アサーション |
|---|---|---|
| `testArrowHitTest` | `segmentHitTest hits near axis, misses far` | segment (0,0)→(100,0), width 6: `(50,3)` tol 8 → true; `(50,40)` tol 8 → false |
| `testShapeStrokedHitTestEdgeOnly` | `shapeHitTest stroked: edge band only` | rect (0,0,100,100), width 4, fill null: `(0,50)` tol 6 → true; `(50,50)` tol 6 → false |
| `testShapeFilledHitTestInside` | `shapeHitTest filled: interior hit` | 同 rect, fill red: `(50,50)` tol 0 → true |
| (追加) | `segmentBoundingBox expands by width` | segment (0,0)→(10,0), width 6 → bbox = (-6,-6,22,12) |

### tests/model/annotation.test.ts

| Swift テスト | TS テスト名 | アサーション |
|---|---|---|
| `testMoveHandleResizesShape` | `moveHandle resizes rectangle, kind preserved` | rectangle rect (0,0,100,100) に `moveHandle(a,'bottomRight',(200,150))` → kind `'rectangle'` のまま rect = (0,0,200,150) |
| `testTranslatePreservesKind` | `translate moves both segment endpoints, kind preserved` | arrow (0,0)→(10,0) を `translate(a,{dx:5,dy:5})` → kind `'arrow'`, start (5,5), end (15,5) |
| `testArrowAndLineShareSegmentElement` | `arrow and line share SegmentElement behavior` | 同一 SegmentElement を包んだ arrow/line で `annotationId`, `boundingBox`, `handles` が等しい |
| `testStrokeWidthRoundTripsForStrokedKinds` | `strokeWidth round-trips for stroked kinds` | arrow/line/rectangle/ellipse: `strokeWidth(a)` = 6 → `withStrokeWidth(a,12)` 後 12 |
| `testStrokeWidthIsNilAndSetterIsNoOpForUnstrokedKinds` | `strokeWidth null and setter no-op for text/pixelate` | text/pixelate: `strokeWidth(a)` = null; `withStrokeWidth(a,12)` が deep-equal で不変 |
| `testColorRoundTripsForColoredKinds` | `color round-trips for colored kinds` | arrow/line/rectangle/ellipse/text: `color(a)` 非 null → `withColor(a, RGBAColors.blue)` 後 blue |
| `testColorIsNilAndSetterIsNoOpForPixelate` | `color null and setter no-op for pixelate` | pixelate: `color(a)` = null; `withColor(a, blue)` 不変 |

### tests/model/arrowOutline.test.ts

| Swift テスト | TS テスト名 | アサーション |
|---|---|---|
| `testReturnsSixPoints` | `returns six points` | (0,0)→(200,0), width 6 → `length === 6` |
| `testTipIsEndAndTailIsStart` | `tip is end and tail is start` | start (17,23), end (140,90): `pts[0]` ≈ end, `pts[3]` ≈ start |
| `testSymmetricAcrossAxisForHorizontalArrow` | `symmetric across axis for horizontal arrow` | pts[1]/pts[5], pts[2]/pts[4] が x 一致・y 符号反転; `|pts[1].y| > |pts[2].y|` |
| `testHeadScalesWithWidth` | `head scales with width` | 長さ 400、width 6 vs 12: `|thick[1].y|` ≈ `|thin[1].y| * 2`(精度 0.01); headLen(=400−pts[1].x)は width 12 の方が大 |
| `testHeadLengthClampedForShortArrow` | `head length clamped for short arrow` | 長さ 10, width 6: headLen ≤ 10×0.85+1e-4; `pts[1].x > 0` |
| `testRotationForVerticalArrow` | `rotation for vertical arrow` | (0,0)→(0,100): tip (0,100), tail (0,0); `pts[1].x` ≈ `-pts[5].x`, `pts[1].y` ≈ `pts[5].y` |
| `testDegenerateArrowReturnsEmpty` | `degenerate arrow returns empty` | start == end (5,5) → `[]` |

### tests/model/defaultPlacement.test.ts(クリック点 p = (50,60))

| Swift テスト | TS テスト名 | アサーション |
|---|---|---|
| `testDegenerateArrowGetsDefaultVector` | `degenerate arrow gets default vector` | start p, end p → start 不変、end = (150,130); bbox width > 3 |
| `testDegenerateLineGetsDefaultVector` | `degenerate line gets default vector` | end = (150,130), kind `'line'` |
| `testDegenerateRectIsCenteredDefaultSize` | `degenerate rect is centered default size` | 零 rect at p → 120×90、中心 (50,60) |
| `testDegenerateEllipseAndPixelateGetDefaultSize` | `degenerate ellipse and pixelate get default size` | ellipse: width 120; pixelate: width 120、midY 60 |
| `testNonDegenerateArrowUnchanged` | `non-degenerate arrow unchanged` | (0,0)→(200,100) 不変(deep-equal) |
| `testNonDegenerateRectUnchanged` | `non-degenerate rect unchanged` | (10,10,100,80) 不変 |
| `testTextUnchanged` | `text unchanged` | 220×44 テキスト不変 |
| `testThinRectIsLeftUnchanged` | `thin sliver rect left unchanged` | (10,10,2,200) 不変(両軸退化が条件) |
| `testTinyBoxBelowThresholdGetsDefaultSize` | `tiny box below threshold gets default size` | (50,60,2.9,2.9) → 120×90 |
| `testRectAtThresholdIsLeftUnchanged` | `rect at threshold left unchanged` | 3×3 不変(strict `<`) |
| `testSegmentJustBelowThresholdGetsDefault` | `segment just below threshold gets default` | end (2.99,0) → end = (100,70) |
| `testSegmentJustAboveThresholdIsLeftUnchanged` | `segment just above threshold unchanged` | end (3.01,0) 不変 |

### tests/model/document.test.ts

| Swift テスト | TS テスト名 | アサーション |
|---|---|---|
| `testDocumentTopmostHitTest` | `hitTest returns topmost element` | 同座標 filled rect ×2 → 後(末尾)の id |
| `testClampedCrop` | `clampedCrop clamps and rejects degenerate` | canvas 100×80: (10,10,50,40) 不変; (-20,60,200,100) → (0,60,100,20); 幅 1 → null; 完全外 (200,200,50,50) → null |
| `testExpandedOutputRectWithNoElements` | `expandedOutputRect with no elements` | canvas 100×80, 要素なし → (0,0,100,80)(integral されない) |
| `testExpandedOutputRectWithOverflowingElement` | `expandedOutputRect grows for overflow` | arrow (80,40)→(150,40) width 6 追加 → width > 100 かつ `containsRect(expanded, (0,0,100,80))` |
| `testExpandedOutputRectWithNegativePosition` | `expandedOutputRect allows negative origin` | rect (-30,-20,50,40) width 4 → origin.x < 0, origin.y < 0 |
| `testExpandedOutputRectWithCrop` | `expandedOutputRect unions past crop` | canvas 200×200, crop (50,50,100,100), arrow →(180,60) → maxX > 150 |
| `testOutputRectForClipToImage` | `outputRectFor clipToImage ignores overflow` | overflow 要素ありでも (0,0,100,80) |
| `testOutputRectForExpandToFit` | `outputRectFor expandToFit grows` | width > 100 |
| (追加) | `mutateElement / addElement / removeElement / bringToFront are pure` | 各操作後、元 Document が不変(参照比較 + deep-equal); 不在 id は no-op で同値の Document |
| (追加) | `integralCrop clamps then snaps` | crop (0.4,0.6,50.2,40.2) → `integral(clampedCrop)` = (0,0,51,41); crop null → null; 退化 crop → null |

### tests/model/pointerTarget.test.ts(canvas 400×400, filled rect = (0,0,100,100) fill red)

| Swift テスト | TS テスト名 | アサーション |
|---|---|---|
| `testResolvePointerPrefersSelectionHandleWhenSelected` | `prefers selection handle when selected` | (102,102), selection = id, tol 8/8 → `{kind:'handle', role:'bottomRight'}` |
| `testResolvePointerHandleIgnoredWhenNotSelected` | `handle ignored when not selected` | 同点 selection null → `{kind:'body'}` |
| `testResolvePointerBodyHit` | `body hit while selected` | (50,50), selection = id → body |
| `testResolvePointerEmpty` | `empty when clear of all elements` | (300,300) → empty |
| `testResolvePointerBodyHitViaSelectionFrame` | `body via selection frame over hollow interior` | stroked rect(fill null, width 6)、(50,50) selection = id → body |
| `testResolvePointerInteriorEmptyWhenNotSelected` | `interior empty when not selected` | 同点 selection null → empty |
| `testResolvePointerTopmostBody` | `topmost body on overlap` | 重なる 2 filled rect, tol 0/8 → 末尾の id |

### tests/model/codec.test.ts

| Swift テスト | TS テスト名 | アサーション |
|---|---|---|
| `testArrowAndLineLegacyJSONDecodes` | `legacy arrow/line JSON decodes exactly` | 下記 JSON(Swift テストから逐語コピー)をデコード: kinds `['arrow','line']`; arrow id `11111111-…`, start (1,2), end (3,4), width 6; line id `22222222-…`, start (5,6), end (7,8), color = `RGBAColors.blue` |
| `testTextElementCodableKeepsOriginAndSize` | `text element JSON keeps origin and size keys` | text (origin (7,9), size 120×30, "hello") をエンコード → JSON 文字列に `"origin"` と `"size"` を含み `"rect"` を含まない; デコードで deep-equal |
| `testDocumentCodableRoundTrip` | `document round-trips` | pngData [0,1,2,3]、arrow/text/pixelate の 3 要素、crop (5,5,100,100) → encode→decode で deep-equal(pngData はバイト列比較) |
| (追加) | `golden mac fixture decodes and round-trips` | `tests/fixtures/golden-mac.kakico` を読み、要素 6 件・kind 順 `['arrow','line','rectangle','ellipse','text','pixelate']`・全 id(小文字化済み)・crop (5,5,600,400)・canvasSize 640×480・pngData バイト列一致・`font.family === 'Inter'`(Helvetica Neue マップ)を検証; さらに encode→decode で deep-equal |
| (追加) | `null-valued optionals are omitted on encode` | crop null / fill null の Document をエンコード → `JSON.parse` 結果に `crop`/`fill` キーが存在しない; `version === 1` が存在 |
| (追加) | `reserved kinds throw CodecError` | `{"blur":{"_0":{}}}` / `{"stamp":{"_0":{}}}` を含む elements のデコードが `CodecError` を throw |
| (追加) | `base64 round-trips` | ランダム長 0/1/2/3/255 バイトの `base64ToBytes(bytesToBase64(b))` = b; 不正文字列は CodecError |
| (追加) | `uuid is lowercased and validated` | 大文字 UUID 入力 → 小文字で保持; `"not-a-uuid"` → CodecError |

legacy fixture(`Tests/AnnotationModelTests/AnnotationModelTests.swift:70-75` から逐語コピーしてテストに埋め込む):

```json
[{"arrow":{"_0":{"color":{"a":1,"b":0.22,"g":0.16,"r":0.9},"end":[3,4],"id":"11111111-1111-1111-1111-111111111111","start":[1,2],"width":6}}},{"line":{"_0":{"color":{"a":1,"b":1,"g":0.48,"r":0},"end":[7,8],"id":"22222222-2222-2222-2222-222222222222","start":[5,6],"width":3}}}]
```
