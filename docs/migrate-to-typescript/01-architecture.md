# 01. ターゲットアーキテクチャ仕様 — kakico-web

本書は macOS アプリ Kakico(`Sources/**`)を TypeScript 製 PWA `kakico-web/` として書き直す際の**確定アーキテクチャ仕様**。後続ドキュメント 02–09 は本書に準拠すること。判断に迷ったら本書が優先。

## 方針

- **移植対象の確定範囲**: Swift モデルが実装するのは `arrow | line | rectangle | ellipse | text | pixelate` の 6 種 + `Document.crop`(`Sources/AnnotationModel/Annotation.swift`、`Sources/Kakico/Tool.swift:1-55`)。README の stamp / blur 記述は未実装の構想。Web 版はこの 6 種 + crop の完全パリティを出荷し、codec は `blur` / `stamp` の discriminant をパリティ達成後の追加拡張用に予約する。
- **AI 実装前提の設計**: 各マイルストーンは自己検証可能(CI ゲート + 手動確認手順)。判断ロジックは全て純粋関数(`dragMachine`、`zoomMath`、`renderer`)へ抽出し、移植したテストが仕様そのものになる。
- **UI の二層分割**: キャンバス操作は framework-free な engine(SwiftUI 版の `CanvasNSView` 相当)、周辺 chrome のみ Preact(SwiftUI shell 相当)。両者は store 経由でのみ通信。
- **WYSIWYG の構造的保証**: 画面描画とエクスポートが同一の純粋 `render()` を呼ぶ。Swift 版で `Renderer.flatten` が両方を担う構造(`Sources/AnnotationRender/Renderer.swift`)の直訳。
- **`.kakico` 互換の規律**: Mac アプリからエクスポートした golden fixture をリポジトリに固定し、codec は fixture に対して書く。互換性は「テスト」であって「期待」ではない。

## 技術スタック

ランタイム依存は **`preact` のみ**。他は全て devDependency またはプラットフォーム API。

| 関心事 | 選定 | 理由 |
|---|---|---|
| 言語 | TypeScript 5.x — `strict`, `noUncheckedIndexedAccess`, `exactOptionalPropertyTypes`, ES2022 | 判別可能ユニオンが Swift enum と 1:1 対応。コンパイラが AI 生成コードの最初のレビュアー |
| ビルド | `vite` | ゼロ設定 TS dev server + ハッシュ付き本番アセット。コード生成モデルが最も習熟したツール |
| PWA | `vite-plugin-pwa`(Workbox `generateSW`) | 完全クライアントサイドアプリに対し全アセット precache。手書き SW のバグをゼロに |
| chrome UI | `preact`(TSX、`@preact/preset-vite`) | 宣言的 chrome が SwiftUI shell を反映。約 4 KB、React 同一 API |
| 状態管理 | 自作 ~100 行 observable store(ライブラリなし) | `@Observable CanvasController` の直訳。Preact は `useSyncExternalStore`、engine は `subscribe` 直接購読 |
| Canvas | 素の `<canvas>` + Canvas 2D + `OffscreenCanvas`。WebGL・canvas ライブラリなし | SwiftUI shell / `CanvasNSView` の分割を反映。単一の純粋描画パイプラインで WYSIWYG を保証 |
| スタイル | 素の CSS カスタムプロパティ(`theme.css`)。Tailwind なし | `Theme.swift` が既に正確なトークン仕様。原典との差分レビューを維持 |
| フォント | OFL フォント Inter を 1 つ同梱し `FontSpec.family` の既定値に | OS/ブラウザ非依存の決定的テキスト計測。旧 `"Helvetica Neue"` はデコード時に Inter へマップ |
| 単体テスト | `vitest`(純粋コードは node 環境、レンダラの pixel テストは `@vitest/browser` + playwright provider) | 本番と同一の import グラフ。ピクセルが問題になる箇所は本物の Canvas 2D |
| E2E(後期・任意) | `playwright`(devDependency) | クリップボード・ダウンロード・オフライン・インストールを唯一スクリプト可能 |
| Lint/Format | `eslint`(typescript-eslint strict)+ `prettier` + `no-restricted-imports` 境界ルール | 決定的な差分。`model/` と `render/` の DOM 非依存を機械的に強制 |

## ディレクトリ構成

```
kakico-web/                          # リポジトリ直下 kakico-web/ に配置
├── index.html                       # app shell: <div id="app">, theme-color meta
├── package.json
├── tsconfig.json                    # strict, ES2022, isolatedModules
├── vite.config.ts                   # preact preset + vite-plugin-pwa + vitest projects
├── playwright.config.ts             # e2e(マイルストーン 09 で追加)
├── dev/
│   └── preview.html                 # dev 専用の目視確認ページ(マイルストーン 04。vite build の rollupOptions.input に含めない)
├── public/
│   ├── icons/                       # maskable PWA アイコン 192/512、favicon.svg
│   └── fonts/inter/                 # 同梱 OFL フォント(woff2)
├── src/
│   ├── model/                       # ≙ Sources/AnnotationModel — 純粋、DOM import ゼロ(lint 強制)
│   │   ├── geometry.ts              # Point/Size/Rect/Vector, RGBAColor + 8 プリセット, FontSpec(strokeWidth↔pointSize マップ), ImageRef, DefaultInitialSize, GeometryMath, rectFromCorners, corners
│   │   ├── elements.ts              # SegmentElement/ShapeElement/TextElement/RedactionElement + arrowOutline()(逐語移植 — Skitch 6 点ポリゴン)
│   │   ├── annotation.ts            # Annotation 判別可能ユニオン {kind:'arrow'|'line'|'rectangle'|'ellipse'|'text'|'pixelate'}; boundingBox/hitTest/handles/moveHandle/translate/strokeWidth/color/applyDefaultInitialSize ディスパッチャ
│   │   ├── handle.ts                # HandleRole ユニオン, oppositeCorner(), cornerHandles(), movingCorner()
│   │   ├── document.ts              # Document, ExportBounds, outputRect/expandedOutputRect, hitTest(前面→背面), clampedCrop, add/remove/bringToFront/mutate — 全て純粋、新 Document を返す
│   │   ├── pointerTarget.ts         # resolvePointer(doc, point, selection, tolerances) → handle | body | selectionFrame | empty
│   │   └── codec.ts                 # .kakico JSON encode/decode(Swift Codable のワイヤ形状を厳密再現)+ "version" フィールド + decode 値域ガード(canvasSize 256 MP / 要素数 / 座標クランプ)。'blur'/'stamp' discriminant を予約
│   ├── render/                      # ≙ Sources/AnnotationRender — model のみ import、ctx を受け取る
│   │   ├── renderer.ts              # render(document, ctx, scale, opts) — 唯一の純粋描画関数(§レンダリング参照)
│   │   ├── text.ts                  # 決定的 measureText 折り返し + suggestedSize()。renderer と editor が共有する唯一の wrap アルゴリズム
│   │   ├── effects.ts               # pixelate(グリッド整列の縮小/拡大、smoothing off)。blur は予約(padded clip 付き ctx.filter)
│   │   ├── flatten.ts               # flatten(doc, baseBitmap, scale, bounds) → OffscreenCanvas。expandToFit 白塗り、256 MP ガード(Renderer.flatten の移植)
│   │   └── encode.ts                # canvas → Blob PNG/JPEG(0.9)、convertToBlob(+ 隠しキャンバスフォールバック)
│   ├── state/                       # ≙ Sources/Kakico/CanvasController.swift
│   │   ├── store.ts                 # 汎用 observable store: getSnapshot/subscribe/update(microtask バッチ通知)
│   │   ├── canvasStore.ts           # アプリ store 形状(§状態管理参照)+ アクション: applyCrop/cancelCrop, selectStrokeColor, setTool, flashToast…
│   │   ├── history.ts               # スナップショット undo/redo {document, baseBitmap}。beginInteraction/commitInteraction/perform。500 ms 色デバウンス統合。bitmap 世代は上限 20(超過分を close — タブ OOM 防止)
│   │   └── tool.ts                  # Tool ユニオン + ラベル + ショートカットキー + アイコン id(≙ Tool.swift)
│   ├── engine/                      # ≙ Sources/Kakico/CanvasView.swift + ZoomMath.swift — framework-free
│   │   ├── CanvasHost.ts            # <canvas> を所有。DPR サイズ調整、rAF バッチ描画、flatten キャッシュ(ドラッグ中凍結 — §レンダリング)、レイヤ合成、dispose()
│   │   ├── zoomMath.ts              # ZoomMath.swift の 1:1 移植(fittedScale, clampedScale, clampedPan, imageRect, panPreservingPoint/Center, presets, percentLabel)
│   │   ├── displayMapping.ts        # DisplayInfo 移植: modelToView/viewToModel/viewRect/modelTolerance(純粋)
│   │   ├── dragMachine.ts           # 純粋ドラッグ状態機械: (state, event, doc, tool, mapping) → {state, docPatch, selection}。状態 none|moving|handle|creating|cropping|movingCrop(≙ CanvasNSView.Drag)
│   │   ├── input.ts                 # PointerEvent/setPointerCapture/wheel/gesture アダプタ → dragMachine + zoomMath。ドラッグ中は mapping 凍結(dragDisplayInfo 移植)
│   │   ├── cropOverlay.ts           # 45% 減光 + クリップ再描画 + marching ants(setLineDash [5,4]、~12 Hz 位相、crop 存在中かつタブ可視時のみ)
│   │   ├── selectionOverlay.ts      # 選択枠 + 円形コーナーハンドルをキャンバス内に描画(DOM ハンドルなし)
│   │   ├── textEditor.ts            # 配置済み <textarea> オーバーレイ: begin/sync/commit ライフサイクル(≙ MinimalTextView + syncTextEditorFrame)
│   │   └── hidpi.ts                 # ResizeObserver devicePixelContentBoxSize(+contentRect×dpr フォールバック)+ 再帰 matchMedia('(resolution)') リスナー
│   ├── platform/                    # feature-detect 付きブラウザアダプタ。各々フォールバックあり
│   │   ├── imageLoad.ts             # File/Blob/DataTransfer → ImageBitmap(createImageBitmap)
│   │   ├── clipboard.ts             # paste イベント主経路。ボタンは navigator.clipboard.read。copy は Promise<Blob> 値の ClipboardItem(Safari 対応)
│   │   ├── files.ts                 # showOpen/SaveFilePicker + ⌘S 用ハンドル再利用。<input type=file>/<a download> フォールバック。launchQueue consumer
│   │   ├── dragOut.ts               # dragstart DownloadURL(Chromium)+ image/png アイテム。非対応環境ではウェルを隠す
│   │   ├── persistence.ts           # localStorage(exportBounds 設定)+ IndexedDB 自動保存(meta/image ストア分離。クラッシュ/リロード復旧)
│   │   ├── errorLog.ts              # 致命イベント(autosave/復元/SW 登録失敗)のローカルログ。sessionStorage リングバッファ、外部送信なし
│   │   └── exportService.ts         # ≙ ExportService.swift のオーケストレーション — files/clipboard + render/ + state/ を束ねる
│   ├── ui/                          # ≙ UI.swift + Theme.swift — Preact chrome。state のみ import、engine 内部は参照禁止
│   │   ├── App.tsx                  # ≙ ContentView: ボード背景 + ドットグリッド、CanvasMount または EmptyState、フローティングオーバーレイ配置
│   │   ├── CanvasMount.tsx          # 唯一のブリッジ: div ref → new CanvasHost(el, store)。unmount で dispose。それ以外の責務なし
│   │   ├── ToolPalette.tsx          # 左フローティングパレット(8 ツール、miroYellow アクティブタイル、色スウォッチ、線幅ボタン)
│   │   ├── ColorPresetPanel.tsx     # Skitch 8 プリセット + <input type=color> フォールバック(native Popover API)
│   │   ├── StrokeWidthPopover.tsx   # スライダー 1–40、begin/commitInteraction で括る(native Popover API)
│   │   ├── ActionBar.tsx            # 右上: ドラッグアウトウェル、コピー、エクスポート
│   │   ├── CropActionBar.tsx        # 下部 Apply Crop / Cancel、doc.crop 存在中に表示
│   │   ├── ZoomControl.tsx          # ライブ % + プリセット 25–400% + Fit(native Popover API)
│   │   ├── ImageSizeBadge.tsx       # "W × H"(crop ペンディング中は元サイズ併記)
│   │   ├── Toast.tsx                # 下部中央カプセル、pointer-events:none、1.8 s 自動消滅
│   │   ├── EmptyState.tsx           # open/paste CTA + drop ヒント
│   │   ├── ConfirmDialog.tsx        # <dialog> ベースの置換/破棄確認(≙ NSAlert)
│   │   ├── chrome.tsx               # 共有 chrome プリミティブ(FloatingPanel/TileButton/PrimaryButton/SecondaryButton/PaletteDivider)
│   │   ├── icons.tsx                # インライン SVG アイコン(SF Symbols を置き換えるオリジナル)
│   │   └── theme.css                # Theme.swift トークン → カスタムプロパティ。prefers-color-scheme で light/dark。ドットグリッドは radial-gradient 背景。backdrop-filter パネル
│   ├── keyboard/shortcuts.ts        # capture-phase keydown: v/a/l/r/o/t/p/c、数字、⌘Z/⇧⌘Z、⌘C/⌘V/⌘S/⌘O/⌘E、⌘+/−/0、Return/Esc/Delete。isEditingText 中は抑止
│   ├── dev/preview.ts               # dev/preview.html 用スクリプト — ハードコード Document を描画(dev 専用、ビルド対象外)
│   └── main.tsx                     # 起動: store + Preact マウント + SW 登録 + launchQueue + beforeunload ガード
└── tests/
    ├── model/                       # AnnotationModelTests, ArrowOutlineTests, DefaultPlacementTests, PointerTargetTests の移植 + codec ラウンドトリップ
    ├── fixtures/                    # Mac アプリからエクスポートした golden .kakico + サンプル画像
    ├── render/                      # browser-mode pixel/golden テスト(≙ EndToEndArtifactTest)。wrap 計算は stub measurer で node テスト
    ├── state/                       # undo/redo、debounce(fake timers)、selection↔tool 同期の無限ループ防止
    ├── engine/                      # zoomMath(≙ ZoomMathTests)、displayMapping ラウンドトリップ、dragMachine シナリオテスト
    ├── platform/                    # files/clipboard/persistence/exportService(マイルストーン 08–09)
    ├── ui/                          # chrome コンポーネントの happy-dom テスト(マイルストーン 07)
    ├── keyboard/                    # shortcuts.test.ts(マイルストーン 07)
    └── e2e/                         # Playwright smoke(マイルストーン 09)
```

## モジュール対応表

| Swift ファイル | TS モジュール | 備考 |
|---|---|---|
| `AnnotationModel/Geometry.swift` | `src/model/geometry.ts` | CGRect ヘルパー → `{x,y,width,height}` 上の関数 |
| `AnnotationModel/Elements.swift` | `src/model/elements.ts` | `arrowOutline()` を逐語移植(Skitch 風 6 点ポリゴン) |
| `AnnotationModel/Annotation.swift` | `src/model/annotation.ts` | payload 付き enum → 判別可能ユニオン。`mutate`/`as!` の曲芸は TS narrowing で消滅 |
| `AnnotationModel/Document.swift` | `src/model/document.ts`, `src/model/codec.ts` | codec は Swift Codable のワイヤ形状(例: `{"arrow":{"_0":{…}}}` の case キー)を再現し Mac アプリと `.kakico` を相互往復。`version` を追加 |
| `AnnotationModel/Handle.swift` | `src/model/handle.ts` | protocol extension → 共有 rect-handle ヘルパー |
| `AnnotationModel/PointerTarget.swift` | `src/model/pointerTarget.ts` | 1:1。選択枠での move 判定を含む同一優先順位 |
| `AnnotationRender/Renderer.swift` | `src/render/{renderer,text,effects,flatten,encode}.ts` | Canvas 2D は元来 y-down/top-left — `withYFlip` 機構は全削除。CoreText → measureText wrap。CIPixellate → モザイク。ImageIO → `convertToBlob` |
| `Kakico/CanvasController.swift` | `src/state/{canvasStore,history}.ts` | documentVersion、interaction スナップショット、色デバウンス、tool↔selection 同期を全移植。UserDefaults → localStorage |
| `Kakico/CanvasView.swift` | `src/engine/{CanvasHost,displayMapping,dragMachine,input,cropOverlay,selectionOverlay,textEditor}.ts` | 731 行の NSView を純粋状態機械 + 薄い DOM グルーに分割 — 本リライト最大のテスタビリティ改善 |
| `Kakico/ZoomMath.swift` | `src/engine/zoomMath.ts` | 行単位移植。`ZoomMathTests` を先に移植 |
| `Kakico/Tool.swift` | `src/state/tool.ts` | SF Symbols → `ui/icons.tsx` |
| `Kakico/Theme.swift` | `src/ui/theme.css` | トークン → カスタムプロパティ。MiroGrid タイル画像 → CSS `radial-gradient` の background-repeat |
| `Kakico/UI.swift` | `src/ui/*.tsx`(struct ごとに 1 コンポーネント) | `DragOutWell` → `platform/dragOut.ts` + ActionBar タイル |
| `Kakico/ExportService.swift` | `src/platform/{files,clipboard}.ts`, `src/render/encode.ts`, `ui/ConfirmDialog.tsx` | NSSavePanel → File System Access API + フォールバック。NSPasteboard → Async Clipboard API |
| `Kakico/ImageLoader.swift` | `src/platform/imageLoad.ts` | CGImage → ImageBitmap |
| `Kakico/KakicoApp.swift` | `src/main.tsx`, `src/keyboard/shortcuts.ts` | メニューバー/NSEvent モニタ → capture-phase keydown。終了確認 delegate → `beforeunload` ガード 1 箇所 |
| `Tests/*`(全 7 ファイル) | `tests/*` | 移植したアサーションが振る舞い仕様そのもの |

## 状態管理

自作 store 1 つで `@Observable CanvasController` を反映。Preact は `useSyncExternalStore` ベースの単一 `useStore()` フックで購読、`CanvasHost` は `subscribe` を直接購読し通知ごとに rAF を 1 回スケジュール。Preact→engine、engine→Preact の直接通信は禁止 — **store が唯一の契約**。

```ts
// state/canvasStore.ts — 厳密な形状
interface CanvasState {
  readonly document: Document | null;
  readonly baseBitmap: ImageBitmap | null;      // Document の外。破壊的 crop で差し替え
  readonly sourceName: string | null;           // エクスポートファイル名の継承
  readonly documentVersion: number;             // flatten キャッシュキー(≙ CanvasController.documentVersion)
  readonly selection: ElementID | null;
  readonly tool: Tool;
  readonly strokeColor: RGBAColor;              // selection と同期(isSyncing ガード)
  readonly strokeWidth: number;
  readonly zoomMode: { kind: 'fit' } | { kind: 'percent'; scale: number };
  readonly pan: Vector;
  readonly effectiveZoomScale: number;          // engine が書き戻し ZoomControl ラベルに反映
  readonly exportBounds: 'clipToImage' | 'expandToFit';  // localStorage に永続化
  readonly isEditingText: boolean;              // ショートカット抑止
  readonly toast: { message: string; id: number } | null;
  readonly dirty: boolean;                      // beforeunload ガード
}
// Store API: getSnapshot(): CanvasState; subscribe(fn): unsubscribe; update(mutator): void(microtask バッチ通知)
// history.ts: {document, baseBitmap} スナップショットの undo/redo スタック。
//   beginInteraction()/commitInteraction() がドラッグを 1 undo ステップに括る。
//   perform(fn) = 単発の 1 ステップ変更。色変更は 500 ms デバウンスで統合(≙ CanvasController.swift:238-266)。
```

engine ローカルに置いてよいのは**キャッシュのみ**(flatten OffscreenCanvas、rAF フラグ、ドラッグ状態)。*判断*にあたるものは全て純粋モジュールに置く。lint 境界ルールで強制: `model/` と `render/` は DOM API を import しない、`ui/` は `engine/` 内部を import しない。

## レンダリング

**Swift `Renderer` とパリティの純粋関数 1 つ:**

```ts
render(document: Document, ctx: CanvasRenderingContext2D, scale: number,
       opts?: { baseBitmap?: ImageBitmap; skipElement?: ElementID }): void
```

画面もエクスポートもこれを呼ぶ — 現行の `Renderer.flatten` が両方を担うのと同じく、WYSIWYG は構造で保証。`skipElement` は編集中のテキスト要素を非表示にする。

`CanvasHost` の二層合成(Mac 版のソフトな補間ズームを改善):

- **Layer A(キャッシュ済みラスタ)**: ベース画像 + pixelate エフェクトを `OffscreenCanvas` にフラット化。キーは(pixelate 要素配列の値比較, baseBitmap 参照)。**`documentVersion` 単独をキーにしない** — documentVersion はドラッグの毎 pointermove で進むため、キーにすると 4K 画像で毎フレーム全面再合成 + canvas 再確保が走る。ドラッグ中(`dragDisplayInfo != null`)は Layer A を凍結し、再 flatten は `commitInteraction`(pointerup)時と非ドラッグ経路の変化時のみ(確定仕様は 06 §8)。
- **Layer B(ライブベクタ)**: arrow/line/rect/ellipse/text を毎 rAF、`devicePixelRatio × zoom` のフル解像度で可視キャンバスに直接再描画。数十パス程度で常にシャープ。ドラッグ中の要素(pixelate 含む)はここでライブ描画する。
- **エクスポート経路**: `flatten()` が `render()` を scale 1 で OffscreenCanvas に実行。`exportBounds` を尊重(expandToFit は白塗り)、256 MP ガード(`Sources/AnnotationRender/Renderer.swift:35-36` の移植)、その後 `encode()`。

**devicePixelRatio 戦略**: バッキングストアは `ResizeObserver` の `devicePixelContentBoxSize` からサイズ決定(Safari は `contentRect × devicePixelRatio` フォールバック)。毎フレーム `ctx.setTransform(dpr,0,0,dpr,0,0)` を適用し engine コードは全て CSS px(AppKit points の対応物)で記述。モニタ移動やブラウザズームによる DPR 変化は再帰 `matchMedia('(resolution: …dppx)')` リスナーで捕捉。

## 難所の解法(確定事項)

- **テキスト編集**: キャンバスコンテナ内に絶対配置の素の `<textarea>` を `displayMapping.viewRect(element.boundingBox)` に置く。`font-size = pointSize × zoom`、フォント文字列・行高はキャンバスと同一。**wrap アルゴリズムは `render/text.ts` の 1 つだけ**を renderer と editor サイズ計算(`suggestedSize`)で共有。編集中は renderer が当該要素をスキップ。blur/クリックアウェイ/ズーム変更で commit、Esc も blur と同じく commit(Swift と同一 — 元テキストへ戻す明示キャンセル経路は原典に存在しない、`CanvasView.swift:684-707`)、空文字なら削除、commit = 1 undo ステップ。同梱 Inter フォントで計測を決定的に。
- **Pixelate**: ベース画像のサブ矩形を `ceil(rect/amount)` px の OffscreenCanvas に描き、`imageSmoothingEnabled = false` で拡大して戻す。**サンプリングをキャンバス固定グリッドにスナップ**(source rect を amount の倍数に整列、1 ブロック過剰サンプル)し、ドラッグ中のブロックのちらつきを防止。Layer A キャッシュに属する。
- **Blur(パリティ後)**: 半径の 3 倍でパディングした source 領域に `ctx.filter = 'blur(Npx)'`、rect にクリップ。feature detection の裏に StackBlur ピクセルループのフォールバック。codec の discriminant は今のうちに予約。
- **クリップボード**: 貼り付け = `paste` イベント(`clipboardData.items`)を全ブラウザ共通の主経路に。明示的な Paste ボタンは対応環境で `navigator.clipboard.read()`、非対応なら「⌘V を押してください」ヒント表示。コピー = `navigator.clipboard.write([new ClipboardItem({'image/png': flattenBlobPromise})])` — **初日から Promise 値**(Safari のジェスチャ要件)。resolve 時に toast。
- **ファイル open/save**: `showOpenFilePicker`/`showSaveFilePicker` + ハンドル再利用でサイレント ⌘S 再保存。`<input type=file>`/`<a download>` フォールバック。`.kakico` = Swift Codable 形状の JSON + base64 PNG + `version: 1`。Mac アプリからエクスポートした golden fixture でロック。
- **ドラッグアウト**: `dragstart` で `dataTransfer.setData('DownloadURL', 'image/png:name.png:'+blobUrl)`(Chromium のみ。DataTransfer は同期必須のためウェルの `pointerenter` で PNG を事前エンコード)+ Web ターゲット向け `image/png` アイテム。非対応環境ではウェルを隠し、クリップボードコピーを代替として前面に(`docs/web-pwa-feasibility.md` 準拠)。
- **ズーム/パン**: `zoomMath.ts` を 1:1 移植。ピンチ = `ctrlKey` 付き `wheel`(non-passive リスナー + `preventDefault`、`scale *= exp(-deltaY*0.01)`、`panPreservingPoint` でカーソル基準)+ Safari の `gesturestart/gesturechange`。素の wheel = `scrollWheel` と同じ early-out を持つ `clampedPan`。⌘+/−/0 でプリセット/フィット。`touch-action: none`。ドラッグ中は display mapping を凍結(`dragDisplayInfo` の移植 — expandToFit のフィードバックループを防止)。
- **Crop オーバーレイ**: `drawCropOverlay` を逐語移植 — 画像矩形に 45% 黒塗り(`CanvasView.swift:311`)、crop 矩形内はフラット化レイヤをクリップ再描画、黒下地 + 白 `setLineDash([5,4])`(`CanvasView.swift:326`)を rAF で `lineDashOffset` を進め ~12 Hz にスロットル。crop 存在中かつタブ可視時(`visibilitychange`)のみ稼働。コーナー再編集は `oppositeCorner` 基準、ボディドラッグで移動、Return で破壊的適用(bitmap 差し替えの undo スナップショット)、Esc でキャンセル — 全て `dragMachine.ts` 内。
- **Marching ants の停止条件**: アニメーションループは crop 矩形が存在する間だけ回し、`document.visibilityState === 'hidden'` で停止。復帰時に再開。

## PWA 構成

- **Manifest**: `name/short_name: Kakico`、`display: standalone`、`theme_color`/`background_color` はテーマトークンから、maskable アイコン 192/512、`launch_handler: {client_mode: 'focus-existing'}`(単一ウィンドウモデル)、`.kakico` + `image/png|jpeg|webp` の `file_handlers` を `window.launchQueue.setConsumer` で消費。v1 に `share_target` なし(デスクトップ優先。パリティ後に再検討)。
- **Service worker**: `vite-plugin-pwa` の `generateSW`。app shell 全体(同梱フォント含む)を precache。`registerType: 'prompt'` + 「Reload to update」toast(新 SW は Reload まで waiting・旧 precache 保持 — autoUpdate は表示中ページの遅延チャンクを破壊するため不採用。09 §2)。**ユーザーデータの runtime caching は禁止** — ドキュメントはファイル/IndexedDB に置き、SW キャッシュには入れない。初回ロード後は完全オフライン動作。
- **ホスティング要件**: `sw.js` / `index.html` / `manifest` は `Cache-Control: no-cache`、ハッシュ付きアセットは `immutable` 長期。CSP meta を `index.html` に同梱(09 §11 の表が正)。sw.js が長期キャッシュされると更新機構が本番で死ぬため、ヘッダ設定はデプロイの必須要件。
- **ガード**: `dirty` 時の `beforeunload`。クラッシュ/リロード復旧用の IndexedDB 自動保存(meta / image ストア分離、保存失敗はトースト可視化 — 08 §10)。`decodeDocument` の値域検証(canvasSize 256 MP・要素数・座標クランプ — 03 §7)がファイルオープンと自動復元の両経路を守る。

## テスト戦略

全マイルストーン共通の CI ゲート: `tsc --noEmit && eslint && vitest run`。

- **Unit(node 環境)**:
  - `model/` — Swift の 4 テストファイル全移植 + Mac エクスポートの golden `.kakico` に対する codec ラウンドトリップ(互換性はテストであって期待ではない)。
  - `engine/zoomMath` — `ZoomMathTests` 逐語移植 + `panPreservingPoint` 不変条件。
  - `engine/dragMachine` — 合成ポインタ列で生成ジオメトリ、デフォルトサイズのクリック閾値(3 px)、ハンドルリサイズの対角固定不変条件、crop クランプをアサート。
  - `state/` — bitmap 差し替え crop を含む undo/redo、500 ms 色デバウンス(fake timers)、selection↔tool 同期の無限ループ防止。
  - `render/text` — stub measurer による wrap の決定性。
- **Unit(vitest browser mode、本物の Canvas 2D)**: レンダラの golden/pixel テスト(`EndToEndArtifactTest` の移植)、pixelate グリッド安定性、expandToFit の白塗り。
- **Component(happy-dom)**: 少数のみ — パレットのアクティブ状態、サイズバッジ文字列、crop バーの表示条件、toast 自動消滅。chrome は設計上薄い。
- **手動チェックリスト(マイルストーンごと、Chrome/Safari/Firefox)**: プラットフォーム API 対象 — クリップボード、ピッカー、ドラッグアウト、ピンチ、DPR 変化。Playwright smoke(オフラインリロード、インストール、paste→注釈→copy)はマイルストーン 09 で導入。それ以前はゲートにしない。

## 規約

- **ファイル名**: モジュールは `camelCase.ts`、Preact コンポーネントは `PascalCase.tsx`、class を持つモジュールのみ `PascalCase.ts`(`CanvasHost.ts`)。
- **型**: 型/interface/ユニオンは `PascalCase`。判別フィールドは常に `kind`。ID は branded type(`ElementID`)。
- **関数**: 純粋関数はデータ第一引数、オプション最終引数。新しい状態を返す関数は Swift 原典と同名の動詞形(`clampedCrop`, `movingCorner`)— **移植した関数は全て Swift 名を維持**し、`Sources/` との差分レビューを可能にする。
- **テスト**: レイヤごとに `tests/` 配下へ配置、`<module>.test.ts` 命名。golden は `tests/fixtures/`。
- **CSS**: カスタムプロパティは `--kk-` プレフィックスで `Theme.swift` のトークン名と 1:1 対応。
- **PR**: 各マイルストーン = 1 PR。PR 説明に移植元の Swift 関数名を明記。

## マイルストーン(後続ドキュメント 02–09 対応)

各マイルストーンは PR 1 本のサイズ。終了条件: CI ゲート green、`vite build` 成功、エージェントが実行可能な手動確認 1 項目。

| Doc | マイルストーン | 内容 | 検証 |
|---|---|---|---|
| **02-project-setup** | Scaffold | Vite + Preact + strict TS + vitest + ESLint 境界 + `theme.css` トークン + ドットグリッドボード + EmptyState(ボタンは無効)+ CI workflow | dev server で Miro 風ランディングが表示。トリビアルテスト 1 本 green |
| **03-model** | Model + codec | `src/model/` 全部 + Swift モデルテスト移植 + golden `.kakico` fixture ラウンドトリップ | 約 40 テスト green。DOM import ゼロ(lint) |
| **04-renderer** | Render pipeline | `renderer/text/effects/flatten/encode` + browser-mode pixel golden + ハードコード doc を描画する dev 専用ページ | pixel テスト green。目視ページが Mac レンダと一致 |
| **05-state-controller** | Store + history | `canvasStore`, `history`(undo/redo、デバウンス、interaction 括り)、`tool.ts`、画像ロード + paste イベント/drop/open、DPR 対応 CanvasHost で fit 表示、サイズバッジ、PNG ダウンロードエクスポート | 5K スクリーンショットを開き Retina でシャープ。store テスト green。*この時点でアプリが最低限使える* |
| **06-canvas-interactions** | Engine | `displayMapping`, `dragMachine`(全種の create/select/move/resize/delete、デフォルトサイズクリック)、選択オーバーレイ、テキストエディタオーバーレイ、crop ツール + marching ants + Return/Esc + 破壊的適用、`zoomMath` + ピンチ/パン + drag-freeze | dragMachine + zoomMath テストスイート green。手動: ⌘Z 込みのフルマークアップループ、crop、カーソル基準ピンチ |
| **07-ui-chrome** | Chrome | ToolPalette, ColorPresetPanel, StrokeWidthPopover, ActionBar, CropActionBar, ZoomControl, Toast, ConfirmDialog, icons、isEditingText ガード込みショートカット表、ダークモード | component テスト green。`build/Kakico.app` とのスクリーンショット並置比較 |
| **08-io-export** | I/O suite | クリップボードコピー(Promise ClipboardItem)+ toast、picker + フォールバックでの PNG/JPEG エクスポート、`.kakico` save/open + ハンドル再利用、ファイル名継承、置換確認、ドラッグアウトウェル、beforeunload ガード、IndexedDB 自動保存 | Mac アプリとの codec 相互互換を検証。3 ブラウザ手動チェックリスト |
| **09-pwa** | PWA + polish | Manifest、SW precache、更新 toast、`file_handlers`/launchQueue、オフライン検証、reduced-motion/ARIA パス、Playwright smoke スイート | インストール → ネットワーク遮断 → 再起動で動作。`.kakico` ダブルクリックでアプリが開く。Lighthouse PWA パス |

パリティ後(docs 02–09 の範囲外): `blur` redaction、`StampElement`、`share_target` — いずれも codec に `kind` discriminant を予約済みの追加拡張。

## リスクと対策

1. **`.kakico` ワイヤフォーマットのドリフト** — マイルストーン 03 で Mac エクスポートの golden fixture をチェックイン。codec は fixture に対して書き、推測で書かない。
2. **エディタ/レンダラの wrap 不一致** — 単一 wrap 関数 + 同梱フォント + stub measurer パリティテストで緩和。
3. **Safari のクリップボード/ジェスチャ制約** — Promise 値 ClipboardItem と paste イベント優先を初日から。失敗は必ず toast で可視化。
4. **微妙な不変条件での AI ドリフト**(drag-freeze、デバウンス、sync ガード、ポインタ優先順位) — 全不変条件を純粋関数化し移植テストを付与。テストが仕様。
5. **巨大画像でのジャンク** — レイヤ分割でラスタコストを隔離。256 MP ガード、差し替え時の `ImageBitmap.close()`。worker への flatten オフロードは公認の将来ステップ(renderer は既に DOM 非依存)。
