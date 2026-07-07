# 08 — I/O とエクスポート一式

## 目的

画像の入力（paste / drag-drop / ファイルオープン）と出力（PNG・JPEG エクスポート / クリップボードコピー / drag-out / `.kakico` 保存・読込）を完成させる。Mac 版 `ExportService.swift` / `ImageLoader.swift` の挙動を Web API 上で忠実に再現し、各操作のエラー処理をトースト表示に統一する。05 で仮実装した最小限のロード・ダウンロード経路を、確認ダイアログ・ファイル名継承・ハンドル再利用・autosave を含む正式版に置き換える。

## 前提

- `02-project-setup.md` 完了（Vite + Preact + vitest + ESLint 境界 + `theme.css`）
- `03-model.md` 完了（`src/model/codec.ts` の `encodeDocument`/`decodeDocument`、golden fixture `tests/fixtures/golden-mac.kakico`、base64 ヘルパー）
- `04-renderer.md` 完了（`src/render/flatten.ts` の `flatten()`、`src/render/encode.ts` の `encode()`）
- `05-state-controller.md` 完了（`canvasStore` / `history`、`loadImage` アクション、仮の paste / drop / open / PNG ダウンロード）
- `06-canvas-interactions.md` 完了（`textEditor` の commit ライフサイクル — paste 置換前に編集確定が必要）
- `07-ui-chrome.md` 完了（`ActionBar` / `Toast` / `ConfirmDialog` / `shortcuts.ts` の骨格）

## 作成・変更ファイル

新規:
- `kakico-web/src/platform/files.ts`
- `kakico-web/src/platform/clipboard.ts`
- `kakico-web/src/platform/dragOut.ts`
- `kakico-web/src/platform/exportService.ts` （`ExportService.swift` 対応のオーケストレーション層。§2 のディレクトリツリーへの追加ファイル — `platform/` 配下で他 4 モジュール + `render/` + `state/` を束ねる）
- `kakico-web/tests/platform/files.test.ts`
- `kakico-web/tests/platform/exportService.test.ts`
- `kakico-web/tests/platform/clipboard.test.ts`
- `kakico-web/tests/platform/persistence.browser.test.ts`（vitest browser mode — 実 IndexedDB / localStorage）

変更:
- `kakico-web/src/platform/imageLoad.ts`（05 §9 の仮 API を正式化・改名。§1 の注記参照）
- `kakico-web/src/platform/persistence.ts`（05 §12 の `loadExportBounds`/`saveExportBounds` に IndexedDB autosave を追加）
- `kakico-web/src/state/canvasStore.ts`（`loadImage`/`replaceDocument` アクション正式化、`sourceName` 管理）
- `kakico-web/src/ui/ActionBar.tsx`（copy / export ボタン配線、Export Bounds picker 追加、drag-out well 追加）
- `kakico-web/vite.config.ts`（04 の browser プロジェクトの include（`tests/render/**/*.browser.test.ts`）を `tests/**/*.browser.test.ts` に拡大し、node プロジェクト側の exclude も同じ `tests/**/*.browser.test.ts` に更新。`persistence.browser.test.ts` が browser mode で実行されるようにする。「テスト」節参照）
- `kakico-web/src/ui/EmptyState.tsx`（Open Image… / Paste from Clipboard ボタン配線）
- `kakico-web/src/ui/ConfirmDialog.tsx`（Promise ベース API `confirmDiscard()` が 07 で未提供なら追加）
- `kakico-web/src/keyboard/shortcuts.ts`（⌘O / ⇧⌘O / ⌘S / ⌘E / ⌘C / ⇧⌘C / ⇧⌘V の配線）
- `kakico-web/src/main.tsx`（paste / drop リスナー、`beforeunload` ガード、autosave 復元）

## 実装手順

### 1. `src/platform/imageLoad.ts` — 画像デコード（≙ `ImageLoader.swift`）

```ts
/** Decode a Blob/File into an ImageBitmap. First frame only (animated GIF etc.).
 *  ≙ ImageLoader.cgImage(from:) — CGImageSourceCreateImageAtIndex(src, 0, nil) */
export async function loadBitmap(source: Blob): Promise<ImageBitmap> {
  // createImageBitmap decodes only the first frame; throws on undecodable data.
  return createImageBitmap(source);
}

/** First image File from a drop DataTransfer, or null.
 *  ≙ CanvasView.performDragOperation: file URLs filtered to public.image, first wins. */
export function imageFileFromDataTransfer(dt: DataTransfer): File | null;

/** First image Blob from a ClipboardEvent (paste), or null.
 *  Scans e.clipboardData.items for type.startsWith('image/'). */
export function imageBlobFromClipboardEvent(e: ClipboardEvent): Blob | null;
```

- **05 §9 の仮 API を本ステップで改名・置換する**（新規ファイルを作らず既存 `imageLoad.ts` を修正。重複実装を作らないこと）:
  - `bitmapFromBlob(blob: Blob): Promise<ImageBitmap>` → `loadBitmap(source: Blob): Promise<ImageBitmap>`
  - `imageBlobFromDataTransfer(dt: DataTransfer): Blob | null` → `imageFileFromDataTransfer(dt: DataTransfer): File | null`（`File` を返すことで `file.name` を sourceName 継承に使える。生画像 item のフォールバックは §5 参照）
  - 05 で配線済みの呼び出し側（drop リスナー等）も新名称に追従させる。
- ダウンスケール・サムネイル化は行わない（Swift 同様、フル解像度の第 1 フレームをそのまま使用。サイズガードは `flatten` の 256 MP 上限のみ）。
- EXIF orientation: `createImageBitmap` のデフォルト `imageOrientation: 'from-image'` を採用。**意図的な差分** — Swift は orientation を無視するが（`CGImageSourceCreateImageAtIndex` はオプションなし）、スクリーンショット用途では orientation タグが付かないため実質パリティ。コード中にこの差分をコメントで明記すること。
- `canvasSize` はデコード結果の `bitmap.width` / `bitmap.height`（ネイティブピクセル）から設定（≙ `CanvasController.swift:103`）。Retina 乗算は一切しない。

### 2. `src/platform/files.ts` — ファイル選択・保存の低レベル層

```ts
export const hasFSAccess: boolean; // 'showOpenFilePicker' in window

/** basename without the last extension: "shot.png" → "shot". */
export function basename(name: string): string; // name.replace(/\.[^.]+$/, '')

/** Format from a chosen filename's extension (lowercased).
 *  ≙ ExportService.swift:53-54 — jpg/jpeg → JPEG, anything else → PNG. */
export function exportTypeForFilename(name: string): 'image/png' | 'image/jpeg';

export interface OpenResult { file: File; handle: FileSystemFileHandle | null }

/** Image open: showOpenFilePicker (accept {'image/*': ['.png','.jpg','.jpeg','.gif','.webp','.bmp','.avif']})
 *  or <input type=file accept="image/*"> fallback. null = user cancel. */
export async function openImageFile(): Promise<OpenResult | null>;

/** .kakico open: accept {'application/json': ['.kakico']}. Fallback: <input accept=".kakico,application/json">. */
export async function openKakicoFile(): Promise<OpenResult | null>;

export interface SaveResult { name: string; handle: FileSystemFileHandle | null }

/** showSaveFilePicker with suggestedName + types; write blob; return chosen name/handle.
 *  Fallback: downloadBlob(blob, suggestedName) and return {name: suggestedName, handle: null}.
 *  null = user cancel (AbortError). Throws on write failure. */
export async function saveBlobAs(
  blob: Blob | Promise<Blob>, suggestedName: string,
  types: FilePickerAcceptType[],
): Promise<SaveResult | null>;

/** Silent re-save to an existing handle (createWritable → write → close). */
export async function writeToHandle(handle: FileSystemFileHandle, blob: Blob): Promise<void>;

/** <a download> fallback. */
export function downloadBlob(blob: Blob, name: string): void;
```

- picker の `AbortError`（ユーザーキャンセル）は `null` に変換して返す。呼び出し側は無音で終了（Swift の `response != .OK` と同じ）。
- `saveBlobAs` で FS Access 使用時: picker を先に開き、フォーマット判定（`exportTypeForFilename`）後にエンコード → 書き込み、の順序を許すため `blob` は `Promise<Blob>` も受け付ける。

### 3. `src/platform/clipboard.ts` — クリップボード入出力

```ts
/** True when navigator.clipboard.read is available (explicit Paste button path). */
export const canReadClipboard: boolean;

/** Explicit-button paste: navigator.clipboard.read() → first item with an image/* type → Blob.
 *  Returns null when clipboard has no image. Throws on permission denial. */
export async function readImageFromClipboard(): Promise<Blob | null>;

/** Copy flattened PNG. MUST pass the Promise into ClipboardItem (Safari user-gesture rule):
 *    navigator.clipboard.write([new ClipboardItem({ 'image/png': pngPromise })])
 *  Resolves on success; rejects on failure. */
export async function copyImageToClipboard(pngPromise: Promise<Blob>): Promise<void>;
```

- Swift は PNG + TIFF の実データを書くが（`ExportService.swift:24-42`）、Web は `image/png` のみ（ブラウザが対応する唯一の画像型）。「promise ではなく実データ」という Mac 版の方針は、Safari のジェスチャ要件により Web では逆転する — `ClipboardItem` に Promise を渡すのが正（アーキテクチャ決定 §6 準拠）。

### 4. `src/platform/exportService.ts` — オーケストレーション（≙ `ExportService.swift`）

Swift の関数名を保持する（命名規約 §9）。すべて `canvasStore` の snapshot を読む純粋なアクション関数。

```ts
import type { CanvasStore, CanvasState } from '../state/canvasStore';
// 05 §3 の CanvasStore クラスを受け取る（generic Store<CanvasState> ではない —
// loadImage / replaceDocument / flashToast / undo 連携はすべて CanvasStore のメソッド）。

/** ≙ ExportService.flatten — Renderer.flatten(doc, baseImage, scale: 1, bounds: exportBounds).
 *  Pending crop is honored WITHOUT applying it (outputRect uses doc.crop). null = no doc or 256MP guard. */
export function flattenCurrent(state: CanvasState): OffscreenCanvas | null;

/** ≙ ExportService.pngData — flatten → PNG Blob. Used by copy and drag-out. */
export async function pngBlob(state: CanvasState): Promise<Blob>; // throws IOError('flatten-failed') when null

/** ≙ ExportService.copyToClipboard.
 *  Success → flashToast('Copied to clipboard'); failure → flashToast(IO_ERRORS.copyFailed). */
export async function copyToClipboard(store: CanvasStore): Promise<void>;

/** ≙ ExportService.exportPanel + export(to:as:).
 *  suggestedName = `${basename(sourceName) ?? 'annotated'}.png`
 *  picker types: [{description:'PNG image', accept:{'image/png':['.png']}},
 *                 {description:'JPEG image', accept:{'image/jpeg':['.jpg','.jpeg']}}]
 *  Format = exportTypeForFilename(chosen name); JPEG quality 0.9.
 *  Fallback (no FS Access): PNG download with suggestedName. */
export async function exportPanel(store: CanvasStore): Promise<void>;

/** ≙ ExportService.openPanel — openImageFile → loadBitmap → store.loadImage(bitmap, file.name). */
export async function openPanel(store: CanvasStore): Promise<void>;

/** ≙ ExportService.confirmAndPasteImage. blob = image from paste event or clipboard.read.
 *  1. hasDocument → confirmDiscard('Replace the current image?',
 *       'Pasting will replace the image you are editing. Unsaved annotations will be lost.', 'Replace');
 *     cancel → return false.
 *  2. commit inline text editing (engine textEditor.commit(), ≙ makeFirstResponder(nil)).
 *  3. loadBitmap(blob) → store.loadImage(bitmap, null).  // sourceName = null → export defaults to 'annotated.png' */
export async function confirmAndPasteImage(store: CanvasStore, blob: Blob): Promise<boolean>;

/** ≙ ExportService.saveDocument (+ handle reuse per architecture §6).
 *  1. No doc or no baseBitmap → flashToast(IO_ERRORS.nothingToSave); return.
 *  2. Re-encode baseBitmap to PNG; doc.baseImage = {kind:'pngData', data: bytesToBase64(png)}  // always embedded
 *  3. json = encodeDocument(doc)  // codec from 03; includes "version": 1
 *  4. First save: saveBlobAs(json, 'untitled.kakico', kakicoTypes) — NEVER source-derived (ExportService.swift:120).
 *     Later ⌘S with a stored handle: writeToHandle silently.
 *  5. Success → flashToast('Saved'); store the handle for reuse. */
export async function saveDocument(store: CanvasStore): Promise<void>;

/** ≙ ExportService.openDocument.
 *  1. openKakicoFile → text → decodeDocument (codec 03).
 *  2. doc.baseImage.kind !== 'pngData' → flashToast(IO_ERRORS.openDocFailed); return.  // Swift: beep on .file ref
 *  3. base64 → Blob('image/png') → loadBitmap.
 *  4. store.loadImage(bitmap, null)   // resets undo/selection/zoom-fit, sourceName = null
 *  5. store.replaceDocument(doc)      // restores elements AND pending crop; keeps documentVersion bump
 *  6. Keep the handle for ⌘S reuse. */
export async function openDocument(store: CanvasStore): Promise<void>;
```

エラー型・定数（本ファイルで export）:

```ts
/** §4 pngBlob 等が throw する I/O エラー。code は 'flatten-failed' 等の識別子。 */
export class IOError extends Error {
  constructor(public code: string) { super(code); }
}

export const IO_ERRORS = {
  loadFailed:     "Couldn't load image",
  noImageOnPaste: 'No image on the clipboard',
  clipboardDenied:'Clipboard unavailable — press ⌘V instead',
  copyFailed:     'Copy failed',
  exportFailed:   'Export failed',
  tooLarge:       'Image is too large to export',   // flatten null (256 MP guard)
  nothingToSave:  'Nothing to save',
  openDocFailed:  "Couldn't open document",
} as const;
```

Swift はビープ + モーダル `NSAlert(error:)` だが、Web はすべて `flashToast`（1.8 s、07 の Toast）に統一。picker キャンセル（`null` 戻り）は無音。

### 5. paste / drop リスナー配線（`src/main.tsx`）

1. `window.addEventListener('paste', handler)`:
   - `e.target` がテキスト編集中の `<textarea>`（engine の textEditor）なら **何もしない**（テキストペーストを通す — ≙ Swift の「NSTextView フォーカス時は monitor をパススルー」`KakicoApp.swift:74-77`）。
   - `imageBlobFromClipboardEvent(e)` が null → `flashToast(IO_ERRORS.noImageOnPaste)`。
   - Blob あり → `e.preventDefault()` して `confirmAndPasteImage(store, blob)`。
2. EmptyState の「Paste from Clipboard」ボタン: `canReadClipboard` なら `readImageFromClipboard()` → Blob → `confirmAndPasteImage`; 画像なし → `noImageOnPaste` トースト; 権限拒否 → `clipboardDenied` トースト。`canReadClipboard` が false（Firefox）ならボタン押下で `clipboardDenied` トースト表示。
3. drag-drop 入力: `#app` ルートに `dragover`（`preventDefault()` + `dataTransfer.dropEffect = 'copy'`）と `drop`:
   - `imageFileFromDataTransfer(dt)` の最初の画像ファイルを `loadBitmap` → `store.loadImage(bitmap, file.name)`。**確認ダイアログなし**（≙ Swift の drop は無確認、`CanvasView.swift:620-636`）。`sourceName = file.name` を記録（エクスポートファイル名継承）。
   - 画像ファイルがなければ `dt.items` の `image/*` 型 item（Web ページからの画像ドラッグ）を `getAsFile()` で試す。どちらもなければ無視。
   - `.kakico` ファイルの drop は受け付けない（Swift 同等。`.kakico` は ⇧⌘O / ダブルクリック起動〔09 の launchQueue〕のみ）。
   - drag-out well からの自己 drop を無視するため、`dragOut.ts` がドラッグ中フラグを立てている間は `drop` を無視する。

### 6. store アクション正式化（`src/state/canvasStore.ts`）

05 の仮実装を以下のシグネチャに確定（≙ `CanvasController.load`, `CanvasController.swift:102-116`）:

```ts
/** Full document replacement. Closes the previous ImageBitmap. */
loadImage(bitmap: ImageBitmap, sourceName: string | null): void
// - canvasSize = {width: bitmap.width, height: bitmap.height}
// - document = new empty Document (elements: [], crop: null,
//     baseImage: sourceName ? {kind:'file', path: sourceName} : {kind:'pngData', data: ''})  // 空 placeholder ≙ .pngData(Data())
// - previous baseBitmap?.close(); baseBitmap = bitmap
// - selection = null; undo/redo stacks cleared; pending color-commit cancelled
// - zoomMode = {kind:'fit'}; pan = {dx:0, dy:0}; documentVersion += 1

/** Used by openDocument step 5 — swap in a decoded Document without resetting zoom again. */
replaceDocument(doc: Document): void   // document = doc; documentVersion += 1
```

`dirty` は「document が存在するか」で決定（Swift に dirty tracking はなく、document があれば常に警告 — `KakicoApp.swift:40-54`）。`state.dirty = document !== null` を維持する派生値とする。

### 7. エクスポートとコピーの配線

1. `ActionBar.tsx`: copy ボタン → `copyToClipboard(store)`、export ボタン → `exportPanel(store)`。document なしのとき disabled（alpha 0.3 相当は theme.css 済みのスタイル）。
2. **Export Bounds コントロール**（≙ Mac の File メニュー Picker、`KakicoApp.swift:234-235`。07 §8 で 08 へ先送りされた UI）: `ActionBar.tsx` の export ボタン脇に popover を開くボタンを置き、中に 2 択の picker（radio 相当）を表示する。ラベルは verbatim:
   - **"Expand to Fit Annotations"** — 値 `'expandToFit'`
   - **"Clip at Image Boundary"** — 値 `'clipToImage'`
   選択 → `store.setExportBounds(bounds)`（05 §4 のアクション）→ 内部で `saveExportBounds`（`persistence.ts`、localStorage key `"exportBounds"`、既定 `'expandToFit'`）。05 の暫定トグルは本コントロールで置き換える。サイズバッジ（05）とエクスポート出力は切替に即時追従する。
3. `keyboard/shortcuts.ts` に追加（すべて `e.preventDefault()`、`isEditingText` 中は §11 のマトリクスに従う）:

| キー | 条件 | アクション |
|---|---|---|
| ⌘O | — | `openPanel` |
| ⇧⌘O | — | `openDocument` |
| ⌘S | document あり | `saveDocument` |
| ⌘E | document あり | `exportPanel` |
| ⇧⌘C | document あり | `copyToClipboard` |
| ⌘C | document あり **かつ** `selection === null` **かつ** `!isEditingText` | `copyToClipboard`（それ以外はブラウザ既定に委ねる — preventDefault しない） |
| ⇧⌘V | — | `readImageFromClipboard` → `confirmAndPasteImage` |
| ⌘V | — | **何もしない**（`paste` イベントに委ねる。preventDefault 禁止） |

3. `exportPanel` の詳細フロー:
   1. `state.document` なし → `flashToast(IO_ERRORS.exportFailed)`（Swift は beep）。
   2. `suggestedName = `${state.sourceName ? basename(state.sourceName) : 'annotated'}.png``。
   3. FS Access あり: picker → 選択名から `exportTypeForFilename` で形式決定 → `flatten` → `encode(canvas, type, 0.9)` → 書き込み。`flatten` が null（256 MP 超）→ `tooLarge` トースト。書き込み throw → `exportFailed` トースト。
   4. FS Access なし: PNG 固定で `downloadBlob(pngBlob, suggestedName)`。
   5. pending crop は **適用せず** に反映される（`flatten` が `doc.outputRect(for: bounds)` を使うため。`Document.swift:27-29,41-46`）。`expandToFit` では pending crop の外側の要素が出力をさらに拡張する点も Swift 通り。
   6. JPEG はアルファを持てない。`expandToFit` は白塗りで問題なし。`clipToImage` + 透過 PNG 元画像の場合、ブラウザの `convertToBlob('image/jpeg')` は黒に合成される — Swift（ImageIO）と同挙動のためそのまま許容。コメントで明記。

### 8. `src/platform/dragOut.ts` + ActionBar well（≙ `DragOutWell`, `UI.swift:442-513`）

```ts
/** Chromium detection — DownloadURL is Chromium-only. */
export function isDragOutSupported(): boolean;  // return 'chrome' in window (navigator.userAgentData?.brands fallback)

export interface DragOutController {
  /** Call on pointerenter of the well: pre-encode PNG (DataTransfer must be sync at dragstart).
   *  ≙ Swift renders at mouseDown; web must be even earlier. Stores {blob, objectUrl}. */
  prepare(makePng: () => Promise<Blob>): void;
  /** dragstart handler. Payload not ready yet → preventDefault (drag doesn't start). */
  onDragStart(e: DragEvent, filename: string): void;
  /** dragend/pointerleave: revoke object URL, clear payload. */
  cleanup(): void;
}
export function createDragOutController(): DragOutController;
```

- `onDragStart` の中身:
  ```ts
  e.dataTransfer.setData('DownloadURL', `image/png:${filename}:${objectUrl}`);
  e.dataTransfer.items.add(new File([blob], filename, { type: 'image/png' })); // Web ターゲット向け
  e.dataTransfer.effectAllowed = 'copy';   // ≙ .copy (UI.swift:492)
  ```
- filename はエクスポートと同一規約: `` `${basename(sourceName) ?? 'annotated'}.png` `` （`UI.swift:497-498`）。
- ペイロードは prepare 時点のスナップショット — ドラッグ中の編集は落ちるファイルに反映されない（≙ mouseDown 時キャッシュ、`UI.swift:487-489`）。
- `ActionBar.tsx`: `isDragOutSupported()` が false のとき well を **非表示**（アーキテクチャ決定 §6。コピーが代替）。well は 32×32、`draggable` 属性付き `<div>`、tooltip `"Drag out to share as PNG"`、document なしで disabled 見た目 + `draggable=false`。

### 9. `.kakico` 保存・読込 — ワイヤフォーマット（自己完結の仕様再掲）

コーデック実装は 03 の `src/model/codec.ts`。本ステップはファイル I/O 配線のみだが、検証のためスキーマを再掲する。**Swift `JSONEncoder`/`JSONDecoder` デフォルトと互換であること**（golden fixture がゲート）。

トップレベル = `Document`:

```json
{
  "version": 1,
  "baseImage": { "pngData": { "_0": "<base64 PNG bytes>" } },
  "canvasSize": [800, 600],
  "elements": [ { "arrow": { "_0": { "...": "SegmentElement" } } } ],
  "crop": [[10, 20], [300, 200]]
}
```

- `version` は Web 版が書き足す追加フィールド。**decode 時は欠落を許容**（Mac 版ファイルには無い）。Mac 版 `JSONDecoder` は未知キーを無視するので相互互換。
- Foundation Codable 表現規約: `CGPoint` → `[x, y]`、`CGSize` → `[w, h]`、`CGRect` → `[[x, y], [w, h]]`、`UUID` → 大文字ハイフン区切り文字列、`Data` → base64 文字列、optional は nil のときキー省略。
- `ImageRef`（`Geometry.swift:54-57`）: `{"file": {"path": "..."}}` または `{"pngData": {"_0": "<base64>"}}`。**保存時は必ず `pngData` に差し替え**（`ExportService.swift:123-126`）。
- `Annotation` は case 名ラッパー + `"_0"` ペイロード。ちょうど 6 種: `arrow` / `line`（`SegmentElement`）、`rectangle` / `ellipse`（`ShapeElement`）、`text`（`TextElement`）、`pixelate`（`RedactionElement`）。`blur` / `stamp` は decode 側で判別子だけ予約（03 で実装済み）。
- 要素ペイロード（`Elements.swift`）:
  - `SegmentElement`: `{"id", "start": [x,y], "end": [x,y], "color": RGBAColor, "width": 6}`
  - `ShapeElement`: `{"id", "rect": [[x,y],[w,h]], "color", "width", "fill": RGBAColor?}`（`fill` は nil で省略）
  - `TextElement`: `{"id", "origin": [x,y], "size": [w,h], "string", "font": FontSpec, "color"}`（origin = テキストボックス左上）
  - `RedactionElement`: `{"id", "rect": [[x,y],[w,h]], "amount": 14}`
  - `RGBAColor`: `{"r": 0.9, "g": 0.16, "b": 0.22, "a": 1}`（0–1 の Double）
  - `FontSpec`: `{"family": "Helvetica Neue", "pointSize": 28, "bold": true}`。decode 時に legacy `"Helvetica Neue"` はバンドル済み Inter へマップ（03 の決定）。encode 時は現在の `FontSpec.family` をそのまま書く。
- MIME / 拡張子: picker type は `{ description: 'Kakico Document', accept: { 'application/json': ['.kakico'] } }`。Blob は `new Blob([json], { type: 'application/json' })`。
- 読込後の状態（≙ `ExportService.openDocument`, `ExportService.swift:136-154`）: 全 elements と pending crop を復元、zoom は Fit にリセット、undo 履歴は空、`sourceName = null`（以後の Export デフォルト名は `annotated.png`）。
- `baseImage` が `file` 参照の `.kakico` は開けない（`openDocFailed` トースト。Swift は beep）。
- ⌘S ハンドル再利用: `saveDocument` 成功時に `FileSystemFileHandle` をモジュール内変数に保持。以後の ⌘S は picker なしで上書き + `'Saved'` トースト。`loadImage`（新規画像ロード）でハンドルをクリア。フォールバック環境では毎回ダウンロード。

### 10. `src/platform/persistence.ts` — 設定永続化 + autosave

```ts
/** localStorage key 'exportBounds', values 'expandToFit' | 'clipToImage', default 'expandToFit'.
 *  ≙ CanvasController.swift:32-43 (UserDefaults). */
export function loadExportBounds(): ExportBounds;
export function saveExportBounds(bounds: ExportBounds): void;

export interface AutosaveRecord {
  docJSON: string;            // encodeDocument(doc) — baseImage は placeholder のまま（PNG は別フィールド）
  imagePng: Blob | null;      // baseBitmap の PNG。bitmap の identity が変わったときだけ再エンコード
  sourceName: string | null;
  savedAt: number;            // Date.now()
}
// IndexedDB: db 'kakico' version 1, objectStore 'autosave', key 'current'
export async function saveAutosave(record: AutosaveRecord): Promise<void>;
export async function loadAutosave(): Promise<AutosaveRecord | null>;
export async function clearAutosave(): Promise<void>;
```

- 配線（`main.tsx`）: store を subscribe し、`documentVersion` 変化後 **2000 ms** debounce で `saveAutosave`。`imagePng` は `baseBitmap` の参照が前回と異なるときのみ再エンコード。`document === null` になったら `clearAutosave()`。
- 起動時復元: `loadAutosave()` が record を返し、かつ launch ファイル（09 の launchQueue）が無い場合、`confirmDiscard('Restore previous session?', 'A document from your last session was found.', 'Restore')` を表示。confirm → `docJSON` を `decodeDocument`、`imagePng` を `loadBitmap` → `loadImage` + `replaceDocument`。cancel → `clearAutosave()`。
- autosave の失敗（quota 等）はサイレント（console.warn のみ。ユーザー操作を妨げない）。

### 11. `beforeunload` ガード（`main.tsx`）

```ts
window.addEventListener('beforeunload', (e) => {
  if (store.getSnapshot().document !== null) e.preventDefault(); // ブラウザ標準の確認ダイアログ
});
```

Swift の quit 確認（`KakicoApp.swift:40-54` — document があれば常に警告）に対応。文言はブラウザ固定のため指定不可。

### 12. ConfirmDialog の Promise API

07 の `<dialog>` コンポーネントに以下を用意（未提供なら追加）:

```ts
/** Shows the modal dialog; resolves true on confirm button, false on Cancel/Esc.
 *  ≙ ExportService.confirmDiscard (ExportService.swift:72-80). */
export function confirmDiscard(message: string, info: string, confirmTitle: string): Promise<boolean>;
```

ボタン順: confirm（default、destructive スタイル）→ Cancel。`dialog.showModal()` 使用、Esc = Cancel。

## 定数・仕様表

| 項目 | 値 | Swift 参照 |
|---|---|---|
| flatten スケール | 常に `1`（エクスポートピクセル == モデル単位。Retina 乗算なし） | ExportService.swift:12,19 |
| flatten ピクセル上限 | 幅・高さ・総ピクセルとも `268435456` (256×1024×1024)。超過で null | Renderer.swift:35-36 |
| expandToFit 背景 | 不透明白 `rgba(1,1,1,1)` で出力全域を塗る | Renderer.swift:51-54 |
| JPEG 品質 | `0.9`（`convertToBlob({type:'image/jpeg', quality: 0.9})`） | Renderer.swift:61,66 |
| エクスポート形式判定 | 選択ファイル名の拡張子を lowercase し `jpg`/`jpeg` → JPEG、それ以外すべて → PNG | ExportService.swift:53-54 |
| エクスポート既定名 | `{basename(sourceName)}.png`、sourceName なし（paste / .kakico 読込後）は `annotated.png` | ExportService.swift:49-50 |
| エクスポート picker 型 | PNG (`.png`) / JPEG (`.jpg`, `.jpeg`) の 2 型 | ExportService.swift:47 |
| コピー成功トースト | `"Copied to clipboard"`（この文言のみ Swift 由来。トースト 1.8 s） | ExportService.swift:41; CanvasController.swift:62-63 |
| paste 置換確認 | message `"Replace the current image?"` / info `"Pasting will replace the image you are editing. Unsaved annotations will be lost."` / confirm `"Replace"` / `"Cancel"` | ExportService.swift:92-96 |
| paste 前の編集確定 | インラインテキスト編集を commit してからロード | ExportService.swift:100 |
| drop 時の確認 | **なし**（paste と非対称。無確認で置換） | CanvasView.swift:620-636 |
| drop 受理 | 画像ファイル最優先 → 生画像 item。`.kakico` drop 非対応 | CanvasView.swift:624-635 |
| 画像デコード | 第 1 フレームのみ。ダウンスケール・色空間変換なし | ImageLoader.swift:9,14 |
| open picker 受理型 | 任意の画像（≙ `public.image`）→ `accept: {'image/*': [...]}` | ExportService.swift:106 |
| .kakico 既定名 | `"untitled.kakico"`（**常に**。source 由来にしない） | ExportService.swift:120 |
| .kakico picker 型 | `.kakico` 拡張子、MIME `application/json`（≙ `UTType(filenameExtension:"kakico") ?? .json`） | ExportService.swift:119,138 |
| .kakico 保存時の画像 | 現在の baseBitmap を PNG 再エンコードして `pngData` に埋め込み（自己完結） | ExportService.swift:123-126 |
| .kakico 読込後 | elements + pending crop 復元 / zoom=Fit / undo 空 / sourceName=null | ExportService.swift:148-149; CanvasController.swift:102-116 |
| `file` 参照 .kakico | 読込拒否（エラー通知） | ExportService.swift:144-146 |
| ImageRef placeholder | paste 由来のロードは `{"pngData":{"_0":""}}`（空 Data）、ファイル由来は `{"file":{"path":...}}` | CanvasController.swift:105 |
| exportBounds 永続化 | key `"exportBounds"`、raw 値 `"expandToFit"`/`"clipToImage"`、既定 `expandToFit` | CanvasController.swift:32-43; Document.swift:4-7 |
| pending crop とエクスポート | crop 未適用のまま `outputRect` に反映。expandToFit では crop 外の要素が出力を拡張 | Document.swift:27-46 |
| drag-out ファイル名 | エクスポートと同一規約（`annotated.png` フォールバック含む） | UI.swift:497-498 |
| drag-out ペイロード | ドラッグ開始前に PNG 確定（以後の編集は反映されない）、operation copy | UI.swift:487-492 |
| drag-out well | 32×32、tooltip `"Drag out to share as PNG"`、doc なしで disabled。非 Chromium では非表示 | UI.swift:339,470-474 |
| ⌘C の条件 | document あり・selection なし・テキスト編集中でないときのみ画像コピー。それ以外はパススルー | KakicoApp.swift:82-86 |
| ⌘V | インターセプトしない（paste イベント経由）。textarea フォーカス時はテキストペーストを通す | KakicoApp.swift:74-77 |
| 終了ガード | document が存在する限り `beforeunload` で確認（dirty tracking なし） | KakicoApp.swift:40-54 |
| 失敗時フィードバック | Swift: beep / NSAlert → Web: `IO_ERRORS` トーストに統一。picker キャンセルは無音 | ExportService.swift 各所 |
| autosave | IndexedDB `kakico`/`autosave`/`current`、debounce 2000 ms（Web 新設。Swift に相当なし — アーキテクチャ §8 準拠） | — |
| ⌘S ハンドル再利用 | 2 回目以降サイレント上書き + `'Saved'` トースト（Web 改善。Swift は毎回 panel — アーキテクチャ §6 準拠） | — |

## 受け入れ基準

- [ ] `cd kakico-web && npx tsc --noEmit` が exit 0
- [ ] `cd kakico-web && npx eslint .` が exit 0（`platform/` から `ui/` への import なし等の境界維持）
- [ ] `cd kakico-web && npx vitest run` が全緑（下記テスト含む）
- [ ] `cd kakico-web && npx vite build` が成功
- [ ] golden fixture 相互互換: `tests/fixtures/golden-mac.kakico`（03 が生成・コミット済み。Mac 版エクスポート）を `openDocument` 経路のユニットテストで decode → re-encode → decode してモデルが一致
- [ ] 手動（Chrome）: PNG を開く → 注釈 → ⌘E → 拡張子 `.jpg` で保存 → 保存ファイルが JPEG であること（`file` コマンド確認）
- [ ] 手動（Chrome）: `screenshot.png` を開いてエクスポート → 既定名が `screenshot.png`。⌘V で貼り付けた画像のエクスポート既定名が `annotated.png`
- [ ] 手動（Chrome）: Export Bounds popover に 2 択（"Expand to Fit Annotations" / "Clip at Image Boundary"）が出る → 切替でサイズバッジとエクスポート出力が即時追従 → リロード後も選択が保持される（localStorage key `"exportBounds"`、既定 `expandToFit`）
- [ ] 手動（Chrome）: pending crop を Return で適用**せず**に ⌘E → 出力サイズが crop サイズ（`clipToImage` 時）。ドキュメントの crop は残ったまま
- [ ] 手動（Chrome/Safari/Firefox）: ⇧⌘C（または copy ボタン）→ "Copied to clipboard" トースト → 他アプリに PNG が貼れる
- [ ] 手動（Chrome/Safari/Firefox）: 画像コピー後に ⌘V → 置換確認ダイアログ（文言一致）→ Replace で置換、Cancel で無変更。document なしなら確認なしで即ロード
- [ ] 手動（Chrome）: 画像ファイルをウィンドウへ drop → **確認なしで**置換される
- [ ] 手動（Chrome）: ⌘S → `untitled.kakico` 保存 → 再度 ⌘S → picker が出ずに 'Saved' トースト。⇧⌘O で開き直すと注釈と pending crop が復元され、zoom が Fit、⌘Z が効かない（undo 空）
- [ ] 手動（Chrome）: drag-out well を Finder / デスクトップへドラッグ → `{basename}.png` が落ちる。Firefox / Safari では well が表示されない
- [ ] 手動（Chrome）: 編集中にタブを閉じる → ブラウザの離脱確認が出る。リロード後に "Restore previous session?" → Restore で注釈込みで復元
- [ ] 手動（Firefox）: FS Access 非対応環境で ⌘E → PNG がダウンロードされる。⌘O → `<input type=file>` 経由で開ける

## テスト

`tests/platform/files.test.ts`（node env）:
- `basename strips only the last extension` — `basename('a.b.png') === 'a.b'`, `basename('shot') === 'shot'`
- `exportTypeForFilename maps jpg/jpeg case-insensitively` — `'x.JPG'`/`'x.jpeg'` → `'image/jpeg'`; `'x.png'`/`'x.webp'`/`'x'` → `'image/png'`（Swift 規則: jpg/jpeg 以外はすべて PNG）

`tests/platform/exportService.test.ts`（node env、files/clipboard をモック）:
- `export default filename inherits source basename` — `sourceName: 'shot.png'` → suggestedName `'shot.png'`; `sourceName: null` → `'annotated.png'`
- `kakico default filename is always untitled.kakico` — `sourceName: 'shot.png'` でも `'untitled.kakico'`
- `saveDocument embeds baseImage as pngData` — 保存 JSON の `baseImage.pngData._0` が非空 base64、`file` キーが無い
- `saveDocument output decodes with codec and round-trips` — `decodeDocument(encodeDocument(doc))` 一致 + `version === 1`
- `openDocument rejects file-ref baseImage` — `{"file":{"path":"/x.png"}}` の fixture → `openDocFailed` トーストが flash され document 不変
- `openDocument restores elements and pending crop, resets sourceName` — golden fixture 読込後: elements 数一致、`crop` 復元、`sourceName === null`
- `confirmAndPasteImage asks only when a document is open` — doc なし: confirm 不呼出でロード; doc あり + cancel: ロードされない
- `flatten failure maps to tooLarge toast` — flatten モックが null → `IO_ERRORS.tooLarge`
- `picker cancel is silent` — `saveBlobAs` が null → トーストなし・エラーなし

`tests/platform/clipboard.test.ts`（happy-dom）:
- `imageBlobFromClipboardEvent picks the first image item` — 合成 ClipboardEvent（`text/plain` + `image/png` items）→ PNG Blob
- `imageBlobFromClipboardEvent returns null without images` — text のみ → null
- `imageFileFromDataTransfer filters to image types` — `.txt` + `.png` の DataTransfer → PNG File
- `copyImageToClipboard passes the Promise into ClipboardItem` — `ClipboardItem` モックで、resolve 前に `write` が呼ばれること（Safari ジェスチャ要件の回帰ガード）

`tests/platform/persistence.browser.test.ts`（vitest browser mode、実 IndexedDB / localStorage。ファイル名の `.browser.test.ts` サフィックスと vite.config の include 拡大により browser プロジェクトで実行される）:
- `exportBounds round-trips through localStorage with expandToFit default` — 未設定時 `'expandToFit'`、`saveExportBounds('clipToImage')` 後に read back
- `autosave record round-trips through IndexedDB` — `saveAutosave` → `loadAutosave` で docJSON / sourceName / imagePng サイズ一致
- `clearAutosave removes the record` — clear 後 `loadAutosave() === null`

`tests/state/canvasStore.test.ts` に追加（node env）:
- `loadImage resets undo, selection, zoom and closes the old bitmap` — 事前に undo 積み → loadImage 後 `canUndo === false`、`selection === null`、`zoomMode.kind === 'fit'`、旧 bitmap の `close` 呼出
- `loadImage sets pngData placeholder for pasted images and file ref for named sources` — `sourceName: null` → `baseImage.kind === 'pngData'` かつ data 空文字; `'shot.png'` → `kind === 'file'`
