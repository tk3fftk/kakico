# 10. パリティチェックリスト — 最終受け入れ

## 目的

kakico-web が macOS 版 Kakico と機能同等（parity）であることを最終確認するチェックリスト。00-feature-inventory.md の全挙動を網羅し、各項目に検証方法（コマンドまたは手動手順）と期待結果（正確な値つき）を付す。全項目 pass + 許容差分表の範囲内で、移行完了（README「完了の定義」）。

## 前提

- 02–09 の全ステップが完了し、各ドキュメントの受け入れ基準が pass 済み。
- CI ゲートが green: `cd kakico-web && npx tsc --noEmit && npx eslint . && npx vitest run && npx vite build`
- 比較対象の Mac 版がビルド済み: `bash scripts/build-app.sh` → `build/Kakico.app`
- golden fixture（Mac 版から書き出した `.kakico` とサンプル画像）が `kakico-web/tests/fixtures/` に存在。

## 使い方

- 各項目の先頭マーカー: 【自動】= vitest テストで検証（`cd kakico-web && npx vitest run <path>` が green なら pass）。【手動】= 記載の手順を実行し期待結果を目視確認。【手動3B】= Chrome / Safari / Firefox の 3 ブラウザで確認（フォールバック挙動含む）。
- 【自動】項目は原則としてステップ 03–08 で移植済みのテストが担う。テストが存在しない場合はこのドキュメントを仕様として追加する。
- 手動確認の共通セットアップ: 800×600 px の PNG（スクリーンショット等）を 1 枚用意し、`npx vite dev` で起動したアプリと `build/Kakico.app` を並べて比較する。
- 期待結果の座標・サイズはすべてモデル空間（画像ピクセル）。参照 `file:line` は Swift 原典。
- PWA 固有の受け入れ（オフライン、install、`file_handlers`、更新トースト）は 09-pwa.md の受け入れ基準で担保する。本ドキュメントは Mac 版とのパリティのみ扱う。

## チェックリスト

### 起動と画像入力

- [ ] 【手動】ドキュメントなしで EmptyState を表示 — アイコン + テキスト "Open or drop an image to start annotating" + ボタン "Open Image…"（primary、miroYellow）と "Paste from Clipboard"（secondary）（UI.swift:112-125）
- [ ] 【手動】"Open Image…" → ファイルピッカーで PNG を選択 → 画像が fit 表示され、サイズバッジに `800 × 600` と表示（区切りは U+00D7、前後スペース）（UI.swift:434-438）
- [ ] 【手動】画像ファイルをウィンドウへドラッグ&ドロップ → **確認なしで** ドキュメント置換（CanvasView.swift:620-637）
- [ ] 【手動】ドキュメントが開いている状態で ⌘V（画像がクリップボードにある）→ 確認ダイアログ "Replace the current image?" / "Pasting will replace the image you are editing. Unsaved annotations will be lost." / Replace・Cancel。Replace で置換、Cancel で無変化（ExportService.swift:93-95）
- [ ] 【手動】クリップボードに画像がない状態でペースト操作 → エラートースト表示（Mac 版は beep。許容差分表参照）（ExportService.swift:87）
- [ ] 【自動】ロード時リセット: `selection = null`、undo/redo スタック空、`zoomMode = fit`、pending 色コミット破棄。`tool` / `strokeColor` / `strokeWidth` / `exportBounds` は**維持** — `tests/state/`（CanvasController.swift:102-116）
- [ ] 【手動】ファイル由来ロードで `sourceName` を記録（エクスポート名に継承）、ペースト由来は null（CanvasController.swift:105-108）
- [ ] 【手動】アニメーション GIF を開く → 先頭フレームのみ静止画として使用（ImageLoader.swift:9）
- [ ] 【手動】デコード不能ファイルのドロップ → エラートースト、ドキュメント無変化（CanvasController.swift:96-99）
- [ ] 【手動】`canvasSize` = 画像のネイティブピクセル寸法（Retina 倍率の乗算なし）（CanvasController.swift:103）

### ツール

- [ ] 【手動】パレットに 8 ツールがこの順で並ぶ: Select / Arrow / Line / Rectangle / Ellipse / Text / Pixelate / Crop（Tool.swift 宣言順）
- [ ] 【手動】起動直後の選択ツールは Arrow（CanvasController.swift:22）
- [ ] 【自動】ツール切替は selection を変更しない・副作用なし — `tests/state/`（Tool.swift、CanvasController）
- [ ] 【自動】作成ツールで既存要素をクリック → 選択+移動開始（ツールは切り替わらない）。空白クリックのみ新規作成 — `tests/engine/dragMachine`（CanvasView.swift:411-428）
- [ ] 【自動】クリック配置（デフォルトサイズ昇格）: ドラッグ距離が閾値 3 未満（**厳密に `<`**）で昇格。arrow/line: `end = start + (100, 70)`。rectangle/ellipse/pixelate: クリック点中心の `120 × 90`。2.99 → 昇格、3.01 → 無変化、ちょうど 3 → 無変化。2×200 の細長ドラッグは維持 — `tests/model/`（Geometry.swift:63-73、Annotation.swift:82-108）
- [ ] 【自動】arrowOutline: 6 点ポリゴン、`points[0] == end`（tip）、`points[3] == start`（tail、尖端）。`shaftHalf = max(1, width*0.5)`、`headHalf = max(shaftHalf*2.4, width*1.8)`、`headLen = min(max(width*4.0, 14), length*0.85)`、`notch = headLen*0.30`。`length <= 0.5` → 空配列 — `tests/model/`（Elements.swift:38-64）
- [ ] 【手動】arrow はストロークなしの単一塗りポリゴン。width 6 で shaftHalf 3 / headHalf 10.8（Renderer.swift:117-128）
- [ ] 【手動】line は start→end のストローク線、round cap/join（Renderer.swift:106-107）
- [ ] 【手動】rectangle / ellipse は fill なしストローク描画、ストロークは辺の中心線上（centered）。ellipse は rect に内接（Renderer.swift:131-149）
- [ ] 【手動】text ツールで空白クリック → `220 × 44` のボックスが置かれ即編集開始。pointSize = `max(18, strokeWidth * 4)`（width 6 → 24）（CanvasView.swift:478-489）
- [ ] 【手動】pixelate 新規作成の block size = 14。ブロックは**ベース画像のみ**をサンプル（下にある注釈は無視）。配列で後の注釈はピクセレートの上に描画（Elements.swift:134、Renderer.swift:192-212）
- [ ] 【手動】pixelate rect の幅または高さ ≤ 1 → 不透明 50% グレー（0.5, 0.5, 0.5, 1）で塗りつぶし（Renderer.swift:194-197）
- [ ] 【自動】pixelate block size = `max(2, amount)`、grid はドラッグ中もシマーしない（キャンバス固定グリッドにスナップ）— `tests/render/`（Renderer.swift:207。グリッド固定は 01-architecture §6 の web 側決定）

### 選択・移動・リサイズ

- [ ] 【自動】resolvePointer 優先順位: ①選択中要素のハンドル（円形、距離 ≤ handleTolerance、handles() 配列順で先勝ち）→ ②最前面 body hit（elements 逆順走査）→ ③選択中要素の boundingBox 内（selection frame fallback）→ ④ empty — `tests/model/pointerTarget`（PointerTarget.swift:20-38）
- [ ] 【自動】非選択要素の角はハンドルにならない（(102,102) で非選択の 100×100 filled rect → body）— `tests/model/pointerTarget`（PointerTargetTests.swift）
- [ ] 【自動】ヒットテスト式: segment `distToSegment <= max(tol, width)`。filled shape `rect.insetBy(-tol).contains(p)`。stroked shape エッジ帯 `max(tol, width)`（内部は外れる）。text/pixelate `rect.insetBy(-tol).contains(p)`。重なりは最前面勝ち — `tests/model/`（Elements.swift:25-27, 97-103、Handle.swift:58、Document.swift:55-60）
- [ ] 【自動】ヒット許容量 = ビュー座標で定数 8px → `modelTolerance = 8 / max(scale, 0.0001)` — `tests/engine/displayMapping`（CanvasView.swift:154）
- [ ] 【自動】ハンドル順: segment `[start, end]`、rect 系 `[topLeft, topRight, bottomLeft, bottomRight]` — `tests/model/`（Elements.swift:30、Handle.swift:75-80）
- [ ] 【自動】角リサイズは対角を固定（`movingCorner` → `rectFromCorners(point, opposite)`）。対角を越えるドラッグは自然に反転、負サイズなし。アスペクト固定・最小サイズ・修飾キーなし — `tests/model/` + `tests/engine/dragMachine`（Handle.swift:84-93）
- [ ] 【自動】body ドラッグはデルタ移動（`last` 点との差分を translate）— `tests/engine/dragMachine`（CanvasView.swift:499-501）
- [ ] 【手動】選択枠: boundingBox をビュー座標へ写像し **2px 外側**へ拡張、`#4262FF`（miroBlue）幅 2 でストローク。ハンドルは 9×9 白円 + miroBlue ストローク幅 1.5（CanvasView.swift:288-307）
- [ ] 【手動】boundingBox: segment/shape は `-width` inset（ストローク分拡張）、text/pixelate は rect そのもの → 選択枠がストロークを囲む（Elements.swift:22, 95、Handle.swift:55）
- [ ] 【手動】選択枠・ハンドルはエクスポート画像に**含まれない**（Renderer は選択クロームを描かない）
- [ ] 【手動】Delete / Forward Delete で選択要素を削除（1 undo ステップ）（CanvasView.swift:596）
- [ ] 【手動】どのツールでも text 要素のダブルクリックで編集開始（CanvasView.swift:381-388）
- [ ] 【手動】未選択の stroked rect の中空内部クリック → 何も起きない（empty）。同じ点でも選択中なら frame fallback で移動可（PointerTarget.swift:33-36）
- [ ] 【自動】ドラッグ中の座標写像は mouseDown 時点で凍結（`dragDisplayInfo`）: expandToFit で要素を画像外へドラッグしてもマッピングが 1:1 のまま（フィードバックループなし）、mouseUp で再フィット — `tests/engine/dragMachine`（CanvasView.swift:57-62, 515-517）
- [ ] 【手動】ホバーフィードバックなし・カーソル変更なし・ドラッグ中の Shift/Option/⌘ 修飾なし・右クリックメニューなし・複数選択なし（CanvasView.swift §16 の明示的不在）

### クロップ

- [ ] 【手動】crop ツールでドラッグ → pending crop 作成。オーバーレイ: 画像全体を黒 45% で減光、crop 窓内はフル輝度で再描画。輪郭は黒 55% 幅 1 の下敷き + 白破線 `[5, 4]`（marching ants、約 12Hz で位相前進）。角に 9×9 白円ハンドル（miroBlue ストローク幅 1）（CanvasView.swift:309-360）
- [ ] 【手動】crop 角の再グラブ: ビュー座標で距離 ≤ 8px → 対角固定でリサイズ。crop 内部ドラッグ → 移動。外側 → 新規 crop 開始（CanvasView.swift:432-450）
- [ ] 【自動】mouseUp で `clampedCrop`: キャンバスと交差、結果の幅 < 2 または高さ < 2 → crop 削除（nil）— `tests/model/`（Document.swift:69-73）
- [ ] 【手動】Return（または Apply Crop ボタン）で破壊的適用: `integralCrop`（clamp + 整数スナップ）でベース画像を切り出し、`canvasSize = crop サイズ`、全要素を `(-minX, -minY)` 平行移動、crop = nil。**undo でビットマップごと復元**（CanvasController.swift:286-301）
- [ ] 【手動】Esc（または Cancel ボタン）で crop = nil（undo 可能）（CanvasController.swift:303-306）
- [ ] 【手動】Apply Crop / Cancel バーは `document.crop != null` の間のみ画面下部に表示。ツールチップに "(Return)" / "(Esc)"（UI.swift:370-381）
- [ ] 【手動】pending 中はキャンバスに**全画像**を表示（crop はオーバーレイのみ）。エクスポートは crop を反映（出力 = crop rect）（CanvasView.swift:162-166、Document.swift:27-29）
- [ ] 【手動】pending crop はツール切替をまたいで維持され、crop ツールで再編集可能
- [ ] 【手動】タブ非表示（`visibilitychange`）で ants アニメーション停止、再表示で再開（CanvasView.swift:105-112 のバックグラウンド停止に対応）
- [ ] 【手動】pending 中のサイズバッジ: `"<outW> × <outH> (<origW> × <origH>)"`（例: crop 480×360 で `480 × 360 (800 × 600)`）（UI.swift:434-438）

### Undo・Redo

- [ ] 【自動】スナップショット方式: undo 単位は `{document, baseBitmap}`。ドラッグ全体（begin/commitInteraction）が 1 ステップ — `tests/state/history`（CanvasController.swift:154-190）
- [ ] 【自動】変化のなかった interaction は何も push しない — `tests/state/history`
- [ ] 【自動】色変更は 500ms デバウンスで合体（fake timers）。`selectStrokeColor`（プリセットタップ）は前後 flush で正確に 1 ステップ — `tests/state/history`（CanvasController.swift:236-260）
- [ ] 【自動】破壊的 crop の undo で document と baseBitmap の両方が復元 — `tests/state/history`（CanvasController.swift:286-301）
- [ ] 【自動】undo/redo 後に消えた selection は null 化（clampSelection）、残った selection の色/幅がコントロールに再同期 — `tests/state/`（CanvasController.swift:192-203）
- [ ] 【手動】undo/redo は selection・tool・zoom・クロームを復元しない（document + bitmap のみ）
- [ ] 【手動】⌘Z / ⇧⌘Z が動作。canUndo / canRedo が false のとき UI は無効表示
- [ ] 【手動】スタック上限なし（20 回以上の連続編集を全部 undo できる）

### ズーム・パン

- [ ] 【自動】presets `[0.25, 0.5, 1.0, 2.0, 4.0]`。`percentLabel = "\(Int((scale*100).rounded()))%"` — `tests/engine/zoomMath`（ZoomMath.swift:14-19）
- [ ] 【自動】zoomIn: `current * 1.001` を超える最初の preset、なければ 4.0（0.63 → 1.0、1.0 → 2.0、4.0 → 4.0）。zoomOut: `current * 0.999` 未満の最後の preset、なければ 0.25（0.63 → 0.5、1.0 → 0.5、0.25 → 0.25）— `tests/engine/zoomMath`（ZoomMath.swift:92-99）
- [ ] 【自動】`fittedScale = min(vw/cw, vh/ch)`、キャンバス寸法 ≤ 0 なら 1 — `tests/engine/zoomMath`（ZoomMath.swift:22-25）
- [ ] 【自動】`clampedScale`: floor = `min(0.25, fittedScale)`（巨大画像は 0.25 未満まで許容。1000×1000 in 100×100 → floor 0.1）、cap = 4.0 — `tests/engine/zoomMath`（ZoomMath.swift:35-38）
- [ ] 【自動】`clampedPan`: 軸ごとに `slack = (content - viewport)/2`、slack ≤ 0 → 0（センタリング固定）、それ以外 `[-slack, +slack]` に clamp — `tests/engine/zoomMath`（ZoomMath.swift:42-49）
- [ ] 【自動】`panPreservingCenter = pan * (newScale/oldScale)`（ビューポート中心下のモデル点が不動）— `tests/engine/zoomMath`（ZoomMath.swift:64-68）
- [ ] 【自動】`panPreservingPoint`: カーソル下のモデル点が不動。中心点では panPreservingCenter に一致。同スケールなら恒等 — `tests/engine/zoomMath`（ZoomMath.swift:78-85）
- [ ] 【手動】ピンチ（trackpad = `wheel` + `ctrlKey`）はカーソルアンカーで連続ズーム、`[min(0.25, fit), 4.0]` に clamp。ピンチ後の ⌘+/⌘− は現在の実効スケールから preset へステップ（CanvasView.swift:565-589）
- [ ] 【手動】プレーンホイール/2 本指スクロールのパン: percent モードかつコンテンツがビューポートをはみ出す時のみ。fit モードでは無反応。注釈ドラッグ中は無反応（CanvasView.swift:540-561。y 符号は y-down Canvas では `+=`）
- [ ] 【手動】⌘0 で fit、fit モードでは pan = 0。fit は pending crop と exportBounds を反映した outputRect に対して計算。ウィンドウリサイズで即再フィット（CanvasView.swift:206-236）
- [ ] 【手動】ズームコントロール: 実効 % のライブ表示（fit 中も実スケール、例 63%）。メニューに 25% / 50% / 100% / 200% / 400% + "Fit to Window"（UI.swift:389-416）
- [ ] 【手動】ズームスケール変更（reconcile / ピンチ）で開いているテキストエディタをコミット（CanvasView.swift:222, 578）
- [ ] 【手動】expandToFit 時、注釈で拡張された領域を含めてキャンバスがライブに広がって表示される（CanvasView.swift:168-190）

### テキスト編集

- [ ] 【手動】編集開始（ダブルクリック / text ツールの空白クリック）→ `<textarea>` オーバーレイが `viewRect(boundingBox)` の位置（-2px inset の余白）に出現。font-size = `pointSize × zoom`、フォント・行送りはキャンバス描画と同一、背景は半透明（CanvasView.swift:640-669）
- [ ] 【自動】suggestedSize: 空文字 → `(width, pointSize + 8)`。非空 → `(width, max(ceil(fitHeight) + 2, pointSize + 8))`。幅は常に不変（ラップ制約）— `tests/render/text`（Renderer.swift:169-179）
- [ ] 【手動】入力中のライブオートサイズ: 折り返しで高さが伸び、削除で縮む。エディタとレンダラで折り返し位置が一致（単一 wrap アルゴリズム + バンドル済み Inter）
- [ ] 【手動】コミット: blur / キャンバスクリック / ズーム変更で確定 = 1 undo ステップ（`string` 更新 + `size = suggestedSize`）。**空文字なら要素削除**（CanvasView.swift:684-707）
- [ ] 【手動】編集中に Esc → 現在の内容でコミット（Mac と同一。明示キャンセルは存在しない — CanvasView.swift:684-707、06-canvas-interactions.md §7）
- [ ] 【手動】編集中は renderer が該当要素をスキップ（`skipElement`）— 二重描画なし
- [ ] 【手動】編集中（`isEditingText`）は無修飾レターショートカット v/a/l/r/o/t/p/c と数字 0–7 が無効（KakicoApp.swift:90-100, 263-268）
- [ ] 【自動】FontSpec デフォルト: family（web は Inter へマップ）、pointSize 28、bold true。`suggestedPointSize(w) = max(18, w*4)`、`strokeWidth(p) = p/4` — `tests/model/`（Geometry.swift:33-49）
- [ ] 【手動】size を超える行はドロップされる（クリップでなく非表示）。ただしアプリは常に suggestedSize で size を維持するため通常は発生しない（Renderer.swift:181-190）

### カラー・線幅

- [ ] 【自動】デフォルト: strokeColor = red `(r:0.90, g:0.16, b:0.22, a:1)`、strokeWidth = 6 — `tests/state/`（Geometry.swift:18、CanvasController.swift:26-29）
- [ ] 【手動】プリセット 8 色、パネル上→下順: Red / Orange / Yellow / Green / Blue / Pink / **White / Black**（White が先）。値: red(0.90,0.16,0.22) / orange(0.98,0.55,0.10) / yellow(1.0,0.80,0.0) / green(0.16,0.70,0.30) / blue(0.0,0.48,1.0) / pink(0.96,0.40,0.68) / white(1,1,1) / black(0,0,0)、全 a=1（UI.swift:289-292、Geometry.swift:18-25）
- [ ] 【手動】現在色と**完全一致**するプリセットに miroBlue 幅 2 の選択リング。`<input type=color>` によるカスタム色フォールバックあり（UI.swift:300-324）
- [ ] 【手動】プリセットパネルは色選択後も開いたまま（スウォッチボタンでトグル）（UI.swift:159-167）
- [ ] 【自動】選択同期: 要素選択でその色/幅がコントロールへ反映（text は `pointSize/4`）。`isSyncing` ガードで didSet ループなし — `tests/state/`（CanvasController.swift:205-260）
- [ ] 【自動】幅変更を選択要素へ適用: text は `pointSize = max(18, w*4)` + `size = suggestedSize` 再計測、stroked 系は width 更新。text/pixelate の `strokeWidth` は getter null / setter no-op、pixelate の `color` も null / no-op — `tests/model/` + `tests/state/`（Annotation.swift:34-76、CanvasController.swift:205-233）
- [ ] 【手動】色変更は選択 shape の**ストローク色のみ**変更（fill 不変）（Annotation.swift:56-76）
- [ ] 【手動】線幅スライダー: 範囲 1–40、幅 140px、連続値（スナップなし）、ドラッグを begin/commitInteraction で 1 undo ステップ化。ノブ 16px / トラック 4px / 塗り miroBlue（UI.swift:214-271）
- [ ] 【手動】以後に作成する要素は現在の strokeColor / strokeWidth を継承

### キーボードショートカット一覧

- [ ] 【手動】無修飾レター: `v` Select / `a` Arrow / `l` Line / `r` Rectangle / `o` Ellipse / `t` Text / `p` Pixelate / `c` Crop（テキスト編集中は無効）（Tool.swift:29-40）
- [ ] 【手動】無修飾数字 0–7 = Tool 宣言順（0 Select … 7 Crop）。⌘⇧⌥⌃ のいずれかが押されていたら発火しない。テキスト編集中は無効（KakicoApp.swift:90-100）
- [ ] 【手動】⌘Z undo / ⇧⌘Z redo
- [ ] 【手動】⌘C: ドキュメントあり かつ 未選択のときのみ flatten 画像をコピー。選択中はパススルー。⇧⌘C は常時コピー（KakicoApp.swift:82-87, 227）
- [ ] 【手動】⌘V ペースト（テキスト編集中はエディタへのテキストペーストが優先）。⇧⌘V 明示ペースト
- [ ] 【手動】⌘O 画像を開く / ⇧⌘O .kakico を開く / ⌘S .kakico 保存 / ⌘E 画像エクスポート
- [ ] 【手動】⌘+ zoomIn / ⌘− zoomOut / ⌘0 fit
- [ ] 【手動】Delete・Forward Delete = 選択削除。Return = pending crop 適用（crop なしなら無視）。Esc = pending crop キャンセル、crop なしなら選択解除（CanvasView.swift:593-616）
- [ ] 【手動】ツールチップにショートカット表記: `"<Label> (<KEY>)"` ×8、"Apply the crop (Return)"、"Cancel the crop (Esc)"

### エクスポート・クリップボード・ドラッグアウト

- [ ] 【自動】画面とエクスポートが同一 `render()` を使用（WYSIWYG）。選択枠・crop オーバーレイは非出力 — `tests/render/`（Renderer.swift:18-58）
- [ ] 【自動】flatten: `pixelW = round(out.width * scale)`。ガード: 各次元と総ピクセル数 ≤ `268435456`（256MP）、超過は null — `tests/render/flatten`（Renderer.swift:33-36）
- [ ] 【自動】ExportBounds: `.clipToImage` → `crop ?? (0,0,canvasSize)`。`.expandToFit` → outputRect と全要素 boundingBox の union を `.integral`（外向き整数スナップ）。要素なしなら outputRect のまま。負原点あり得る — `tests/model/`（Document.swift:27-46）
- [ ] 【自動】expandToFit の背景は不透明白 (1,1,1,1)。50px 幅キャンバスの右へ arrow end x=100・width 6 → 出力幅 106、拡張域は白 — `tests/render/`（Renderer.swift:51-54、AnnotationRenderTests）
- [ ] 【手動】exportBounds 設定: デフォルト `expandToFit`、localStorage キー `"exportBounds"`（値 `"expandToFit"` / `"clipToImage"`）に永続化、リロード後も維持（CanvasController.swift:32-43）
- [ ] 【手動3B】画像エクスポート: デフォルトファイル名 `<sourceBasename>.png`、ソースなしは `annotated.png`。拡張子 `jpg`/`jpeg`（小文字比較）→ JPEG quality 0.9、その他 → PNG（ExportService.swift:44-57、Renderer.swift:61-70）
- [ ] 【自動】PNG 出力はマジックバイト `89 50 4E 47` で始まる — `tests/render/encode`
- [ ] 【手動3B】クリップボードコピー（ボタン / ⇧⌘C / 無選択 ⌘C）→ image/png が書かれ、トースト "Copied to clipboard" 表示。他アプリ（Slack 等）へペーストで画像が入る。Safari でもジェスチャ内で成功（Promise 値 ClipboardItem）
- [ ] 【手動】pending crop + expandToFit の組み合わせ: エクスポート出力 = crop rect と全 boundingBox の union（crop は expandToFit をクリップしない）（Document.swift:31-39）
- [ ] 【手動】ドラッグアウト well（Chromium）: ActionBar の well をデスクトップへドラッグ → `<sourceBasename>.png`（なければ `annotated.png`）が生成。バイト列はドラッグ開始前に固定（ドラッグ中の編集は反映されない）。非対応ブラウザでは well 非表示（UI.swift:442-513、許容差分表参照）
- [ ] 【手動】ActionBar（右上）: drag-out well / copy / export の 3 タイル、ドキュメントなしで無効化。web 版は先頭に Undo・Redo タイル + 縦区切りが追加されるが、Mac 版との比較ではこの 2 タイル + 区切りを除外する（UI.swift:337-357、許容差分表参照）
- [ ] 【手動】サイズバッジ: `outputRect(for: exportBounds).integral` を `"W × H"` で表示（Int 切り捨て）。exportBounds 切替と pending crop にライブ追従（UI.swift:418-440）
- [ ] 【手動】トースト: 下部中央のカプセル、チェックアイコン（miroSuccess #2EA56A）+ メッセージ、クリック透過（pointer-events: none）、**1.8 秒**で自動消滅、再表示でタイマーリセット（CanvasController.swift:53-66、UI.swift:75-105）

### .kakico フォーマット

- [ ] 【自動】ワイヤ形状が Swift Codable と一致: Annotation は case キー + `"_0"`（例 `{"arrow":{"_0":{…}}}`）、`CGPoint` → `[x,y]`、`CGSize` → `[w,h]`、`CGRect` → `[[x,y],[w,h]]`、`RGBAColor` → `{"r","g","b","a"}`、`FontSpec` → `{"family","pointSize","bold"}`、`Data` → base64、`fill`/`crop` は null で**キー省略**、UUID 大文字小文字非依存デコード — `tests/model/codec`（AnnotationModelTests.swift:68-87）
- [ ] 【自動】TextElement の JSON に `"origin"` と `"size"` キーが出現（`rect` は非エンコード）— `tests/model/codec`
- [ ] 【自動】Mac 版で書き出した golden `.kakico`（tests/fixtures/）が decode → encode → decode で等価 — `tests/model/codec`
- [ ] 【自動】レガシー arrow/line JSON fixture（小文字 UUID）が正確な id / 座標 / width / color でデコード — `tests/model/codec`
- [ ] 【手動】保存: baseImage は常に埋め込み `pngData`（base64 PNG）に置換、デフォルトファイル名 `untitled.kakico`（ソース名から派生しない）、web 版は `"version": 1` フィールドを追加（ExportService.swift:116-134）
- [ ] 【手動】読み込み: 全要素 + pending crop を復元。zoom は fit にリセット、undo 空、sourceName null（以後のエクスポート名は `annotated.png`）（ExportService.swift:136-154）
- [ ] 【手動】`ImageRef.file(path:)` 参照のドキュメントはエラー表示で開けない（Mac 版と同挙動: pngData 必須）（ExportService.swift:144-146）
- [ ] 【手動】クロス互換: web 版で保存した `.kakico` を `build/Kakico.app` の "Open Kakico Document…" で開き、全注釈が同位置・同色・同サイズで表示される（unknown key `version` は Swift デコーダが無視）
- [ ] 【自動】codec は `blur` / `stamp` discriminant を予約済み（未知 kind として安全に reject または保持、03-model.md の仕様どおり）— `tests/model/codec`

### UI テーマトークン

- [ ] 【手動】ライト: board `#F5F5F7`、grid dot `#D7D7DE`、divider `#E3E3E8`、ink `#050038`、textSecondary `#6B6B7B`。ダーク（`prefers-color-scheme: dark`）: board `#202024`、grid `#38383F`、surface `#313138`、textPrimary `#ECECEF`、textSecondary = `#ECECEF` @ 65%（Theme.swift:8-51）
- [ ] 【手動】アクセント: miroYellow `#FFD02F`（選択ツールタイル背景、primary ボタン）、miroBlue `#4262FF`（スライダー塗り、プリセット選択リング、選択枠 — ライト/ダーク同一）、miroSuccess `#2EA56A`（Theme.swift:25-34）
- [ ] 【手動】ドットグリッド: 28px タイル、1.5×1.5px ドット（タイル左上）、ウィンドウ固定（パン/ズームに追従しない）（Theme.swift:71, 85）
- [ ] 【手動】フローティングパネル: 角丸 16、半透明背景 + `backdrop-filter: blur`、影 黒 22% radius 16 / y 14、ボーダー `#E3E3E8` @ 50% 幅 1、内側 padding 8（Theme.swift:188-201）
- [ ] 【手動】タイポグラフィ: body 16 regular / control 15 semibold / button 15 bold / caption 12 semibold（Theme.swift:61-64）
- [ ] 【手動】ボタン: primary = ink on miroYellow、pad 10/20、角丸 10。tile = 角丸 11、hover/pressed 塗り（ライト `#F1F1F4` / `#E6E6EB`、ダーク `#313138` / `#38383F`）、pressed scale 0.96（Theme.swift:105-174）
- [ ] 【手動】レイアウト: キャンバス padding left 76 / right 24 / 上下 24。パレット左 16。ActionBar 右上 16。crop バー下 20。zoom+バッジ右下 16（間隔 8）。トースト下 24（UI.swift:41-72, 78）
- [ ] 【手動】`prefers-reduced-motion` でアニメーション簡略化（ツール選択、パネル出現スケール、プレススプリング、トーストオフセット）
- [ ] 【手動】文言逐語一致: "Open or drop an image to start annotating" / "Open Image…" / "Paste from Clipboard" / "Apply Crop" / "Cancel" / "Copied to clipboard" / "Fit to Window" / "Replace the current image?" ほか §起動・§クロップ・§エクスポート記載の全文言
- [ ] 【手動】Mac 版とのサイドバイサイド スクリーンショット比較（同一画像 + 同一注釈セット）で、クロームの配置・配色が一致（07-ui-chrome.md の検証手順を再実行）

### 座標系と DPR

- [ ] 【自動】モデル空間 = 画像ピクセル、左上原点、y 下向き。displayMapping の modelToView/viewToModel が往復で恒等（Y フリップなし）— `tests/engine/displayMapping`（Geometry.swift:4-6、CanvasView.swift:138-160）
- [ ] 【手動】zoom 100% = 1 画像ピクセル / 1 CSS px（Retina では 2 デバイスピクセル）。5K スクリーンショットを開いて 100% 表示 → Retina でシャープ（ZoomMath.swift:3-5）
- [ ] 【手動】ベクター注釈（Layer B）はどのズーム率でも `devicePixelRatio × zoom` で再描画されクリスプ（Mac 版の scale-1 flatten 補間より高品質 — 許容差分表参照）
- [ ] 【手動】ブラウザズーム変更・DPR の異なるモニタへの移動で表示が崩れない（`devicePixelContentBoxSize` + `matchMedia('(resolution)')` 再購読）
- [ ] 【自動】flatten はモデル解像度（scale 1）でエクスポート。出力ピクセル寸法 = outputRect 寸法（100×80 → 100×80、crop 40×20 → 40×20、scale 2 → 2 倍）— `tests/render/flatten`（AnnotationRenderTests）

## 許容差分

Web 版で意図的に Mac 版と異なる挙動。これらはチェックリストの failure に数えない。

| # | 項目 | Mac 版 | web 版 | 根拠 |
|---|---|---|---|---|
| 1 | ドラッグアウト | NSFilePromiseProvider、全対応 | Chromium のみ（`DownloadURL`）。PNG は well の `pointerenter` 時にプリエンコード。Safari/Firefox では well 非表示、コピーが代替 | DataTransfer 同期制約（01-architecture §6） |
| 2 | フォント | Helvetica Neue Bold（OS バンドル） | バンドル OFL フォント Inter。レガシー `.kakico` の "Helvetica Neue" はデコード時に Inter へマップ。テキストのピクセル単位の描画差・折り返し位置差を許容 | 決定論的テキスト計測（01-architecture §1） |
| 3 | ピクセレート実装 | CIPixellate（rect 中心アンカー、ソフトウェア CI） | Canvas 縮小→拡大（smoothing off）、キャンバス固定グリッドにスナップ。ブロック境界・各ブロック色のピクセル単位差を許容。ブロックサイズ `max(2, amount)` は同一 | CIPixellate は再現不能（01-architecture §6） |
| 4 | 終了確認 | "Quit Kakico?" カスタムアラート（⌘Q/⌘W/赤ボタン全経路） | `beforeunload`（`dirty` 時のみ）。文言はブラウザ標準でカスタム不可。⌘W/タブ閉じもこれで担保 | ブラウザ制約 |
| 5 | 失敗フィードバック | `NSSound.beep()` | エラートースト表示 | 音は web で不適（01-architecture §7 "failures always surface a toast"） |
| 6 | ファイルダイアログ | NSOpenPanel / NSSavePanel | File System Access API（Chromium）。Safari/Firefox は `<input type=file>` / `<a download>` フォールバック — ⌘S のサイレント上書き保存は Chromium のみ、他は毎回ダウンロード | プラットフォーム API 差 |
| 7 | クリップボード形式 | PNG + TIFF の具象バイト | `ClipboardItem` の `image/png` のみ（TIFF なし）。Firefox の明示 Paste ボタンは「⌘V を押してください」ヒント表示 | Async Clipboard API 制約 |
| 8 | メニューバー | macOS メニュー（File/Edit/View/Tools）+ Edit メニューフィルタ | メニューバーなし。全コマンドはショートカット + UI ボタンで提供。EditMenuFilter は不要 | web にネイティブメニューなし |
| 9 | ウィンドウ | 最小 720×520、単一ウィンドウ、タイトル "Kakico" | ブラウザウィンドウ任意サイズ（レスポンシブ）。PWA manifest `launch_handler: focus-existing` で単一ウィンドウ相当 | ブラウザ制約 |
| 10 | 自動保存 | なし（終了時に破棄確認のみ） | IndexedDB 自動保存によるクラッシュ/リロード復元を**追加** | 09-pwa.md（web の利点として追加） |
| 11 | アイコン | SF Symbols | `src/ui/icons.tsx` のオリジナル SVG（モチーフは同等、字形は非同一） | クリーンルーム方針 |
| 12 | クロームのフォント | SF Pro（システム） | `system-ui` フォントスタック（OS により字形差） | プラットフォーム差 |
| 13 | ズーム時の注釈画質 | scale-1 flatten を高品質補間で拡大（ズーム > 100% でソフト） | Layer B ベクターを毎フレーム `dpr × zoom` で描画（常にクリスプ）。**Mac 版より高品質になる方向の差のみ許容** | 01-architecture §5 |
| 14 | ピンチ式 | `oldScale * (1 + magnification)` | `scale *= exp(-deltaY * 0.01)`（ctrl+wheel）+ Safari gesture イベント。カーソルアンカー・clamp `[min(0.25, fit), 4.0]` は同一 | イベントモデル差（01-architecture §6） |
| 15 | パネルの素材感 | `.regularMaterial`（OS ブラー） | 半透明背景 + `backdrop-filter: blur`（近似） | CSS 近似 |
| 16 | ツールチップ | `.help`（即時、スタイル統一） | `title` 属性（表示遅延・見た目はブラウザ依存） | ブラウザ制約 |
| 17 | `.kakico` の `version` | フィールドなし | `"version": 1` を追加（Swift 版は未知キーとして無視 — クロス互換維持） | 01-architecture §2 codec |
| 18 | 更新通知 | なし | SW 更新時 "Reload to update" トーストを**追加** | 09-pwa.md |
| 19 | エクスポート形式選択 | NSSavePanel の拡張子でユーザーが選択 | ピッカー対応ブラウザは同等。フォールバック時は PNG デフォルト + JPEG 選択 UI（08-io-export.md の仕様） | プラットフォーム API 差 |
| 20 | ActionBar | 3 タイル（well/copy/export） | 先頭に Undo・Redo タイル + 縦区切りを**追加**（メニューバー不在の代替）。Mac との厳密一致比較時はこの 2 タイル + 区切りを除外 | 07-ui-chrome.md §8 |
