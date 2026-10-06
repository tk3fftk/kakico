# 06 — キャンバス操作 (Canvas Interactions)

## 目的

`Sources/Kakico/CanvasView.swift`(`CanvasNSView`、732 行)のマウス・キーボード・ジェスチャー処理を、純粋な状態機械 `dragMachine` と薄い DOM グルーに分割して移植する。全種類の注釈の作成・選択・移動・リサイズ・削除、インラインテキスト編集、クロップ(marching ants 含む)、ズーム/パンのジェスチャーを Pointer Events / Wheel / Gesture Events 上で再現する。SwiftUI 版と挙動が 1:1 で一致することを、純粋関数のユニットテストと精密な手動チェックで検証する。

## 前提

- `02-project-setup.md` 完了(Vite + Preact + strict TS + vitest + ESLint 境界ルール)。
- `03-model.md` 完了(`src/model/` 全体。特に `resolvePointer`、`movingCorner`、`applyingDefaultInitialSize`、`clampedCrop`、`hitTest`)。
- `04-renderer.md` 完了(`render/renderer.ts` の `skipElement` オプション、`render/text.ts` の `suggestedSize`)。
- `05-state-controller.md` 完了(`canvasStore`、`history` の `beginInteraction`/`commitInteraction`/`perform`、fit 表示のみの `CanvasHost`、`hidpi.ts`)。

## 作成・変更ファイル

新規:

- `kakico-web/src/engine/displayMapping.ts`
- `kakico-web/src/engine/dragMachine.ts`
- `kakico-web/src/engine/input.ts`
- `kakico-web/src/engine/selectionOverlay.ts`
- `kakico-web/src/engine/cropOverlay.ts`
- `kakico-web/src/engine/textEditor.ts`
- `kakico-web/tests/engine/displayMapping.test.ts`
- `kakico-web/tests/engine/dragMachine.test.ts`

05 で実装済み — 内容確認のみ:

- `kakico-web/src/engine/zoomMath.ts`
- `kakico-web/tests/engine/zoomMath.test.ts`

変更:

- `kakico-web/src/engine/CanvasHost.ts` — フレーム合成順序、`reconcileZoom`、ドラッグ中のマッピング凍結、ants スケジューラ統合。
- `kakico-web/src/state/canvasStore.ts` — `applyCrop()` / `cancelCrop()` / `deleteSelection()` が未実装なら追加(05 で実装済みなら確認のみ)。

## 実装手順

### 1. `zoomMath.ts` — 05 で実装済み(仕様照合のみ)

`src/engine/zoomMath.ts` と `tests/engine/zoomMath.test.ts` は `05-state-controller.md` §8 で `ZoomMath.swift` の逐語移植としてテスト込みで先行実装済み。**05 で実装済みならスキップして仕様照合のみ行う**(新規作成しない)。移植仕様の全文は 05 §8 を参照。確認事項:

- 関数名・シグネチャが Swift と同一: `presets` / `percentLabel` / `fittedScale` / `contentSize` / `clampedScale` / `clampedPan` / `imageRect` / `panPreservingCenter` / `panPreservingPoint` / `zoomInScale` / `zoomOutScale`。
- `tests/engine/zoomMath.test.ts` が `Tests/KakicoTests/ZoomMathTests.swift` の全件移植(許容誤差 0.0001)で green。

### 2. `displayMapping.ts` — `DisplayInfo` の移植(Y フリップ削除)

`CanvasNSView` は non-flipped(y-up)なので Swift 版は Y を反転する。Canvas 2D はモデル空間と同じ y-down のため、**Y フリップ項 `canvas.height - ...` を削除する**。それ以外の式は同一。

```ts
// src/engine/displayMapping.ts — 依存: model/, zoomMath のみ(DOM 禁止)
export interface DisplayInfo {
  readonly canvas: Rect;   // モデル空間の outputRect(crop は常に除去済み)
  readonly scale: number;  // CSS px / モデル単位(= Swift の view point / model unit)
  readonly rect: Rect;     // ビュー空間(CSS px)で画像が占める矩形
}

export function modelToView(info: DisplayInfo, p: Point): Point;
// x: rect.x + (p.x - canvas.x) * scale
// y: rect.y + (p.y - canvas.y) * scale          ← Swift 版のフリップを削除

export function viewToModel(info: DisplayInfo, p: Point): Point;
// scale <= 0 → {x: 0, y: 0}
// x: canvas.x + (p.x - rect.x) / scale
// y: canvas.y + (p.y - rect.y) / scale

export function modelTolerance(info: DisplayInfo): number;
// 8 / Math.max(info.scale, 0.0001)   — ヒット許容量は「ビュー 8px 固定」をモデル単位へ換算

export function viewRect(info: DisplayInfo, box: Rect): Rect;
// 対角 2 点を modelToView に通し rectFromCorners で正規化

export function computeDisplayInfo(doc: Document, exportBounds: ExportBounds,
  zoomMode: ZoomMode, pan: Vector, viewport: Size): DisplayInfo;
// displayDoc = { ...doc, crop: null }  ← キャンバスは常に非クロップ全体を表示
// canvas = outputRectFor(displayDoc, exportBounds)   ← 03-model.md §5
// canvas が空 → { canvas, scale: 1, rect: {0,0,0,0} }
// scale: fit → fittedScale(canvas.size, viewport); percent → その値
// rect = imageRect(canvas.size, viewport, scale, pan)
```

参照: `CanvasView.swift:138-190`。

### 3. `dragMachine.ts` — 純粋ドラッグ状態機械

`CanvasNSView` の `mouseDown/mouseDragged/mouseUp`(`CanvasView.swift:372-536`)を、DOM を一切知らない純粋関数に移植する。**判断はすべてここ、副作用は `input.ts`。**

```ts
// src/engine/dragMachine.ts — 依存: model/, displayMapping のみ
export type DragState =
  | { kind: 'none' }
  | { kind: 'moving'; id: ElementID; last: Point }        // 本体ドラッグ(前回モデル点、差分移動)
  | { kind: 'handle'; id: ElementID; role: HandleRole }   // 既存要素のハンドルリサイズ
  | { kind: 'creating'; id: ElementID; role: HandleRole } // down で生成、ライブハンドル追従
  | { kind: 'cropping'; anchor: Point }                   // 対角アンカー固定でクロップ矩形を伸縮
  | { kind: 'movingCrop'; last: Point };                  // クロップ矩形の平行移動

export interface DragContext {
  readonly tool: Tool;
  readonly selection: ElementID | null;
  readonly strokeColor: RGBAColor;
  readonly strokeWidth: number;
}

export type DragInput =
  | { kind: 'down'; modelPoint: Point; viewPoint: Point; clickCount: number }
  | { kind: 'move'; modelPoint: Point }
  | { kind: 'up'; modelPoint: Point };

export interface DragResult {
  readonly state: DragState;
  readonly document: Document;               // 変更なしなら同一参照を返す
  readonly selection: ElementID | null;
  readonly beginTextEdit: ElementID | null;  // input.ts への副作用要求
  readonly freezeMapping: boolean;           // down のみ: state.kind !== 'none' なら true
}

export function dragMachine(state: DragState, input: DragInput,
  doc: Document, ctx: DragContext, info: DisplayInfo): DragResult;
```

#### 3.1 `down` の処理順(`mouseDown`, `CanvasView.swift:372-405`)

1. `clickCount === 2` かつ `hitTest(doc, modelPoint, modelTolerance(info))` が **text** 要素にヒット(**どのツールでも**): `selection = id`、`state = none`、`beginTextEdit = id`、`freezeMapping = false` で return。
2. ツール分岐:
   - `select` → 3.2(creationTool = null)
   - `crop` → 3.3
   - `arrow | line | rectangle | ellipse | text | pixelate` → 3.2(creationTool = tool)
3. `freezeMapping = (state.kind !== 'none')`。クリック経路(テキスト生成・ダブルクリック編集)は凍結しない。

#### 3.2 select / 作成ツール共通(`handlePointerMouseDown`, `:411-428`)

`resolvePointer(doc, modelPoint, selection, { bodyTolerance: tol, handleTolerance: tol })`(tol = `modelTolerance(info)`)の結果で分岐。優先順位は `PointerTarget.swift:20-38` の通り:

| 優先 | 判定 | 結果 |
|---|---|---|
| 1 | 現在選択のハンドル(`distance <= handleTolerance`) | `state = handle(id, role)` — **リサイズが移動に勝つ** |
| 2 | 最前面の本体ヒット(`elements` を末尾から走査) | `selection = id`; `state = moving(id, last: modelPoint)` |
| 3 | 選択要素の `boundingBox().contains(p)`(中空シェイプの内側ドラッグ) | 2 と同じ扱い |
| 4 | empty + select ツール | `selection = null`; `state = none` |
| 4' | empty + 作成ツール | text → 3.4、それ以外 → 3.5。**ツールは自動で切り替えない** |

#### 3.3 crop ツール(`handleCropMouseDown`, `:432-450`)

既存クロップ(`width > 0 && height > 0`)がある場合:

1. **コーナー再編集**: 4 コーナーを `modelToView` に通し、`hypot(v.x - viewPoint.x, v.y - viewPoint.y) <= 8`(**ビュー空間 8px** — 要素ハンドルと違いモデル換算しない)なら `state = cropping(anchor: 対角コーナーのモデル座標)`(TL↔BR、TR↔BL、`HandleRole.opposite`)。
2. **内側**(`crop.contains(modelPoint)`)なら `state = movingCrop(last: modelPoint)`。

それ以外(またはクロップなし): `doc.crop = rectFromCorners(p, p)`(p にゼロサイズ)、`state = cropping(anchor: p)`。

#### 3.4 テキスト生成(`createText`, `:478-489`)

```ts
const element: TextElement = {
  origin: p, size: { width: 220, height: 44 }, string: '',
  font: { family: DEFAULT_FONT_FAMILY /* Inter */, pointSize: Math.max(18, ctx.strokeWidth * 4), bold: true },
  color: ctx.strokeColor,
};
```
`add` → `selection = id` → `state = none` → `beginTextEdit = id`。テキストはクリック配置のみ、ドラッグ生成なし。

#### 3.5 図形生成(`createElement`, `:452-476`)

すべて `p` にゼロサイズで生成し、`add` → `selection = id` → `state = creating(id, role)`:

| tool | 生成 | live handle role |
|---|---|---|
| arrow | `SegmentElement(start: p, end: p, color, width)` | `end` |
| line | 同上 | `end` |
| rectangle / ellipse | `ShapeElement(rect: zeroRect, color, width)`(fill なし) | `bottomRight` |
| pixelate | `RedactionElement(rect: zeroRect, amount: 14)` | `bottomRight` |

#### 3.6 `move`(`mouseDragged`, `:491-513`)

| state | 動作 |
|---|---|
| `none` | 何もしない |
| `moving` | `delta = p - last`; `mutate(id, el => translate(el, delta))`; `last = p` |
| `handle` / `creating` | `mutate(id, el => moveHandle(el, role, p))` — 矩形系は `movingCorner`(対角アンカー、交差反転は min/abs 正規化で自然に処理)、セグメントは start/end を直接更新 |
| `cropping` | `doc.crop = rectFromCorners(anchor, p)` |
| `movingCrop` | `crop = offsetBy(crop, p.x - last.x, p.y - last.y)`; `last = p` |

**修飾キーの処理は一切ない**(Shift 正方形拘束・45° スナップ・中心リサイズ・Option 複製はすべて原典に存在しない。追加禁止)。

#### 3.7 `up`(`mouseUp`, `:515-536`)

1. `creating` なら `mutate(id, el => applyingDefaultInitialSize(el))` — Skitch 式クリック配置。生の広がり(セグメント長、または `max(w, h)`)が **3 未満**ならデフォルトサイズに置換: arrow/line は `end = start + (100, 70)`、rect/ellipse/pixelate は **クリック点中心の 120×90**。それ以外は no-op。
2. `cropping | movingCrop` なら `doc.crop = clampedCrop(doc, crop)` — キャンバス矩形と交差、`width < 2 || height < 2` なら null(クロップ消滅)。
3. `state = none` を返す。

### 4. `input.ts` — DOM イベント → dragMachine / zoomMath アダプタ

キャンバスコンテナ要素にリスナーを張る薄いグルー。判断ロジック禁止。

#### 4.1 Pointer(macOS mouse 系の対応)

| macOS | web |
|---|---|
| `mouseDown` (clickCount) | `pointerdown`(`e.button === 0` のみ、`e.detail` を clickCount として渡す)+ `setPointerCapture(e.pointerId)` |
| `mouseDragged` | `pointermove`(capture 中のみ) |
| `mouseUp` | `pointerup` / `pointercancel` |

`pointerdown` ハンドラの順序(Swift と同一):

1. `textEditor.commit()`(開いているインラインエディタは**どのクリックでも**コミット)。
2. `store` に document がなければ return。
3. `info = computeDisplayInfo(...)`(ライブ)、`viewPoint` = コンテナ相対 CSS px(`getBoundingClientRect` 基準)、`p = viewToModel(info, viewPoint)`。
4. `history.beginInteraction()`。
5. `dragMachine(state, {kind:'down', ...}, ...)` を呼び、`document`/`selection` を store へ反映、`beginTextEdit` があれば `textEditor.begin(id)`。
6. `freezeMapping` なら `dragDisplayInfo = info` を保持(**ドラッグ全期間この凍結マッピングを使用**。理由: expandToFit では画像端を越えるドラッグがキャンバス矩形を成長させ、マッピングが動くと暴走リサイズになる。`CanvasView.swift:57-61`)。

`pointermove`: `info = dragDisplayInfo ?? live`; `dragMachine(move)`。
`pointerup`: `dragDisplayInfo = null`; `dragMachine(up)`; `history.commitInteraction()`(document が変わっていた場合のみ undo 1 段。**クリックのみで変更なしなら何も積まれない**)。

その他: canvas コンテナに `touch-action: none`、`contextmenu` は `preventDefault()`(原典に右クリックメニューなし)、`user-select: none`。

#### 4.2 Wheel パン(`scrollWheel`, `:540-561`)

`wheel` リスナー(`{ passive: false }`)。`e.ctrlKey === true` はピンチ(4.3)へ。それ以外はパン:

- ガード(すべて満たさない場合は何もしない。ただし `preventDefault()` は常に呼びページスクロール・スワイプバックを止める):
  1. document あり
  2. `zoomMode.kind === 'percent'`(**fit モードではパン不可**)
  3. `drag.kind === 'none'`(注釈ドラッグ中はパン禁止)
  4. `content.width > viewport.width || content.height > viewport.height`(収まっているなら中央固定)
- 更新: `pan.dx -= e.deltaX; pan.dy -= e.deltaY`。
  - 符号根拠: Swift は `dx += scrollingDeltaX; dy -= scrollingDeltaY`(non-flipped y-up ビュー、`CanvasView.swift:556-557`)。DOM wheel の delta は scrollingDelta と逆符号、かつ web は y-down のため両軸とも `-=` になる。指の動きにコンテンツが追従することが不変条件。
- `pan = clampedPan(pan, content, viewport)`; `textEditor.syncFrame()`(パン中も入力中エディタが要素に張り付く); 再描画スケジュール。

#### 4.3 ピンチズーム(`magnify`, `:565-589`)

| macOS | web |
|---|---|
| `magnify` イベント(`1 + magnification` を累積) | Chrome/Firefox: `wheel` + `ctrlKey`(トラックパッドピンチ)→ `factor = Math.exp(-e.deltaY * 0.01)` |
| 同上 | Safari: `gesturestart/gesturechange/gestureend`(`e.scale` は gesture 開始からの累積倍率)。3 イベントとも `preventDefault()` |
| スマートズーム(2 本指ダブルタップ) | **対応しない**(原典に無し) |
| スクロールホイールズーム | **対応しない**(原典に無し) |

共通処理(1 イベントごと):

1. ガード: document あり、`drag.kind === 'none'`。
2. `newScale = clampedScale(oldScale * factor, canvas.size, viewport)`(Safari gesture は `gesturestart` 時の scale を base に `base * e.scale`)。クランプ域は `[min(0.25, fittedScale), 4.0]`。
3. `newScale === oldScale` なら return。
4. インラインエディタが開いていれば `commit()`(フォントに旧スケールが焼き込まれているため)。
5. `anchor` = カーソルのコンテナ相対座標。`pan = panPreservingPoint(anchor, pan, oldScale, newScale, canvas.size, viewport)` → `clampedPan`。
6. `store.setZoom(newScale)`(→ `percent`)+ **即座に** `store.reportEffectiveZoomScale(newScale)`(直後の `reconcileZoom` がカーソルアンカー済みパンを中心アンカーで上書きするのを防ぐ。`CanvasView.swift:584-587`)。

#### 4.4 キャンバスキーボード(`keyDown`, `:593-616`)

`window` への capture-phase `keydown`。`store.isEditingText === true` の間、および `e.target` が input/textarea の場合はすべて素通し。

| macOS keyCode | web `e.key` | 動作 |
|---|---|---|
| 51 (Delete) / 117 (Fwd Delete) | `'Backspace'` / `'Delete'` | `store.deleteSelection()`(undo 1 段) |
| 36 (Return) / 76 (Enter) | `'Enter'` | `doc.crop != null` なら `store.applyCrop()`、なければ素通し |
| 53 (Esc) | `'Escape'` | `doc.crop != null` なら `store.cancelCrop()`、**なければ** `selection = null` |

矢印キーによる移動・ナッジは**原典に存在しない**。追加禁止。

#### 4.5 カーソル・ホバー

**原典にカーソル変更・ホバーフィードバックは一切ない**(`NSCursor`/tracking area 不使用を grep で確認済み)。canvas コンテナは `cursor: default` 固定。ハンドル上・要素上・ドラッグ中もカーソルを変えない。ホバーハイライトも実装しない。

### 5. `selectionOverlay.ts` — 選択枠とハンドル(`drawSelection`/`drawHandle`, `:288-307`)

```ts
export function drawSelection(ctx: CanvasRenderingContext2D, element: Annotation, info: DisplayInfo): void;
export function drawHandle(ctx: CanvasRenderingContext2D, center: Point, strokeStyle: string, lineWidth: number): void;
```

- 選択枠: `viewRect(info, boundingBox(element))` を **各辺 2px 外側に拡張**(`insetBy(-2,-2)`)し、`#4262FF`、線幅 2 でストローク。
- ハンドル: `element.handles()` の各位置(セグメント: start/end、矩形系: 4 コーナー)に **9×9 CSS px の円**(中心 −4.5)。白塗り + `#4262FF` 線幅 **1.5**。
- DOM ハンドルは作らない。すべて canvas 内に描画。
- 注: セグメント/シェイプの `boundingBox()` はモデル側で `-width` インセット済み(ストローク張り出しを含む)。オーバーレイ側で追加調整しない。

### 6. `cropOverlay.ts` — クロップオーバーレイ + marching ants(`drawCropOverlay`/`updateAntsTimer`, `:309-360`)

```ts
export function drawCropOverlay(ctx: CanvasRenderingContext2D, viewCrop: Rect, imageRect: Rect,
  redrawContent: (ctx: CanvasRenderingContext2D) => void, antsPhase: number): void;

export class AntsScheduler {  // 12 Hz で phase を進め再描画を要求
  start(requestDraw: () => void): void;  // setInterval(1000 / 12); tick ごとに phase += 1
  stop(): void;
  readonly phase: number;
}
```

描画手順(順序厳守):

1. `imageRect` 全体を `rgba(0,0,0,0.45)` で塗る(減光)。
2. `save()` → `clip(viewCrop)` → `redrawContent(ctx)`(フラット済みレイヤ + ベクターレイヤをクロップ内に再描画)→ `restore()`。クロップ窓内は全輝度。
3. 下地アウトライン: `rgba(0,0,0,0.55)`、線幅 1、実線で `viewCrop` をストローク(明るい画像上でも白破線が見えるように)。
4. marching ants: 白、線幅 1、`setLineDash([5, 4])`、`lineDashOffset = -antsPhase` で `viewCrop` をストローク。描画後 `setLineDash([])` に戻す。
5. 4 コーナーに 9×9 白円ハンドル、`#4262FF`、線幅 **1**(選択ハンドルの 1.5 と異なる)。

AntsScheduler の稼働条件: `doc.crop != null` の間のみ。`visibilitychange` で hidden になったら `stop()`、visible 復帰で再開(macOS の `didResignActive`/`didBecomeActive` 対応、`CanvasView.swift:105-112`)。`CanvasHost.dispose()` でも `stop()`。

クロップ適用/キャンセル(store 側、`CanvasController.swift:286-306`):

- `applyCrop()`: `integralCrop`(clamp + 整数ピクセルスナップ)で `baseBitmap` を切り出し、`crop = null`、`canvasSize = clamped.size`、全要素を `(-clamped.x, -clamped.y)` 平行移動。undo スナップショットは **document + bitmap 両方**(破壊的)。
- `cancelCrop()`: `perform(doc => { doc.crop = null })`(undo 可能)。

### 7. `textEditor.ts` — インラインテキスト編集(`:640-731`)

canvas コンテナ内の絶対配置 `<textarea>`(1 個のみ)。

```ts
export class TextEditorOverlay {
  begin(id: ElementID): void;
  syncFrame(): void;          // パン・入力時の追従
  commit(): void;             // 冪等。エディタ非表示なら no-op
  readonly isActive: boolean;
  dispose(): void;
}
```

#### begin(`beginTextEditing`, `:649-669`)

1. 既存エディタがあれば先に `commit()`。
2. frame = `viewRect(info, boundingBox(element))` を **各辺 2px 拡張**(エディタクロームの余白)。
3. スタイル: `font-family` = 要素の family(バンドル Inter に解決)、`font-weight: 700`(bold=true 時)、**`font-size = pointSize × info.scale` px**(表示ズームを焼き込む)、`color` = 要素色、`background: color-mix(in srgb, var(--kk-text-background) 90%, transparent)`(Swift の `NSColor.textBackgroundColor.withAlphaComponent(0.9)` 相当、`CanvasView.swift:660`)、`resize: none; border: none; overflow: hidden; white-space: pre-wrap`。`line-height` は `render/text.ts` の折り返しと同一値。
   - `--kk-text-background` は `07-ui-chrome.md` §1 の `theme.css` で定義済み(`:root` にライト `#FFFFFF`、`prefers-color-scheme: dark` ブロックにダーク `#1E1E1E`。macOS の `textBackgroundColor` ライト白 / ダーク暗色に対応)。本ステップでは参照するのみで再定義しない。
4. `value = element.string`、`focus()`、`store.isEditingText = true`(単文字ツールショートカット抑止)。

#### 入力中の自動リサイズ(`textDidChange` → `syncTextEditorFrame`, `:674-682`)

`input` イベントごと: 現在の `textarea.value` をスクラッチ TextElement にコピー → `suggestedSize()`(`render/text.ts`。幅は要素の現幅固定、`height = max(ceil(fitHeight) + 2, pointSize + 8)`、空文字は 1 行分 `pointSize + 8`)→ そのモデル矩形を `viewRect` + 2px 拡張でエディタに再設定。パン後(4.2)にも同じ関数を呼ぶ。

#### commit(`commitTextEditing`, `:684-707`)

トリガー: (a) キャンバスへの任意の `pointerdown`、(b) `blur`(フォーカス喪失)、(c) ズームスケール変化(reconcile / ピンチ)、(d) 別要素の編集開始、(e) **Esc キー**。

処理: textarea を除去、`isEditingText = false`。最終文字列が**空なら要素を削除**(選択中なら解除)。空でなければ `perform(doc => { t.string = newString; t.size = suggestedSize(t) })` — undo 1 段。

**「前のテキストに戻すキャンセル」は存在しない**(`CanvasView.swift` にキャンセル経路なし)。Esc も blur と同じくコミットする。Enter は改行(textarea 既定動作、抑止しない — NSTextView と同じ複数行編集)。

編集中のレンダリング: `render()` に `skipElement: editingTextID` を渡し、canvas 側の該当テキスト描画をスキップ(半透明エディタ越しの二重描画を防ぐ。Mac 版は下に描いたまま被せるが、web は skip 方式が正 — アーキテクチャ決定 §6)。

### 8. `CanvasHost.ts` 変更 — reconcileZoom とフレーム合成

#### reconcileZoom(`:206-236`) — 毎フレーム描画前に実行

1. `dragDisplayInfo != null` なら**まるごとスキップ**(ドラッグ中は凍結)。
2. `zoomMode.kind === 'fit'` → `pan = {dx: 0, dy: 0}`。
3. `info = computeDisplayInfo(...)`。`info.scale !== store.effectiveZoomScale` の場合:
   - percent モードなら `pan = panPreservingCenter(pan, old, info.scale)` して rect を再計算(⌘+/⌘−/メニューズームが**ビュー中心アンカー**になる根拠)。
   - エディタが開いていれば `textEditor.commit()`。
   - `store.reportEffectiveZoomScale(info.scale)`。
4. `pan = clampedPan(pan, info.rect.size, viewport)`; `reconciledInfo = info`。

#### フレーム合成順序(`draw`, `:243-286`)

`info = dragDisplayInfo ?? reconciledInfo ?? live` を選択し、1 rAF 内で:

1. Layer A(フラット済みキャッシュ)を `imageRect = viewRect(info, outputRectFor(flattenedKeyDoc, exportBounds))`(`outputRectFor` は 03-model.md §5)へ描画(`imageSmoothingQuality = 'high'`)。凍結マッピング中は成長分がはみ出して描かれる(fit 矩形に押し込まない)。
2. Layer B(ベクター)を `render(doc, ctx, ...)` 相当で描画(`skipElement` 適用)。
3. `doc.crop != null` なら `drawCropOverlay(...)`(redrawContent = 手順 1+2 の再実行)。
4. AntsScheduler の start/stop を crop の有無で切替。
5. `selection` が要素に解決すれば `drawSelection(...)`。

**レイヤの内容分担(01 §レンダリングの確定仕様)**: Layer A = base 画像 + pixelate 要素のみ(host が「pixelate 以外の要素を除き `crop: null` にした doc コピー」を `flatten()` に渡す)。Layer B = pixelate 以外の全要素(同様に「pixelate を除いた doc コピー」を `render()` に渡す)。renderer 側の変更は不要 — フィルタは doc コピーで行う。

**フラットキャッシュ(Layer A)の無効化規則 — 確定仕様。`documentVersion` 単独をキーにしない**:

1. **ドラッグ中(`dragDisplayInfo != null`)は Layer A を凍結** — キャッシュキーの評価自体をスキップし、再 flatten しない。`documentVersion` は移動・リサイズの**毎 pointermove で +1** される(05 §3)ため、これをそのまま無効化キーにすると 4K 画像でドラッグの毎フレームに OffscreenCanvas 新規確保 + ベース画像全面 drawImage が走る(フレーム落ち + GC 圧)。ドラッグ中の要素表示は Layer B のライブ vector 描画が担う。
2. 再 flatten のタイミングは **`commitInteraction`(pointerup)後の最初のフレーム**、および undo / redo / applyCrop / loadImage / テキスト commit / 色・線幅確定などの非ドラッグ経路の変化時のみ。キャッシュキーは(pixelate 要素配列の値比較, `baseBitmap` 参照)。
3. クロップ矩形のドラッグは version を進めるが Layer A 内容(base + pixelate)は不変 — キー比較により再フラットしない(`CanvasView.swift:248-262` と同じ帰結)。
4. **pixelate 要素のドラッグ**だけは例外扱い: ドラッグ開始時(`beginInteraction`)に「当該 pixelate を除いた」Layer A を 1 回だけ再 flatten して凍結し、ドラッグ中は Layer B が当該 pixelate を `drawPixelate` でライブ描画する(base bitmap は Layer B からも参照可)。pointerup で通常の再 flatten に戻る。ドラッグ中の再 flatten は 1 要素あたり開始時の 1 回のみ。

### 9. store アクション確認

`canvasStore.ts` に以下があることを確認(なければ本ステップで追加): `applyCrop()`、`cancelCrop()`、`deleteSelection()`、`setZoom(scale)`、`reportEffectiveZoomScale(scale)`。仕様は手順 6 と `CanvasController.swift:270-306` に従う。

## 定数・仕様表

| 項目 | 値 | Swift 原典 |
|---|---|---|
| ヒット許容量 | ビュー 8px 固定 → `8 / max(scale, 0.0001)` モデル単位 | CanvasView.swift:154 |
| viewToModel ゼロ除算ガード | `scale <= 0 → (0,0)` | CanvasView.swift:149 |
| 選択枠 色/線幅/インセット | `#4262FF` / 2px / boundingBox を −2 拡張 | CanvasView.swift:299-301; Theme.swift:34 |
| ハンドル円 | 9×9(中心 −4.5)、白塗り | CanvasView.swift:289-290 |
| 選択ハンドル枠線幅 | 1.5 | CanvasView.swift:305 |
| クロップハンドル枠線幅 | 1 | CanvasView.swift:333 |
| クロップ減光 | black alpha 0.45 | CanvasView.swift:311 |
| ants 下地 | black alpha 0.55、線幅 1 | CanvasView.swift:322-323 |
| ants 破線 | 白、線幅 1、dash `[5, 4]`、offset = phase | CanvasView.swift:325-326 |
| ants 周期 | `1/12` 秒(12 Hz)、tick ごと `phase += 1` | CanvasView.swift:339-342 |
| クロップコーナー掴み半径 | ビュー空間 `hypot <= 8` px | CanvasView.swift:437 |
| クロップ最小サイズ | 幅・高さとも `>= 2`(未満で null) | Document.swift:71 |
| クロップ適用スナップ | clamp 後 `.integral`(整数ピクセル) | Document.swift:77-79 |
| ダブルクリック判定 | `clickCount == 2`(web: `e.detail === 2`) | CanvasView.swift:381 |
| クリック配置しきい値 | 生の広がり `< 3` モデル単位 | Geometry.swift:63 |
| デフォルトセグメント | `end = start + (100, 70)` | Geometry.swift:65 |
| デフォルト矩形 | 120×90、クリック点中心 | Geometry.swift:67, 70-73 |
| 新規テキスト箱 | 220×44 | CanvasView.swift:480 |
| 新規テキスト pointSize | `max(18, strokeWidth * 4)` | Geometry.swift:41-43 |
| pixelate 初期 amount | 14 | Elements.swift:134 |
| エディタ frame インセット | viewRect を各辺 −2(2px 拡張) | CanvasView.swift:645-646 |
| エディタ背景 | textBackground alpha 0.9 | CanvasView.swift:660 |
| エディタ font-size | `pointSize × 表示 scale` | CanvasView.swift:724-726 |
| テキスト最小高さ | `pointSize + 8`; 実測 `max(ceil(fitHeight) + 2, pointSize + 8)` | Renderer.swift:171, 178 |
| ズームプリセット | `[0.25, 0.5, 1.0, 2.0, 4.0]` | ZoomMath.swift:14 |
| スケールクランプ | `[min(0.25, fittedScale), 4.0]` | ZoomMath.swift:35-38 |
| パンクランプ | 軸ごと `slack = (content − viewport)/2`; `slack <= 0 → 0` | ZoomMath.swift:42-50 |
| zoomIn/Out イプシロン | `current × 1.001` / `current × 0.999` | ZoomMath.swift:92-99 |
| ピンチ倍率(macOS) | `oldScale × (1 + magnification)` | CanvasView.swift:573 |
| ピンチ倍率(web ctrl+wheel) | `oldScale × exp(-deltaY × 0.01)` | アーキテクチャ決定 §6(web 側規約) |
| ホイールパン符号(macOS) | `dx += scrollingDeltaX; dy -= scrollingDeltaY`(y-up) | CanvasView.swift:556-557 |
| ホイールパン符号(web) | `dx -= e.deltaX; dy -= e.deltaY`(y-down + delta 逆符号) | 上記からの導出(§4.2) |
| キー: 削除 | keyCode 51/117 → `Backspace`/`Delete` | CanvasView.swift:596 |
| キー: クロップ適用 | keyCode 36/76 → `Enter` | CanvasView.swift:599 |
| キー: Esc | keyCode 53 → crop キャンセル、なければ選択解除 | CanvasView.swift:606-611 |
| カーソル | 常に default(変更なし・ホバーなし) | 原典に NSCursor 不使用(grep 確認) |
| ドラッグ中の修飾キー | なし(拘束・複製なし) | 原典に修飾キー処理なし(grep 確認) |
| ZoomMath テスト許容誤差 | 0.0001 | Tests/KakicoTests/ZoomMathTests.swift:7 |

## 受け入れ基準

CI ゲート:

- [ ] `cd kakico-web && npx tsc --noEmit` が成功する。
- [ ] `cd kakico-web && npx eslint .` が成功する(`engine/dragMachine.ts`・`displayMapping.ts`・`zoomMath.ts` に DOM import がないことを境界ルールが保証)。
- [ ] `cd kakico-web && npx vitest run` が全件緑(zoomMath / displayMapping / dragMachine スイート含む)。
- [ ] `cd kakico-web && npx vite build` が成功する。

手動チェック(Chrome。画像を 1 枚開いた状態から):

- [ ] arrow ツールで空白を**クリックのみ**(3px 未満) → クリック点から右下 (100, 70) の矢印が生成され選択される。⌘Z で消える。
- [ ] rectangle ツールでクリックのみ → クリック点を中心に 120×90 の矩形が生成される。ellipse/pixelate も同様。
- [ ] text ツールでクリック → 220×44 の位置に textarea が現れフォーカスされる。何も入力せずコミット(キャンバス外クリック等)→ 要素は消える。⌘Z 1 回で空テキスト要素が再出現し、もう 1 回の ⌘Z で作成前に戻る(作成と削除がそれぞれ 1 undo ステップ)。
- [ ] arrow をドラッグ生成 → 終点がカーソルに追従。ドラッグ距離 3px 以上ならその形のまま確定し、⌘Z 1 回で全体が消える(生成+リサイズが 1 undo)。
- [ ] 作成ツール(例: arrow)のまま既存要素の本体をクリック → 選択されて移動でき、**新規要素は生成されず、ツールも切り替わらない**。
- [ ] 選択中の矩形のコーナーハンドル(9px 円)をドラッグ → 対角コーナーが固定されたままリサイズ。対角を**越えて**ドラッグすると矩形が反転して追従する。
- [ ] 選択中の(塗りなし)矩形の内側の空洞部分をドラッグ → 移動できる(選択枠内側ルール)。非選択の矩形は空洞クリックでヒットせず、縁のみでヒットする。
- [ ] ハンドル位置と本体が重なる位置でポインタダウン → **リサイズが優先**される。
- [ ] どのツールでもテキスト要素をダブルクリック → インライン編集が始まる。編集中に v/a/l 等を打ってもツールが切り替わらない(文字が入力される)。
- [ ] 編集中に文字を追加し続ける → textarea の高さが 1 行ずつ伸び、canvas 側の該当テキストは描画されない(スキップ)。blur でコミットされ、canvas 描画と textarea の折り返し位置が一致していた。
- [ ] 編集中に Esc → 現在の内容で**コミット**される(元の文字列には戻らない)。
- [ ] crop ツールでドラッグ → 白破線 + 黒下地のクロップ枠。枠外が 45% 減光、枠内は全輝度。破線が約 12 Hz で流れる(marching ants)。タブを非表示にして戻ると再開する。
- [ ] クロップコーナー(8px 以内)をドラッグ → 対角固定で再編集。内側ドラッグ → 枠全体が移動。枠外で新規ドラッグ → 新しい枠に置き換わる。
- [ ] クロップ枠を画像外へドラッグしてから up → 枠がキャンバス内にクランプされる。2×2 未満に潰すと枠が消える。
- [ ] クロップ表示中に Enter → 破壊的に適用され画像が切り替わり、サイズバッジが新サイズになる。⌘Z → 画像・注釈とも完全に復元。
- [ ] クロップ表示中に Esc → 枠が消える(⌘Z で戻る)。クロップなしで Esc → 選択が解除される。
- [ ] Backspace / Delete → 選択要素が削除される。テキスト編集中の Backspace は文字削除のみ(要素は消えない)。
- [ ] exportBounds = expandToFit で矢印を画像端の外へドラッグ → ドラッグ中はカーソルと要素が 1:1 で追従し(暴走なし)、up した瞬間にキャンバスが成長分を含めて再フィットする。
- [ ] 4K 級の画像を開いて要素を連続ドラッグ → DevTools Performance で記録し、ドラッグ中に `flatten`(OffscreenCanvas 確保 + 全面 drawImage)が毎フレーム走っていないこと(再 flatten は pointerup 後の 1 回のみ)。
- [ ] トラックパッドでピンチ(または Chrome で Ctrl+ホイール) → **カーソル直下の画像点が固定**されたままズーム。400% 超・フロア未満にはならない。ズーム % 表示が連続値で追従する。
- [ ] 100% 超で 2 本指スクロール → 画像が指に追従してパンし、端が viewport 内側に入らない。fit モードではスクロールしても動かない。注釈ドラッグの最中はパン・ズームとも効かない。
- [ ] ピンチ中にテキスト編集が開いていた → ズーム開始時点でコミットされる。パン中は textarea が要素に張り付いたまま動く。
- [ ] 要素・ハンドル・クロップ枠のどこにポインタを置いてもカーソルは default のまま変化しない。右クリックでブラウザのコンテキストメニューが出ない。
- [ ] Safari で gesturechange ピンチが同様に動く(カーソルアンカー・クランプ)。

## テスト

### `tests/engine/zoomMath.test.ts`(ZoomMathTests.swift の全件移植、許容誤差 0.0001)

- `fittedScale returns min ratio`, `fittedScale degenerate canvas returns 1`
- `clampedScale floors at min(0.25, fitted)`: 1000×1000 canvas / 100×100 viewport → floor 0.1
- `clampedScale caps at 4.0`
- `clampedPan zero when content fits`, `clampedPan clamps to ±slack`
- `imageRect centers content then applies clamped pan`; 極端な pan で辺が viewport 辺に一致
- `panPreservingCenter keeps center model point fixed`; scale 不変で恒等
- `panPreservingPoint keeps cursor model point fixed`(数点で `viewToModel(before) == viewToModel(after)` を検証)
- `panPreservingPoint at viewport center equals panPreservingCenter`
- `zoomInScale: 0.63→1.0, 1.0→2.0, 4.0→4.0, 10→4.0`
- `zoomOutScale: 0.63→0.5, 1.0→0.5, 0.25→0.25, 0.1→0.25`
- `percentLabel rounds`: 0.63 → "63%"

### `tests/engine/displayMapping.test.ts`

- `modelToView/viewToModel round-trip`: 任意の点で往復一致(y-down、フリップなしを固定)
- `viewToModel with zero scale returns origin`
- `modelTolerance is 8 view px in model units`: scale 2 → 4、scale 0.5 → 16
- `computeDisplayInfo strips crop`: crop 付き document でも canvas は非クロップ outputRect
- `computeDisplayInfo expandToFit grows canvas with out-of-image element`
- `viewRect normalizes corners`(負方向の矩形)

### `tests/engine/dragMachine.test.ts`(合成ポインタシーケンス)

- `click-only arrow gets default size (100,70)`: down→up(移動なし)で `end - start == (100, 70)`、up 結果 state none
- `drag beyond threshold keeps dragged geometry`: down→move(+50,+10)→up でサイズ維持
- `click-only rectangle centers 120x90 on click point`(ellipse/pixelate も同型でパラメトライズ)
- `pixelate created with amount 14`
- `creation tool on existing body selects and moves instead of creating`: 要素数不変・selection 更新・moving 状態
- `handle beats body at overlapping point`: 選択要素のハンドル半径内 down → state handle
- `handle resize anchors opposite corner`: bottomRight ドラッグ中 topLeft 不変; 対角越えで反転矩形
- `selection frame interior drags hollow shape`: 塗りなし矩形選択中、内部点 down → moving
- `empty click with select tool clears selection`
- `double-click text element in arrow tool requests text edit`: `beginTextEdit == id`、state none、freezeMapping false
- `text tool click creates 220x44 empty text and requests edit`
- `text pointSize = max(18, strokeWidth*4)`: strokeWidth 6 → 24; strokeWidth 2 → 18
- `crop drag creates rect from anchor`, `crop corner grab within 8 view px resizes against opposite`, `crop corner grab at 9 view px starts new rect`
- `crop body drag moves rect`, `crop clamped on up`: キャンバス外→交差矩形、1×1 → crop null
- `freezeMapping true only for drag states`: creating/moving/handle/cropping/movingCrop で true、テキスト生成・ダブルクリックで false
- `document reference unchanged when nothing happens`(empty click + select)

### `tests/state/`(05 のスイートへ追加)

- `applyCrop swaps bitmap and translates elements; undo restores both`(OffscreenCanvas スタブ)
- `cancelCrop is one undoable step`
- `drag interaction is exactly one undo step`(beginInteraction → 複数 mutate → commitInteraction)
- `no-op interaction pushes nothing`(begin → commit、変更なし)

### 手動確認用開発ページ

vitest 対象外。`04-renderer` の dev ページを流用し、`CanvasHost` + `input.ts` を繋いだ状態で上記手動チェックを実施する(新規ファイル追加は不要、既存 dev エントリに mount するだけにする)。
