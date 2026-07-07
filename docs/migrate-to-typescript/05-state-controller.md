# 05: State Controller — CanvasStore / History / Tool / ZoomMath の移植

## 目的

`Sources/Kakico/CanvasController.swift`(`@Observable` な状態ルート)、`Tool.swift`、`ZoomMath.swift` を `kakico-web/src/state/` と `src/engine/zoomMath.ts` に移植する。スナップショット方式の undo/redo、選択と色・線幅コントロールの双方向同期、500 ms カラーデバウンス、crop ライフサイクル、ズーム演算を Swift と同一のセマンティクスで実装する。あわせて画像読み込み(open / paste / drop)、fit 表示のみの最小 `CanvasHost`、画像サイズバッジ、PNG ダウンロードを配線し、このマイルストーン完了時点でアプリが最小限使える状態にする。

## 前提

- `02-project-setup.md` 完了(Vite + Preact + strict TS + vitest + ESLint 境界ルール + `theme.css`)。
- `03-model.md` 完了(`src/model/` 全体。特に `Document` / `outputRect` / `integralCrop` / `documentsEqual` / `RGBAColor` / `FontSpec` / `ElementID`)。`documentsEqual(a: Document, b: Document): boolean`(深い構造的等値)が未定義なら本ステップで `src/model/document.ts` に追加する。
- `04-renderer.md` 完了(`render()` / `flatten()` / `encode()` / `suggestedSize()`。`applyStrokeWidthToSelection` と PNG エクスポートが依存)。

## 作成・変更ファイル

新規:

- `kakico-web/src/state/store.ts` — 汎用 observable store
- `kakico-web/src/state/tool.ts` — `Tool` union(≙ `Sources/Kakico/Tool.swift`)
- `kakico-web/src/state/canvasStore.ts` — `CanvasState` + `CanvasStore`(≙ `CanvasController.swift`)
- `kakico-web/src/state/history.ts` — undo/redo スタック
- `kakico-web/src/engine/zoomMath.ts` — `ZoomMath.swift` の逐語移植(純粋関数。マイルストーン 06 が消費するが、テスト込みでここで先行実装)
- `kakico-web/src/engine/hidpi.ts` — DPR 追従キャンバスサイズ
- `kakico-web/src/engine/CanvasHost.ts` — 最小版(fit 描画 + effectiveZoomScale 報告のみ。ドラッグ操作は doc 06)
- `kakico-web/src/platform/imageLoad.ts` — File/Blob/DataTransfer → ImageBitmap
- `kakico-web/src/platform/persistence.ts` — `exportBounds` の localStorage 永続化
- `kakico-web/src/ui/CanvasMount.tsx` — `CanvasHost` ブリッジ
- `kakico-web/src/ui/ImageSizeBadge.tsx` — サイズバッジ
- `kakico-web/tests/engine/zoomMath.test.ts`
- `kakico-web/tests/state/history.test.ts`
- `kakico-web/tests/state/selectionSync.test.ts`
- `kakico-web/tests/state/colorDebounce.test.ts`
- `kakico-web/tests/state/crop.test.ts`
- `kakico-web/tests/state/canvasStore.test.ts`

変更:

- `kakico-web/src/ui/App.tsx` — EmptyState / CanvasMount / ImageSizeBadge の切り替え配線
- `kakico-web/src/main.tsx` — paste / dragover / drop リスナー、store 生成
- `kakico-web/package.json` — `npm i -D happy-dom`(`tests/state/canvasStore.test.ts` の localStorage テストが happy-dom 環境を要求。doc 07 の UI テストでも再利用)

## 実装手順

### 1. `src/state/tool.ts` — Tool union

`Tool.swift` の 8 ケースを宣言順どおりに移植する。**配列順がレガシー数字ショートカット 0–7 の定義**(doc 07 で使用)。

```ts
// ≙ Sources/Kakico/Tool.swift
export type Tool =
  | 'select' | 'arrow' | 'line' | 'rectangle'
  | 'ellipse' | 'text' | 'pixelate' | 'crop';

/** Declaration order = legacy digit shortcuts 0–7 (Tool.allCases). */
export const allTools: readonly Tool[] =
  ['select', 'arrow', 'line', 'rectangle', 'ellipse', 'text', 'pixelate', 'crop'];

export const toolLabel: Record<Tool, string> = {
  select: 'Select', arrow: 'Arrow', line: 'Line', rectangle: 'Rectangle',
  ellipse: 'Ellipse', text: 'Text', pixelate: 'Pixelate', crop: 'Crop',
};

/** Miro-style single-letter shortcut (unmodified keydown, doc 07). */
export const toolShortcutKey: Record<Tool, string> = {
  select: 'v', arrow: 'a', line: 'l', rectangle: 'r',
  ellipse: 'o', text: 't', pixelate: 'p', crop: 'c',
};

/** Icon id consumed by ui/icons.tsx (replaces SF Symbols). */
export const toolIconId: Record<Tool, string> = {
  select: 'cursor', arrow: 'arrow-up-right', line: 'line-diagonal',
  rectangle: 'rectangle', ellipse: 'circle', text: 'text',
  pixelate: 'pixelate-grid', crop: 'crop',
};
```

ツール切り替えは**副作用なし**(選択をクリアしない、コミットしない。CanvasController.swift:22 の plain stored property と同じ)。

### 2. `src/state/store.ts` — 汎用 store

```ts
export interface ReadonlyStore<T> {
  getSnapshot(): T;
  subscribe(listener: () => void): () => void;   // returns unsubscribe
}

export interface Store<T> extends ReadonlyStore<T> {
  set(next: T): void;
  update(fn: (prev: T) => T): void;
}

export function createStore<T>(initial: T): Store<T>;
```

- `set`/`update` は即座に snapshot を差し替え、**通知は microtask でバッチ**する(1 tick 内の複数更新で listener は 1 回)。`queueMicrotask` + フラグで実装。
- Preact は `useSyncExternalStore(store.subscribe, store.getSnapshot)` で消費。`CanvasHost` は `subscribe` 直結で rAF を 1 回スケジュール。

### 3. `src/state/canvasStore.ts` — 状態 shape

アーキテクチャ仕様 §4 の shape をそのまま使う。各フィールドの Swift 対応:

```ts
import type { Document, ElementID, RGBAColor, Vector, ExportBounds } from '../model/...';
import type { Tool } from './tool';
import type { ZoomMode } from '../engine/zoomMath';

export interface CanvasState {
  readonly document: Document | null;        // ≙ CanvasController.document
  readonly baseBitmap: ImageBitmap | null;   // ≙ baseImage (CGImage?)
  readonly sourceName: string | null;        // ≙ sourceURL — web にパスはないので filename のみ保持
  readonly documentVersion: number;          // ≙ documentVersion (&+= 1; TS では +1 で可)
  readonly selection: ElementID | null;      // ≙ selection
  readonly tool: Tool;                       // ≙ tool、初期値 'arrow'
  readonly strokeColor: RGBAColor;           // ≙ strokeColor、初期値 RGBAColor.red
  readonly strokeWidth: number;              // ≙ strokeWidth、初期値 6
  readonly zoomMode: ZoomMode;               // ≙ zoomMode、初期値 { kind: 'fit' }
  readonly pan: Vector;                      // ≙ CanvasNSView.panOffset(web では store に置く)
  readonly effectiveZoomScale: number;       // ≙ effectiveZoomScale、初期値 1
  readonly exportBounds: ExportBounds;       // ≙ exportBounds、localStorage 永続化
  readonly isEditingText: boolean;           // ≙ isEditingText、初期値 false
  readonly toast: { message: string; id: number } | null;  // ≙ toastMessage(id は再表示検知用の連番)
  readonly dirty: boolean;                   // web 追加: document !== null の派生値。beforeunload ガード用(doc 08 で消費)
}
```

`CanvasStore` はクラスとして実装し、内部に `Store<CanvasState>` と非リアクティブなプライベート状態(≙ `@ObservationIgnored`)を持つ:

```ts
export class CanvasStore implements ReadonlyStore<CanvasState> {
  private readonly store: Store<CanvasState>;
  private readonly history = new History();          // §5
  private interactionSnapshot: Snapshot | null = null;
  private pendingCommitTimer: ReturnType<typeof setTimeout> | null = null;  // ≙ pendingCommitTask
  private toastTimer: ReturnType<typeof setTimeout> | null = null;          // ≙ toastTask
  private isSyncing = false;                         // ≙ isSyncing 再入ガード
  private toastSeq = 0;

  getSnapshot(): CanvasState;
  subscribe(l: () => void): () => void;

  // 派生値(≙ computed)
  get hasDocument(): boolean;     // document !== null
  get canUndo(): boolean;         // history.canUndo
  get canRedo(): boolean;         // history.canRedo
  get zoomPercentText(): string;  // percentLabel(effectiveZoomScale)
}
```

Swift の `didSet` チェーンは TS にないため、**セッターをメソッドとして明示**し、フック呼び出しを内包する。書き込み経路はこのメソッド群に限定する(直接 `store.set` する UI コードを作らない):

| メソッド | 動作(Swift の didSet 相当を含む) |
|---|---|
| `setDocument(doc)` (private) | `document` 差し替え + `documentVersion + 1`。**値が等しくてもバージョンは加算**(CanvasController.swift:11-17) |
| `setSelection(id)` | `selection` 更新 → `syncToolStateFromSelection()`(CanvasController.swift:19-21) |
| `setTool(tool)` | 副作用なしの単純代入 |
| `setStrokeColor(color)` | 代入 → `applyColorToSelection()`(:26-28) |
| `setStrokeWidth(w)` | 代入 → `applyStrokeWidthToSelection()`(:29-31) |
| `setExportBounds(b)` | 代入 → `localStorage.setItem('exportBounds', b)`(:32-43) |
| `setEditingText(flag)` | 単純代入(ショートカット抑止は doc 07) |
| `reportEffectiveZoomScale(s)` | **値が同じなら no-op**(通知ループ防止、:127-130) |

### 4. `src/state/history.ts` — スナップショット undo/redo

Undo 単位は **document + baseBitmap のペア**(破壊的 crop がビットマップを交換するため。CanvasController.swift:68-73):

```ts
export interface Snapshot {
  readonly document: Document;
  readonly baseBitmap: ImageBitmap | null;
}

export class History {
  private undoStack: Snapshot[] = [];
  private redoStack: Snapshot[] = [];

  push(pre: Snapshot): void;               // undoStack.push(pre); redoStack = []
  undo(current: Snapshot): Snapshot | null; // pop undo → push current to redo → return popped
  redo(current: Snapshot): Snapshot | null; // 対称
  get canUndo(): boolean;
  get canRedo(): boolean;
  clear(): void;                            // load 時のみ
  allBitmaps(): Set<ImageBitmap>;           // close() 判定用
}
```

**スタック上限なし**(Swift と同じ)。`Document` はプレーンな値ツリーなのでスナップショットは参照コピーで可(mutate 系は常に新オブジェクトを返す — doc 03 の規約)。`ImageBitmap` は immutable なので参照共有で安全。**history から到達可能な bitmap に `close()` を呼んではならない**。`close()` してよいのは `load()` でスタックをクリアした時に、新しい bitmap 以外の到達不能 bitmap のみ。

`CanvasStore` 側のオーケストレーション(メソッド名は Swift と同一に保つ):

```ts
beginInteraction(): void;
// flushPendingCommit(); document が null なら return;
// interactionSnapshot = { document, baseBitmap }   (CanvasController.swift:148-152)

commitInteraction(): void;
// pre = interactionSnapshot; 常に最後に interactionSnapshot = null;
// pre があり documentsEqual(pre.document, document) が false のときだけ history.push(pre)
// (:155-160 — 変化のないドラッグは何も積まない)

perform(change: (doc: Document) => Document): void;
// flushPendingCommit(); doc が null なら return;
// pre = { document, baseBitmap }; next = change(document);
// documentsEqual(next, pre.document) なら何もしない(setDocument も呼ばない = version 加算なし);
// 変化があれば history.push(pre); setDocument(next)   (:163-172)

undo(): void;
// flushPendingCommit(); pre = history.undo(currentSnapshot); null なら return;
// setDocument(pre.document); baseBitmap = pre.baseBitmap; clampSelection()   (:174-181)

redo(): void;  // 対称 (:183-190)

private clampSelection(): void;
// selection が document 内に存在しなければ selection = null;
// その後**常に** syncToolStateFromSelection()   (:192-195)

deleteSelection(): void;
// selection がなければ return; perform(doc => doc.remove(selection)); setSelection(null)  (:275-279)
```

**undo push が発生するトリガーの完全な一覧**(これ以外は積まない):

1. `commitInteraction()` — ドラッグ確定時、document が変化した場合のみ(要素の作成・移動・リサイズ、crop ドラッグ、線幅スライダーのドラッグ。begin/commit は呼び出し側=engine/UI が括る)
2. `perform()` — 変化があった単発操作(`deleteSelection`、`cancelCrop` など)
3. `applyCrop()` — 手動 push(document + bitmap の両方が変わるため。§7)
4. `applyColorToSelection()` — デバウンス括りの begin/commit(§6)

**undo 対象外**: zoom / pan / tool / selection / exportBounds / isEditingText / toast(zoomMode は「意図的に undo スタック外」— CanvasController.swift:46-47)。undo/redo は selection・tool・zoom を復元**しない**。

`dirty` の規則(web 追加): **派生値** `state.dirty = document !== null`(`setDocument` / `loadImage` で同期)。`history.push` とは無関係で、保存成功でも false に戻さない。Swift に dirty tracking はなく、document がある限り終了時に常に警告する(KakicoApp.swift:40-54)。00-feature-inventory.md の終了確認と 08-io-export.md §6 の beforeunload ガード(`document !== null` 判定)に一致させる。

### 5. 選択 ↔ ツール状態の同期(`syncToolStateFromSelection`)

CanvasController.swift:201-213 の逐語移植。`selection` 変更・`clampSelection` から呼ばれる:

```ts
private syncToolStateFromSelection(): void {
  const { selection, document } = this.getSnapshot();
  if (selection === null || document === null) return;
  const i = indexOf(document, selection);
  if (i === null) return;
  this.isSyncing = true;
  try {
    const element = document.elements[i]!;
    if (element.kind === 'text') {
      const width = strokeWidthForPointSize(element.element.font.pointSize); // pointSize / 4(ペイロードは 03 の {kind, element})
      if (width !== this.getSnapshot().strokeWidth) this.setStrokeWidth(width);
    } else {
      const width = strokeWidthOf(element);   // model の Annotation.strokeWidth getter
      if (width !== null && width !== this.getSnapshot().strokeWidth) this.setStrokeWidth(width);
    }
    const color = colorOf(element);           // model の Annotation.color getter
    if (color !== null && !colorsEqual(color, this.getSnapshot().strokeColor)) {
      this.setStrokeColor(color);
    }
  } finally {
    this.isSyncing = false;
  }
}
```

`isSyncing = true` の間、`applyStrokeWidthToSelection` / `applyColorToSelection` は冒頭で return する(sync → apply のフィードバックループ遮断。CanvasController.swift:75-77)。

### 6. 編集の選択要素への伝播

`applyStrokeWidthToSelection()`(CanvasController.swift:221-233):

```ts
private applyStrokeWidthToSelection(): void {
  if (this.isSyncing) return;
  // selection / document / index が揃わなければ return
  // text 要素: pointSize = suggestedPointSize(strokeWidth) = max(18, strokeWidth * 4);
  //   変化なしなら return; 変化ありなら font.pointSize を更新し
  //   size = suggestedSize(t)  ← render/text.ts(doc 04)で再計測(折返しテキストのクリップ防止)
  //   setDocument で書き戻し(undo 境界は呼び出し側: スライダーが begin/commitInteraction で括る)
  // 非 text で strokeWidth を持つ要素: 現在値と異なる場合のみ書き込み
}
```

`applyColorToSelection()`(CanvasController.swift:240-255)— **500 ms デバウンス undo 境界**:

```ts
private applyColorToSelection(): void {
  if (this.isSyncing) return;
  // selection / document / index / element.color が揃い、現在色と異なるときのみ:
  if (this.pendingCommitTimer === null) this.beginInteraction();
  // document の要素 color を strokeColor に書き換え(setDocument)
  if (this.pendingCommitTimer !== null) clearTimeout(this.pendingCommitTimer);
  this.pendingCommitTimer = setTimeout(() => {
    this.pendingCommitTimer = null;
    this.commitInteraction();
  }, 500);
}
```

`selectStrokeColor(color)`(プリセットスウォッチのタップ、:260-264)— 前後 flush で**必ず 1 undo ステップ**:

```ts
selectStrokeColor(color: RGBAColor): void {
  this.flushPendingCommit();
  this.setStrokeColor(color);   // didSet 経路(applyColorToSelection)を通す
  this.flushPendingCommit();
}
```

`flushPendingCommit()`(:268-273)— タイマーがあれば cancel → null → `commitInteraction()` を即時実行。**`beginInteraction` / `perform` / `undo` / `redo` の先頭で必ず呼ぶ**(デバウンス保留中の変更が後続操作のスナップショットを壊さない保証)。

### 7. Crop ライフサイクル

状態機械(判定は `document.crop` のみ。専用の状態フィールドは持たない):

| 状態 | 判定 | 入る経路 | 出る経路 |
|---|---|---|---|
| `none` | `document.crop === null` | 初期状態 / `cancelCrop` / `applyCrop` 後 | crop ツールでドラッグ開始 → `dragging` |
| `dragging` | engine ローカル(dragMachine、doc 06) | pointerdown(crop tool / pending crop の再編集) | pointerup で `document.crop` 確定 → `pending`(begin/commitInteraction で 1 undo) |
| `pending` | `document.crop !== null`(非破壊・再編集可能) | ドラッグ確定 / undo による復元 | Return・Apply ボタン → `applied`;Esc・Cancel ボタン → `none`(undoable);コーナー/本体ドラッグ → `dragging` に戻り再編集 |
| `applied` | `crop === null` かつ `canvasSize` 縮小・`baseBitmap` 交換済み | `applyCrop()` | undo → 元の document + bitmap を丸ごと復元 |

本ステップで実装するのは store 側の `applyCrop` / `cancelCrop`(ドラッグでの `crop` 書き込みは doc 06)。

`applyCrop()`(CanvasController.swift:286-301 の移植。**破壊的・undoable**):

```ts
applyCrop(): void {
  const { document, baseBitmap } = this.getSnapshot();
  if (document === null || baseBitmap === null) return;
  const clamped = integralCrop(document);   // model: crop ∩ canvas、幅・高さ >= 2、.integral 済み
  if (clamped === null) return;

  const croppedBase = cropBitmap(baseBitmap, clamped);

  let next: Document = { ...document, crop: null, canvasSize: { width: clamped.width, height: clamped.height } };
  const delta: Vector = { dx: -clamped.x, dy: -clamped.y };
  next = { ...next, elements: next.elements.map(e => translate(e, delta)) };

  this.history.push({ document, baseBitmap });  // perform を使わない手動 push(bitmap も変わるため)
  // redoStack は push 内でクリア
  // baseBitmap = croppedBase; setDocument(next)
  // 旧 baseBitmap は history に残るので close() しない
}

/** ≙ CGImage.cropping(to:) — 同期実装 */
function cropBitmap(base: ImageBitmap, rect: Rect): ImageBitmap {
  const c = new OffscreenCanvas(rect.width, rect.height);
  const ctx = c.getContext('2d')!;
  ctx.drawImage(base, rect.x, rect.y, rect.width, rect.height, 0, 0, rect.width, rect.height);
  return c.transferToImageBitmap();
}
```

`cancelCrop()`(:304-307): `document.crop === null` なら no-op、あれば `perform(doc => ({ ...doc, crop: null }))`(**undoable**)。

Return/Esc のキーバインド(Return → applyCrop、Esc → cancelCrop else 選択解除)は doc 06/07 で配線。本ステップでは store メソッドまで。

### 8. ズーム — `src/engine/zoomMath.ts` の逐語移植

`ZoomMath.swift:1-100` を 1:1 で移植する。全パラメータ・戻り値は CSS px(≙ view points)。pan は「画像中心の viewport 中心からの変位」。

```ts
// ≙ Sources/Kakico/ZoomMath.swift — line-for-line port
import type { Point, Size, Rect, Vector } from '../model/geometry';

export type ZoomMode = { kind: 'fit' } | { kind: 'percent'; scale: number };

export const presets: readonly number[] = [0.25, 0.5, 1.0, 2.0, 4.0];  // ZoomMath.swift:14
const minPreset = 0.25;  // presets.first!
const maxPreset = 4.0;   // presets.last!

export function percentLabel(scale: number): string {         // :17-19
  return `${Math.round(scale * 100)}%`;
}

export function fittedScale(canvas: Size, viewport: Size): number {  // :22-25
  if (canvas.width <= 0 || canvas.height <= 0) return 1;
  return Math.min(viewport.width / canvas.width, viewport.height / canvas.height);
}

export function contentSize(canvas: Size, scale: number): Size {     // :28-30
  return { width: canvas.width * scale, height: canvas.height * scale };
}

export function clampedScale(scale: number, canvas: Size, viewport: Size): number {  // :35-38
  const floor = Math.min(minPreset, fittedScale(canvas, viewport));
  return Math.min(Math.max(scale, floor), maxPreset);
}

export function clampedPan(pan: Vector, content: Size, viewport: Size): Vector {     // :42-50
  const clamp = (v: number, c: number, vp: number): number => {
    const slack = (c - vp) / 2;
    if (slack <= 0) return 0;
    return Math.min(Math.max(v, -slack), slack);
  };
  return {
    dx: clamp(pan.dx, content.width, viewport.width),
    dy: clamp(pan.dy, content.height, viewport.height),
  };
}

export function imageRect(canvas: Size, viewport: Size, scale: number, pan: Vector): Rect {  // :54-60
  const content = contentSize(canvas, scale);
  const p = clampedPan(pan, content, viewport);
  return {
    x: (viewport.width - content.width) / 2 + p.dx,
    y: (viewport.height - content.height) / 2 + p.dy,
    width: content.width,
    height: content.height,
  };
}

export function panPreservingCenter(oldPan: Vector, oldScale: number, newScale: number): Vector {  // :64-68
  if (oldScale <= 0) return oldPan;
  const f = newScale / oldScale;
  return { dx: oldPan.dx * f, dy: oldPan.dy * f };
}

export function panPreservingPoint(
  viewPoint: Point, oldPan: Vector,
  oldScale: number, newScale: number,
  canvas: Size, viewport: Size,
): Vector {                                                    // :75-87
  if (oldScale <= 0) return oldPan;
  const f = newScale / oldScale;
  const solve = (v: number, pan: number, c: number, vp: number): number => {
    const rectMin = (vp - c * oldScale) / 2 + pan;
    const newRectMin = v - (v - rectMin) * f;
    return newRectMin - (vp - c * newScale) / 2;
  };
  return {
    dx: solve(viewPoint.x, oldPan.dx, canvas.width, viewport.width),
    dy: solve(viewPoint.y, oldPan.dy, canvas.height, viewport.height),
  };
}

export function zoomInScale(current: number): number {         // :92-94
  return presets.find(p => p > current * 1.001) ?? maxPreset;
}

export function zoomOutScale(current: number): number {        // :97-99
  for (let i = presets.length - 1; i >= 0; i--) {
    const p = presets[i]!;
    if (p < current * 0.999) return p;
  }
  return minPreset;
}
```

store 側のズーム API(CanvasController.swift:120-130):

```ts
setZoom(scale: number): void;   // zoomMode = { kind: 'percent', scale }
zoomToFit(): void;              // zoomMode = { kind: 'fit' }
zoomIn(): void;                 // setZoom(zoomInScale(effectiveZoomScale))  ← live 実効スケール起点
zoomOut(): void;                // setZoom(zoomOutScale(effectiveZoomScale))
reportEffectiveZoomScale(scale: number): void;  // 等値なら no-op
```

`zoomIn/zoomOut` は **`effectiveZoomScale` 起点**(fit 中 0.63 → zoomIn → 1.0)。zoomMode / pan は undo 対象外。

### 9. 画像読み込み — `platform/imageLoad.ts` + store の `load`

```ts
// platform/imageLoad.ts
export async function bitmapFromBlob(blob: Blob): Promise<ImageBitmap>;   // createImageBitmap(blob)
export function imageBlobFromDataTransfer(dt: DataTransfer): Blob | null; // files → image/* 先頭、なければ items
```

store の `load`(CanvasController.swift:102-116 の移植):

```ts
loadImage(bitmap: ImageBitmap, sourceName: string | null): void;
// canvasSize = { width: bitmap.width, height: bitmap.height }
// baseImage ref(CanvasController.swift:105 と同一規則、08-io-export.md §6 と一致):
//   baseImage = sourceName ? { kind: 'file', path: sourceName }
//                          : { kind: 'pngData', data: new Uint8Array(0) }   // 空 Data の等価物
//   (doc 08 の .kakico 保存時に実 PNG を埋め込む)
// document = 新規 Document(elements: [], crop: null); sourceName 保存; dirty = true(document !== null の派生値)
// リセット: selection = null; history.clear()(到達不能 bitmap を close);
//   pendingCommitTimer を clear→null; interactionSnapshot = null; zoomMode = fit
// 保持: tool / strokeColor / strokeWidth / exportBounds
```

デコード失敗時(`createImageBitmap` reject): `NSSound.beep()` の web 代替として `flashToast('Could not load image')`。

配線(`main.tsx`):

- `window` の `paste` イベント: `clipboardData` から画像 Blob → `loadImage`。document が既にあれば ConfirmDialog(doc 07 まではとりあえず `window.confirm('Replace the current document?')` で代用可、ただし acceptance では動作すること)。
- `dragover`(preventDefault)+ `drop`: 画像ファイル → `loadImage`。
- EmptyState の Open ボタン: `<input type="file" accept="image/*">`(FS Access picker と handle 再利用は doc 08)。

### 10. 最小 `CanvasHost` + `hidpi.ts` + fit 描画

`engine/hidpi.ts`:

```ts
export function observeCanvasSize(
  canvas: HTMLCanvasElement,
  onResize: (cssSize: Size, devicePixelSize: Size, dpr: number) => void,
): () => void;
// ResizeObserver の devicePixelContentBoxSize を優先、未対応(Safari)は contentRect × devicePixelRatio
// 加えて matchMedia(`(resolution: ${dpr}dppx)`) の再帰リスナーで DPR 変化(モニタ移動・ブラウザズーム)を検知
```

`engine/CanvasHost.ts`(本ステップは表示のみ。入力処理・overlay は doc 06 で拡張):

```ts
export class CanvasHost {
  constructor(container: HTMLElement, store: CanvasStore);
  dispose(): void;
}
```

動作:

1. `<canvas>` を生成し container に追加。`observeCanvasSize` で backing store を device px に設定、毎フレーム `ctx.setTransform(dpr, 0, 0, dpr, 0, 0)`(以後 CSS px 座標系)。
2. `store.subscribe` → `requestAnimationFrame` を 1 回だけスケジュール(rAF フラグ)。
3. draw: document がなければ clear のみ。あれば `flatten(document, baseBitmap, 1, exportBounds)`(doc 04)を `documentVersion` キーでキャッシュし、
   - `outSize = flatten 結果のサイズ`(= `outputRectFor(document, exportBounds)` の integral サイズ)
   - fit: `scale = fittedScale(outSize, viewportCssSize)`、`pan = {dx:0, dy:0}`(CanvasView の reconcileZoom: fit 中 pan は常に zero)
   - percent: `scale = clampedScale(zoomMode.scale, outSize, viewport)`、`pan = clampedPan(store.pan, contentSize(outSize, scale), viewport)`
   - `rect = imageRect(outSize, viewport, scale, pan)` に `drawImage`(拡大時 `imageSmoothingEnabled = false` はまだ不要。二層化は doc 06)
4. 描画後 `store.reportEffectiveZoomScale(scale)`(等値 no-op ガードにより通知ループしない)。

`ui/CanvasMount.tsx`: `div` の ref で `new CanvasHost(el, store)`、unmount で `dispose()`。それ以外の責務なし。

### 11. サイズバッジ + toast + PNG ダウンロード

サイズバッジは純粋関数として `canvasStore.ts` に export(UI.swift:432-439 の移植):

```ts
export function imageSizeLabel(document: Document, bounds: ExportBounds): string {
  const out = integral(outputRectFor(document, bounds));   // integral は 03 の geometry.ts
  const size = `${Math.trunc(out.width)} × ${Math.trunc(out.height)}`;  // "W × H"
  if (document.crop === null) return size;
  const w = Math.trunc(document.canvasSize.width);
  const h = Math.trunc(document.canvasSize.height);
  return `${size} (${w} × ${h})`;   // pending crop 中は元サイズを括弧で併記
}
```

`ui/ImageSizeBadge.tsx` はこれを表示するだけ(右下フローティング)。バッジは exportBounds の切り替えと pending crop にライブ追従する。

toast(CanvasController.swift:58-66):

```ts
flashToast(message: string): void;
// toastTimer を clearTimeout; toast = { message, id: ++toastSeq };
// toastTimer = setTimeout(() => { toast = null; toastTimer = null; }, 1800);
```

PNG ダウンロード(暫定エクスポート。picker・JPEG・ファイル名継承は doc 08):
ActionBar 相当の仮ボタンで `flatten(document, baseBitmap, 1, exportBounds)` → `encode(canvas, 'image/png')` → `<a download="annotated.png">` + `URL.createObjectURL`。

### 12. `platform/persistence.ts`

```ts
export function loadExportBounds(): ExportBounds;   // localStorage 'exportBounds'、不正値/未設定は 'expandToFit'
export function saveExportBounds(b: ExportBounds): void;
```

キー名・raw 値は Swift と同一(`"exportBounds"` / `"expandToFit"` / `"clipToImage"`)。IndexedDB autosave は doc 08。

localStorage を使うテスト(`tests/state/canvasStore.test.ts` の `exportBounds persists to localStorage`)のため、本ステップで `npm i -D happy-dom` を実行する。02 の vitest 設定は node 環境のみで happy-dom の本格導入は doc 07 だが、当該テストファイル先頭に `// @vitest-environment happy-dom` プラグマ(または `vite.config.ts` の `test.projects` エントリ)を置くことで、step 05 の CI ゲートでも localStorage テストが green になる。

## 定数・仕様表

| 名前 | 値 | 意味 | Swift 参照 |
|---|---|---|---|
| 初期 tool | `'arrow'` | 起動時ツール | Sources/Kakico/CanvasController.swift:22 |
| 初期 strokeColor | `RGBAColor.red` = `{r:0.90, g:0.16, b:0.22, a:1}` | 既定色 | CanvasController.swift:26 / AnnotationModel/Geometry.swift:18 |
| 初期 strokeWidth | `6` | 既定線幅 | CanvasController.swift:29 |
| exportBounds 永続化キー | `"exportBounds"` | localStorage キー(UserDefaults と同名) | CanvasController.swift:32 |
| exportBounds 既定値 | `'expandToFit'` | 未保存時のフォールバック | CanvasController.swift:38 |
| 初期 zoomMode | `{ kind: 'fit' }` | 起動時・画像ロード時 | CanvasController.swift:47, 115 |
| 初期 effectiveZoomScale | `1` | 実効スケール初期値 | CanvasController.swift:50 |
| toast 表示時間 | `1800` ms | 自動消滅 | CanvasController.swift:62 |
| カラーデバウンス | `500` ms | 色変更の undo 合体窓 | CanvasController.swift:250 |
| documentVersion | 書き込みごとに +1(等値でも加算) | flatten キャッシュ無効化キー | CanvasController.swift:11-17 |
| undo 単位 | `{document, baseBitmap}` | crop がビットマップを交換するため | CanvasController.swift:70-73 |
| undo スタック上限 | なし | | CanvasController.swift:79-80 |
| suggestedPointSize | `max(18, strokeWidth * 4)` | 線幅 → text pointSize | AnnotationModel/Geometry.swift:42-44 |
| strokeWidthForPointSize | `pointSize / 4`(クランプなし) | 逆写像(スライダー反映) | AnnotationModel/Geometry.swift:48-50 |
| crop 最小寸法 | 幅・高さとも `>= 2`(未満は degenerate → null) | `clampedCrop` | AnnotationModel/Document.swift:69-74 |
| integralCrop | `clampedCrop(crop)` に `.integral`(origin floor、max 辺 ceil) | 適用時のピクセルスナップ | AnnotationModel/Document.swift:78-80 |
| crop 適用時の要素移動 | `delta = (-clamped.x, -clamped.y)` で全要素 translate | 新原点へシフト | CanvasController.swift:294-295 |
| zoom presets | `[0.25, 0.5, 1.0, 2.0, 4.0]` | ⌘+/⌘− ステップ・上下限 | ZoomMath.swift:14 |
| percentLabel | `Math.round(scale * 100) + '%'` | ズーム表示 | ZoomMath.swift:17-19 |
| fittedScale 退化時 | `1`(canvas の辺が 0 以下) | | ZoomMath.swift:23 |
| zoom 下限 | `min(0.25, fittedScale)` | 巨大画像は fit まで縮小可 | ZoomMath.swift:36 |
| zoom 上限 | `4.0` | | ZoomMath.swift:37 |
| zoomIn epsilon | `current * 1.001` を超える最初の preset | 正確な preset 値から次へ進む | ZoomMath.swift:93 |
| zoomOut epsilon | `current * 0.999` 未満の最後の preset | | ZoomMath.swift:98 |
| pan clamp | 軸ごとに `slack = (content - viewport)/2`;`slack <= 0` なら 0、それ以外 `±slack` にクランプ | | ZoomMath.swift:42-50 |
| pan の意味 | 画像中心の viewport 中心からの変位(CSS px) | | ZoomMath.swift:11-12 |
| `percent(1.0)` の意味 | 画像 1px = 1 CSS px(DPR は関与しない) | Retina で 1 image px = 2 device px | ZoomMath.swift:3-5 |
| zoomIn/Out の起点 | `effectiveZoomScale`(fit 表示の実スケール) | fit 0.63 → zoomIn → 1.0 | CanvasController.swift:124-125 |
| fit 時の pan | 常に `(0, 0)` | reconcileZoom | CanvasView.swift(reconcileZoom) |
| fit の対象サイズ | `outputRectFor(document, exportBounds)` のサイズ | pending crop・expandToFit に追従 | CanvasView.swift(fittedScale 呼び出し) |
| サイズバッジ書式 | `"${w} × ${h}"`(U+00D7、前後スペース)、crop pending 中 `" (${origW} × ${origH})"` 追記 | | Sources/Kakico/UI.swift:432-439 |
| Tool ケース順 | select, arrow, line, rectangle, ellipse, text, pixelate, crop | index = レガシー数字ショートカット | Sources/Kakico/Tool.swift:3-12 |
| Tool 単キー | v a l r o t p c | doc 07 で配線 | Sources/Kakico/Tool.swift:29-40 |
| デコード失敗時 | toast 表示(Swift は `NSSound.beep()`) | web 代替の明示的決定 | CanvasController.swift:90-96 |
| ZoomMath テスト許容誤差 | `0.0001` | 全アサーション共通 | Tests/KakicoTests/ZoomMathTests.swift:7 |

## 受け入れ基準

- [ ] `cd kakico-web && npx tsc --noEmit` がエラーなし
- [ ] `cd kakico-web && npx eslint .` がエラーなし(`state/` から `ui/` への import なし、`engine/zoomMath.ts` に DOM API なし)
- [ ] `cd kakico-web && npx vitest run` が全テスト green(zoomMath 19 ケース + state テスト群を含む)
- [ ] `cd kakico-web && npm run build` が成功
- [ ] 手動: `npm run dev` → EmptyState の Open で PNG を開くと fit 表示される。Retina(DPR 2)でぼやけない(100% 時に 1 image px = 2 device px)
- [ ] 手動: 画像ファイルのドロップ、⌘V ペーストの双方で読み込める。既に document がある状態のペーストは確認ダイアログを経由する
- [ ] 手動: サイズバッジが `W × H` を表示し、exportBounds の切替(暫定トグルで可)で値が変わる
- [ ] 手動: PNG ダウンロードで得たファイルの寸法が `outputRectFor(document, exportBounds).integral` と一致する
- [ ] 手動: ズーム % 表示が fit の実スケールを示す(ウィンドウリサイズで追従)
- [ ] 手動: `exportBounds` を変更してリロードすると値が保持されている(localStorage キー `exportBounds`)
- [ ] 手動: 別画像を読み込むと selection / undo / zoom がリセットされ、tool・色・線幅は保持される

## テスト

### `tests/engine/zoomMath.test.ts` — ZoomMathTests 完全移植表

許容誤差 `0.0001`(`expect(x).toBeCloseTo(v, 4)` 相当。以下すべて `Tests/KakicoTests/ZoomMathTests.swift` の該当メソッドを同名で移植):

| # | Swift テスト名 | 入力 | 期待値 |
|---|---|---|---|
| 1 | `testFittedScaleWideCanvas` | canvas 200×100, viewport 100×100 | `fittedScale = 0.5` |
| 2 | `testFittedScaleTallCanvas` | canvas 100×400, viewport 100×100 | `0.25` |
| 3 | `testFittedScaleDegenerateCanvas` | canvas 0×0, viewport 100×100 | `1`(厳密等値) |
| 4 | `testClampedPanCenteredWhenContentFits` | pan (50,−30), content 80×60, viewport 100×100 | `(0, 0)`(厳密等値) |
| 5 | `testClampedPanClampsOverflowAxisOnly` | pan (80,20), content 200×50, viewport 100×100 | `dx = 50`, `dy = 0` |
| 6 | `testClampedPanBothAxesOverflow` | pan (−999,10), content 300×300, viewport 100×100 | `dx = −100`, `dy = 10` |
| 7 | `testImageRectCenteredWhenFitting` | canvas 40×20, viewport 100×100, scale 1, pan (0,0) | rect `(30, 40, 40, 20)` |
| 8 | `testImageRectEdgesNeverInsideViewportWhenOverflowing` | canvas 100×100, viewport 100×100, scale 4, pan (9999,−9999) | `minX <= 0`, `maxX >= 100`, `minY <= 0`, `maxY >= 100`;かつ `minX = 0`, `maxY = 100`(パン方向の角がビューポート辺にちょうどクランプ) |
| 9 | `testPanPreservingCenterKeepsCenterModelPointFixed` | canvas 100×100, viewport 100×100, scale 2→4, oldPan (30,−20) | zoom 前に viewport 中心 (50,50) 下にあったモデル点が、`panPreservingCenter` 後の `imageRect` でも中心に写る: `newRect.min + model * newScale == 50`(両軸) |
| 10 | `testPanPreservingPointKeepsAnchorModelPointFixed` | canvas 120×80, viewport 100×100, scale 2→3.5, oldPan (−15,25), anchor (70,20) | anchor 下のモデル点が固定: `newRect.min + model * newScale == anchor`(両軸) |
| 11 | `testPanPreservingPointAtViewportCenterMatchesPanPreservingCenter` | canvas 200×150, viewport 100×100, scale 1.5→0.75, oldPan (12,−8), viewPoint (50,50) | `panPreservingPoint == panPreservingCenter`(両軸) |
| 12 | `testPanPreservingPointIdentityWhenScaleUnchanged` | scale 2→2, pan (5,−7), viewPoint (10,90), canvas/viewport 100×100 | pan 不変 `(5, −7)` |
| 13 | `testClampedScaleFloorsAtSmallestPreset` | scale 0.05, canvas 100×100, viewport 100×100(fit=1.0) | `0.25` |
| 14 | `testClampedScaleFloorsAtFitForHugeImages` | scale 0.01, canvas 1000×1000, viewport 100×100(fit=0.1) | `0.1` |
| 15 | `testClampedScaleCapsAtLargestPreset` | scale 9, canvas 100×100, viewport 100×100 | `4.0` |
| 16 | `testZoomInFromFitFraction` | `zoomInScale(0.63)` | `1.0` |
| 17 | `testZoomOutFromFitFraction` | `zoomOutScale(0.63)` | `0.5` |
| 18 | `testZoomInFromExactPresetAdvances` | `zoomInScale(1.0)` / `zoomOutScale(1.0)` | `2.0` / `0.5` |
| 19 | `testZoomClampsAtEnds` | `zoomInScale(4.0)`, `zoomInScale(10.0)`, `zoomOutScale(0.25)`, `zoomOutScale(0.1)` | `4.0`, `4.0`, `0.25`, `0.25` |

### `tests/state/history.test.ts`(node env、ImageBitmap はダミーオブジェクトでスタブ)

- `commitInteraction pushes pre-state only when document changed` — begin → 要素追加 → commit で `canUndo === true`;begin → 無変更 → commit で `canUndo === false`
- `perform with no change does nothing` — 恒等変換の `perform` で undo push なし・`documentVersion` 加算なし
- `perform with change pushes and clears redo` — undo 後に `perform` すると `canRedo === false`
- `undo restores document and baseBitmap` — applyCrop 相当の bitmap 交換後、undo で document と bitmap の**参照**が元に戻る
- `redo is symmetric` — undo → redo で最新状態に戻る
- `clampSelection nils removed selection` — 選択中の要素を含む状態へ undo で消えたら `selection === null`
- `undo does not restore selection, tool, zoom` — undo 前後で tool / zoomMode が不変

### `tests/state/colorDebounce.test.ts`(`vi.useFakeTimers()`)

- `two color changes within 500ms coalesce to one undo step` — 選択中要素へ `setStrokeColor` を 2 回(間隔 300 ms)→ 500 ms 経過 → `undo()` 1 回で最初の色に戻る
- `changes 500ms apart are separate steps` — 間隔 600 ms → undo 2 回必要
- `selectStrokeColor is exactly one immediate step` — タイマー経過なしで即 `canUndo === true`、直後の `beginInteraction` が保留分を巻き込まない
- `flushPendingCommit runs before beginInteraction/perform/undo/redo` — デバウンス保留中に `undo()` を呼ぶと、色変更が 1 ステップとして確定した上で undo される

### `tests/state/selectionSync.test.ts`

- `selecting element adopts its stroke width and color` — width 12・orange の rectangle を選択 → `strokeWidth === 12`、`strokeColor` が orange
- `selecting text derives width from pointSize / 4` — pointSize 28 の text 選択 → `strokeWidth === 7`
- `sync does not write back into the document` — 選択直後、document の全要素が選択前と `documentsEqual`(isSyncing ガードの検証)
- `setStrokeWidth on selected text maps to max(18, w*4) and re-measures size` — `setStrokeWidth(4)` → pointSize 18;`setStrokeWidth(10)` → pointSize 40、`size` が `suggestedSize` の返り値に更新
- `setStrokeWidth is no-op for pixelate selection` — pixelate 選択中の `setStrokeWidth` で document 不変

### `tests/state/crop.test.ts`

- `applyCrop shifts elements and shrinks canvas` — crop (10,20,100,80)・要素 start (30,30) → 適用後 canvasSize 100×80、start (20,10)、`crop === null`
- `applyCrop is rejected for degenerate crop` — 幅 1 の crop で no-op(document・bitmap 不変、undo push なし)
- `applyCrop swaps bitmap and undo restores it` — 適用後 `baseBitmap` が別参照、undo で元参照
- `cancelCrop is undoable` — cancel 後 `crop === null`、undo で crop 復活
- `cancelCrop with no crop is no-op` — undo push なし

### `tests/state/canvasStore.test.ts`

ファイル先頭に `// @vitest-environment happy-dom` プラグマを置く(localStorage テストのため。他の state テストは node 環境のまま。`happy-dom` は本ステップで devDependency に追加済み):

- `load resets interaction state but keeps tool prefs` — tool='line'、色 blue に変更 → `loadImage` → selection null / canUndo false / zoomMode fit / dirty true(document !== null の派生値)、tool・色・線幅は保持
- `documentVersion bumps on every document write` — 同値 document の再代入でも +1
- `reportEffectiveZoomScale is no-op when unchanged` — 同値報告で listener 未発火(microtask 後に通知回数を検証)
- `zoomIn steps from effectiveZoomScale` — `reportEffectiveZoomScale(0.63)` 後の `zoomIn()` で `zoomMode = percent(1.0)`
- `toast auto-dismisses after 1800ms`(fake timers)— 1799 ms で残存、1800 ms で null;再表示でタイマー再スタートと `id` 増加
- `imageSizeLabel formats with U+00D7 and pending-crop suffix` — crop なし `"1920 × 1080"`;crop (0,0,800,600) pending で `"800 × 600 (1920 × 1080)"`
- `exportBounds persists to localStorage` — `setExportBounds('clipToImage')` 後、`localStorage.getItem('exportBounds') === 'clipToImage'`(happy-dom)
