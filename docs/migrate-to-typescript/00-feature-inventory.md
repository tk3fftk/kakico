# 00. 機能インベントリ — 現行 macOS アプリのパリティ契約

## 概要

Kakico (Swift/macOS) の現行機能の正典仕様。TypeScript PWA (`kakico-web/`) は本ドキュメントに列挙されたすべての定数・数式・挙動を再現する。後続ドキュメント (02–09) の実装・テストはすべてここを参照点とする。値はすべて Swift ソースから抽出済みで、各項目に `file:line` 参照を付す。

対象範囲(現行アプリに実在するもののみ):

- アノテーション 6 種: `arrow | line | rectangle | ellipse | text | pixelate` + `Document.crop`(`Sources/AnnotationModel/Annotation.swift:6-12`)
- **存在しない機能**(移植で発明しないこと): stamp、blur、ハイライター、フリーハンド、影(shadow)、テキスト縁取り、複数選択、要素コピー&ペースト、ホバー表示、カーソル変更、ドラッグ中の修飾キー(Shift 正方形拘束等)、右クリックメニュー、スクロールホイールズーム、スマートズーム

---

## 起動と画像入力

### ウィンドウ

| 項目 | 値 | 参照 |
|---|---|---|
| ウィンドウタイトル / id | `"Kakico"` / `"main"`(単一ウィンドウ) | Sources/Kakico/KakicoApp.swift:20 |
| 最小コンテンツサイズ | 720 × 520 pt | Sources/Kakico/KakicoApp.swift:22 |
| 最後のウィンドウを閉じたら終了 | true | KakicoApp.swift (`applicationShouldTerminateAfterLastWindowClosed`) |
| 終了確認ダイアログ | "Quit Kakico?" / "Quitting will discard the image you are editing. Unsaved annotations will be lost." / 確認ボタン "Quit" — ドキュメントが開いている場合のみ。⌘W・赤ボタンも同ルートに集約 | Sources/Kakico/KakicoApp.swift:43-45 |

Web 対応: 終了確認 → `beforeunload` ガード(`dirty` 時)。

### 空状態 (EmptyState)

- アイコン `photo.on.rectangle.angled` 56pt、色 textSecondary(UI.swift:113-114)
- テキスト: **"Open or drop an image to start annotating"**(UI.swift:116)
- ボタン: Primary "Open Image…" → open panel / Secondary "Paste from Clipboard" → paste 確認フロー(UI.swift:119)
- レイアウト: VStack spacing 16、ボタン HStack spacing 12(UI.swift:112,119)

### 画像入力経路(3 つ + .kakico)

1. **ファイルを開く** (⌘O): 対象は `public.image` 全般。ImageIO デコード、**先頭フレームのみ**(`CGImageSourceCreateImageAtIndex(src, 0)`, Sources/Kakico/ImageLoader.swift:9,14)。ダウンスケールなし・EXIF 回転処理なし・色空間変換なし。失敗時はビープ音のみ(CanvasController.swift `loadImage(at:)`)。
2. **ペースト** (⌘V / ⇧⌘V / 空状態ボタン): ペーストボードに画像がなければビープ。ドキュメントが開いている場合は確認ダイアログ "Replace the current image?" / "Pasting will replace the image you are editing. Unsaved annotations will be lost." / "Replace"(ExportService.swift:93-95)。確認後にインラインテキスト編集を終了させてからロード。`sourceURL = nil`。
3. **ドラッグ&ドロップ**: 受け付け型 `[.fileURL, .png, .tiff]`、URL は UTI `"public.image"` でフィルタ(CanvasView.swift:92,624)。**確認なしで即置換**(ペーストと異なる)。ファイルドロップは `sourceURL` を記録。
4. **.kakico を開く** (⇧⌘O): 後述「.kakicoフォーマット」参照。

### ロード時の状態リセット(全経路共通、CanvasController.swift:102-116)

- `canvasSize` = 画像のネイティブピクセルサイズ `(image.width, image.height)`
- `ImageRef`: ファイル由来 → `.file(path)` / それ以外 → `.pngData(空 Data)`(プレースホルダ)
- 新規 `Document`(要素なし、crop なし)。`selection = nil`。**undo/redo スタック全消去**。保留中カラーコミットをキャンセル。`zoomMode = .fit`
- **リセットしないもの**: tool、strokeColor、strokeWidth、exportBounds
- サイズガードはロード時になし。下流の flatten で 256 MP 上限のみ(Renderer.swift:35-36)

---

## ツール

`Tool` enum、宣言順(= レガシー数字ショートカット 0–7 の順)、Sources/Kakico/Tool.swift:

| index | tool | rawValue | label | 文字キー | SF Symbol |
|---|---|---|---|---|---|
| 0 | select | "select" | Select | `v` | cursorarrow |
| 1 | arrow | "arrow" | Arrow | `a` | arrow.up.right |
| 2 | line | "line" | Line | `l` | line.diagonal |
| 3 | rectangle | "rectangle" | Rectangle | `r` | rectangle |
| 4 | ellipse | "ellipse" | Ellipse | `o` | circle |
| 5 | text | "text" | Text | `t` | textformat |
| 6 | pixelate | "pixelate" | Pixelate | `p` | squareshape.split.3x3 |
| 7 | crop | "crop" | Crop | `c` | crop |

- 起動時デフォルトツール: `.arrow`(CanvasController.swift:22)
- ツール切替に副作用なし(選択解除しない、コミットしない)
- **作成ツール中でも既存要素クリックは選択・移動になる**(自動でツールは切り替わらない)。空白クリックのみ作成

### 作成の共通フロー(CanvasView.swift:372-536)

1. mouseDown: 空白 (`PointerTarget.empty`) で作成開始。`strokeColor`/`strokeWidth` の現在値を使用
2. ゼロサイズで要素を追加し即選択、ライブハンドルをドラッグ追従(`drag = .creating(id, role)`)
3. mouseUp: `applyingDefaultInitialSize()` 適用(下記)、undo 1 ステップとしてコミット

**デフォルト配置(クリック配置、Skitch 流)** — Sources/AnnotationModel/Annotation.swift:82-108, Geometry.swift:60-74:

| 定数 | 値 | 参照 |
|---|---|---|
| `degenerateThreshold` | `3`(**厳密に `<`**。ちょうど 3 は非退化) | Geometry.swift:63 |
| segment デフォルトベクトル | `(dx: 100, dy: 70)`(右下方向、`end = start + (100,70)`) | Geometry.swift:65 |
| rect 系デフォルトサイズ | `120 × 90`、**クリック点中心**(`x-60, y-45`) | Geometry.swift:67,70-73 |

- segment(arrow/line): 退化判定は `distance(start,end) < 3`(**生ジオメトリ**。boundingBox ではない)
- rect 系(rectangle/ellipse/pixelate): `max(rect.width, rect.height) < 3`(両軸とも小さい場合のみ。2×200 の細長ドラッグは意図的として保持)
- text: 常に変更なし(作成時に既定サイズ済み)
- kind は常に保持される

### arrow(SegmentElement)

- ペイロード: `{id, start, end, color = .red, width = 6}`(Elements.swift:8-16)
- レンダリング: **塗りつぶし 6 点ポリゴン 1 個のみ**(ストロークなし)。`arrowOutline()`(Elements.swift:38-64)を逐語移植:

```
dx = end.x - start.x;  dy = end.y - start.y
length = hypot(dx, dy)
if (length <= 0.5) return []              // 描画なし (Elements.swift:41)
ux = dx/length; uy = dy/length            // 軸単位ベクトル
px = -uy;       py = ux                   // 垂直単位ベクトル
shaftHalf = max(1, width * 0.5)           // Elements.swift:46
headHalf  = max(shaftHalf * 2.4, width * 1.8)   // Elements.swift:47
headLen   = min(max(width * 4.0, 14), length * 0.85)  // Elements.swift:48
notch     = headLen * 0.30                // Elements.swift:49
baseX     = length - headLen
notchX    = baseX + notch
pt(t, o) = (start.x + ux*t + px*o, start.y + uy*t + py*o)
points = [pt(length,0),          // 0: tip == end
          pt(baseX,  headHalf),  // 1: 上バーブ
          pt(notchX, shaftHalf), // 2: 上ノッチ
          pt(0, 0),              // 3: tail == start(尾は点。幅ゼロ)
          pt(notchX,-shaftHalf), // 4: 下ノッチ
          pt(baseX, -headHalf)]  // 5: 下バーブ
```

- width 6 のとき: shaftHalf=3, headHalf=max(7.2,10.8)=10.8, headLen=min(24, 0.85·length)
- ハンドル: `[start, end]` の 2 個(Elements.swift:30)

### line(SegmentElement、arrow と同一ペイロード)

- レンダリング: `start`→`end` の単純ストローク。色/幅は要素値、lineCap/lineJoin ともに `.round`(Renderer.swift:106-107)

### rectangle / ellipse(ShapeElement)

- ペイロード: `{id, rect, color = .red, width = 6, fill: RGBAColor? = nil}`(Elements.swift:82-90)。アプリは fill を設定しない(常に nil)
- レンダリング: fill があれば先に塗り、その後 rect/楕円(rect 内接)をストローク。**ストロークはパス中央揃え**(内外に width/2 ずつ)

### text(TextElement)

- モデル既定: `{origin(左上), size = 160×40, string = "", font = FontSpec(), color = .red}`(Elements.swift:108-124)
- **キャンバスからの新規作成は 220 × 44** で上書き(CanvasView.swift:480)、`pointSize = max(18, strokeWidth * 4)`、`color = strokeColor`。クリック配置のみ(ドラッグ作成なし)。作成直後にインライン編集開始
- レンダリング: 空文字は描画なし。word-wrap 幅 = `size.width`、`size.height` に収まらない行は**黙って落とす**(CoreText frame 挙動; Renderer.swift:181-190)。左揃え、影・縁取りなし

### pixelate(RedactionElement)

- ペイロード: `{id, rect, amount = 14}`(`defaultPixelateAmount = 14`, Elements.swift:132-134)
- レンダリング(Renderer.swift:192-212):
  - ガード: base 画像なし、または `rect.width <= 1 || rect.height <= 1` → **不透明 50% グレー `rgba(0.5,0.5,0.5,1)` で塗りつぶし**(Renderer.swift:194-196)
  - 本処理: **ベース画像のみ**をソースに `CIPixellate` 相当。ブロックサイズ `max(2, amount)` px、グリッドは**矩形の中心にアンカー**、端はエッジクランプ(`clampedToExtent`)で不透明維持(Renderer.swift:205-208)
  - pixelate より前(下)の注釈はモザイクに含まれない(常にベース画素を表示)。後(上)の注釈はモザイクの上に描かれる
- Web 実装指針(アーキ決定 §6): `ceil(rect/amount)` px の OffscreenCanvas に縮小描画 → `imageSmoothingEnabled = false` で拡大戻し。サンプリングはキャンバス固定グリッドにスナップ

### crop(ツール)

「クロップ」セクション参照。

---

## 選択・移動・リサイズ

### ポインタ解決(優先順位、Sources/AnnotationModel/PointerTarget.swift:20-38)

`resolvePointer(at:selection:bodyTolerance:handleTolerance:)` — select ツールと作成ツールで共用:

1. **選択中要素のハンドル**: `handles()` を順に走査(segment: `[start, end]` / rect 系: `[topLeft, topRight, bottomLeft, bottomRight]`)、`distance(handle.position, point) <= handleTolerance`(ユークリッド、円形判定)の**最初の一致** → `.handle`。ハンドルは選択中要素にのみ存在
2. **本体ヒット**: `Document.hitTest` — `elements.reversed()` を走査し最初にヒットした要素(**最前面優先**。描画順 = 配列順) → `.body`
3. **選択フレーム内フォールバック**: 選択中要素の `boundingBox().contains(point)` → `.body(選択要素)`(未塗り図形の中空内部をドラッグ可能にする。選択中のみ)
4. それ以外 → `.empty`(作成ツールなら作成開始、select なら選択解除)

### ヒットテスト式(モデル空間、tolerance は呼び出し側供給)

| 種別 | 式 | 参照 |
|---|---|---|
| segment (arrow/line) | `distanceToSegment(p, start, end) <= max(tolerance, width)` | Elements.swift:26 |
| shape 塗りあり | `rect.insetBy(-tolerance).contains(p)` | Elements.swift:98 |
| shape ストロークのみ | `t = max(tolerance, width)`; `rect.insetBy(-t)` 内 **かつ** `rect.insetBy(+t)` 外(エッジ帯のみ。ellipse も**矩形帯**で判定) | Elements.swift:100-102 |
| text / pixelate | `rect.insetBy(-tolerance).contains(p)` | Handle.swift:58 |
| 点–線分距離 | `t = clamp(((p-a)·d)/|d|², 0, 1)` の射影距離(端点クランプ) | Geometry.swift:83-95 |

`CGRect.contains` は半開区間(max 辺は排他)。

### 許容量 (tolerance)

- `modelTolerance = 8 / max(scale, 0.0001)` — **ビュー 8pt 固定**をモデル単位に変換(CanvasView.swift:154)。body/handle とも同値

### boundingBox

| 種別 | 式 | 参照 |
|---|---|---|
| segment | `CGRect(corner: start, end).insetBy(dx: -width, dy: -width)` | Elements.swift:22 |
| shape | `rect.insetBy(dx: -width, dy: -width)` | Elements.swift:95 |
| text / pixelate | `rect` そのまま | Handle.swift:55 |

### ハンドルとリサイズ(Handle.swift)

- `HandleRole`: `move, start, end, topLeft, topRight, bottomLeft, bottomRight` の 7 種
- `opposite`: `topLeft↔bottomRight`、`topRight↔bottomLeft`、他は nil(Handle.swift:5-25)
- コーナーリサイズ: `movingCorner(role, to: p)` = 移動点と**対角コーナー**から `CGRect(corner: p, opposite)` を再構築(Handle.swift:84-93)。対角を越えるドラッグは min/abs 正規化で自然に反転。アスペクト固定・最小サイズ・修飾キーなし
- segment の `moveHandle`: `.start`/`.end` のみ有効、他ロールは no-op(Elements.swift:66-72)

### ドラッグ状態機械(CanvasView.swift:48-55, 491-536)

状態: `none | moving(id, last) | handle(id, role) | creating(id, role) | cropping(anchor) | movingCrop(last)`

- `.moving`: `delta = p - last` で `translate(by:)`、`last = p` 更新(デルタ方式)
- `.handle` / `.creating`: `moveHandle(role, to: p)`
- **ドラッグ中は DisplayInfo を凍結**(`dragDisplayInfo`、CanvasView.swift:57-62): expandToFit で要素が画像外へ出るとキャンバス矩形が成長しマッピングが変わる暴走フィードバックを防ぐ。mouseUp で解除・再フィット
- mouseDown で `beginInteraction()`、mouseUp で `commitInteraction()`(変更があった場合のみ undo 1 ステップ)

### 選択の描画(キャンバス内描画。DOM ハンドル不使用)

| 項目 | 値 | 参照 |
|---|---|---|
| 選択枠 | `boundingBox()` をビュー変換し `insetBy(-2,-2)`(2pt 外側)、色 miroBlue #4262FF、線幅 2 | CanvasView.swift:299-301; Theme.swift:34 |
| ハンドル円 | 9×9 pt(中心−4.5)、白塗り、miroBlue ストローク幅 1.5(crop ハンドルは幅 1) | CanvasView.swift:288-295 |

### 削除

- Delete / Fwd-Delete(keyCode 51/117)→ `deleteSelection()`: `perform { remove(id) }` + `selection = nil`。undo 1 ステップ(CanvasView.swift:596; CanvasController.swift)

### ダブルクリック

- `clickCount == 2` で text 要素にヒット → **どのツールでも**選択+インライン編集開始(CanvasView.swift:381)

---

## クロップ

### 非破壊 (pending) フェーズ

- crop ツールのドラッグが `document.crop: CGRect?`(モデル空間)を書く。適用まで非破壊・再編集可能。ツール切替後も維持
- mouseDown(crop ツール、CanvasView.swift:432-450):
  1. 既存 crop の 4 コーナー: ビュー座標で `hypot(...) <= 8` **ビュー pt**(要素ハンドルと異なりビュー空間判定)→ `.cropping(anchor: 対角コーナー)`
  2. crop 内部クリック → `.movingCrop(last: p)`
  3. それ以外 → 新規 `crop = CGRect(corner: p, p)`、`.cropping(anchor: p)`
- ドラッグ: `.cropping` → `crop = CGRect(corner: anchor, p)` / `.movingCrop` → `offsetBy(delta)`
- mouseUp: `crop = document.clampedCrop(crop)` — キャンバス `(0,0,canvasSize)` と交差、**交差が null または `width < 2 || height < 2` なら nil(crop 消滅)**(Document.swift:69-73)

### クロップオーバーレイ描画(CanvasView.swift:309-360)

| 項目 | 値 | 参照 |
|---|---|---|
| 減光 | imageRect 全体を黒 45% で塗り、crop 窓は flatten 画像をクリップ再描画(全輝度) | CanvasView.swift:311 |
| アンダーレイ線 | 黒 55%、幅 1 | CanvasView.swift:322-323 |
| マーチングアンツ | 白破線、パターン `[5, 4]`、幅 1、`phase = antsPhase` | CanvasView.swift:325-326 |
| アンツタイマー | `1/12` 秒(12 Hz)、tick ごと `antsPhase += 1`。crop 表示中のみ動作。アプリ非アクティブで停止 | CanvasView.swift:337-360 |
| ダーティ矩形 | crop ビュー矩形の `insetBy(-8,-8)`(9pt ハンドルを覆う) | CanvasView.swift:348 |
| コーナーハンドル | 9×9 白円、miroBlue ストローク幅 1 | CanvasView.swift:333 |

Web: `setLineDash([5,4])` + `lineDashOffset`、rAF を ~12 Hz にスロットル、`visibilitychange` で停止。

### 適用・キャンセル

- **適用**(Return/keypad Enter = keyCode 36/76、または "Apply Crop" ボタン)— `applyCrop()`(CanvasController.swift:286-301):
  - `integralCrop` = clampedCrop 後に `.integral`(整数ピクセルへスナップ、Document.swift:77-79)
  - base 画像を `cropping(to:)`、`crop = nil`、`canvasSize = clamped.size`、**全要素を `(-clamped.minX, -clamped.minY)` 平行移動**
  - undo push は手動: `(document, baseImage)` ペアをスナップショット(画像も入れ替わるため)
- **キャンセル**(Esc = keyCode 53、または "Cancel" ボタン)— `cancelCrop()`: `perform { crop = nil }`(undo 可能)
- CropActionBar(画面下部、`crop != nil` の間のみ): `MiroPrimaryButton("Apply Crop")` tooltip "Apply the crop (Return)" / plain "Cancel" tooltip "Cancel the crop (Esc)"(UI.swift:372-381)

### エクスポートとの関係

- pending crop はエクスポートで尊重される(`outputRect = crop ?? full`)。expandToFit では crop 起点で注釈 bbox を union するため crop 外注釈が出力を広げる
- 画面表示は常に **crop を nil にしたコピー**を flatten(全体を表示しつつオーバーレイで crop を示す。CanvasView.swift:162-166)

---

## Undo・Redo

スナップショット方式(コマンド方式ではない)。CanvasController.swift:

- undo 単位: `State { document: Document, image: CGImage? }` — **base 画像込み**(破壊的 crop が画像を差し替えるため)
- `beginInteraction()`: `flushPendingCommit()` 後、現在の `(document, baseImage)` を `interactionSnapshot` へ
- `commitInteraction()`: `snapshot.document != document`(値比較)のときのみ **pre 状態**を undoStack へ push し redoStack をクリア。無変更なら何も積まない
- `perform(fn)`: 単発変更。無変更なら document 再代入すらしない(version も上がらない)
- `undo()` / `redo()`: pop → 現状態を反対スタックへ → `document` と `baseImage` を復元 → `clampSelection()`(消えた選択 id は nil 化、その後 `syncToolStateFromSelection()`)
- **スタック上限なし**。selection / tool / zoom / crop UI 状態は復元対象外
- `documentVersion`: document への**全書き込みで** `&+= 1`(等値でも)。flatten キャッシュの無効化キー(CanvasController.swift:12-17)
- **カラーデバウンス**: `strokeColor.didSet` → 選択要素へ適用。pending タスクがなければ `beginInteraction()`、**500 ms** 後に `commitInteraction()`。500 ms 内の連続変更は 1 undo ステップに合体(CanvasController.swift:250)
- `selectStrokeColor(color)`(プリセットタップ): `flushPendingCommit(); strokeColor = color; flushPendingCommit()` — 正確に 1 undo ステップ、隣とは合体しない
- `flushPendingCommit()`: `beginInteraction` / `perform` / `undo` / `redo` の先頭で必ず呼ぶ
- undo 境界の責務: 幅スライダーのドラッグは begin/commit で括る(呼び出し側)。テキスト編集コミットは `perform` 1 ステップ
- 画像ロードで undo/redo 全消去

---

## ズーム・パン

### ZoomMode と定数(Sources/Kakico/ZoomMath.swift)

| 項目 | 値 | 参照 |
|---|---|---|
| `ZoomMode` | `fit` \| `percent(CGFloat)`。`.percent(1.0)` = 1 画像ピクセル / 1 ビューポイント | ZoomMath.swift:3-8 |
| presets | `[0.25, 0.5, 1.0, 2.0, 4.0]` | ZoomMath.swift:14 |
| `percentLabel(for:)` | `"\(Int((scale * 100).rounded()))%"` | ZoomMath.swift:17-19 |
| `fittedScale(canvas, viewport)` | `min(vw/cw, vh/ch)`; canvas 辺が 0 以下なら `1` | ZoomMath.swift:22-25 |
| `clampedScale` | `floor = min(0.25, fittedScale)`; `min(max(scale, floor), 4.0)` | ZoomMath.swift:35-38 |
| `clampedPan`(軸ごと) | `slack = (content - viewport)/2`; `slack <= 0` → `0`; それ以外 `clamp(v, -slack, +slack)` | ZoomMath.swift:42-50 |
| `imageRect` | origin `((vw-cw)/2 + pan.dx, (vh-ch)/2 + pan.dy)`、size = `canvas * scale`(pan は clamp 後) | ZoomMath.swift:54-60 |
| `panPreservingCenter` | `oldScale <= 0` なら oldPan; `f = new/old`; `pan * f` | ZoomMath.swift:64-68 |
| `panPreservingPoint`(軸ごと) | `rectMin = (viewport - canvas*old)/2 + pan; newRectMin = v - (v - rectMin)*f; result = newRectMin - (viewport - canvas*new)/2` | ZoomMath.swift:75-87 |
| `zoomInScale(from)` | `presets.first { $0 > current * 1.001 } ?? 4.0` | ZoomMath.swift:92-94 |
| `zoomOutScale(from)` | `presets.last { $0 < current * 0.999 } ?? 0.25` | ZoomMath.swift:97-99 |
| pan の定義 | 画像**中心**のビューポート**中心**からの変位(ビュー pt) | ZoomMath.swift:11-12 |
| テスト許容差 | 0.0001 | Tests/KakicoTests/ZoomMathTests.swift:7 |

テストで固定された不変条件: 0.63 から zoomIn → 1.0 / 1.0 → 2.0 / 4.0・10.0 → 4.0。0.63 から zoomOut → 0.5 / 1.0 → 0.5 / 0.25・0.1 → 0.25。1000×1000 画像を 100×100 ビューポートで clampedScale → floor 0.1。

### コントローラ側 API

- `zoomIn()/zoomOut()` は **`effectiveZoomScale`(実描画スケール)から**ステップ(fit 比率 0.63 → 1.0 など)
- `effectiveZoomScale`: ビューが描画時に `reportEffectiveZoomScale` で書き戻す。ズーム UI の % ラベルはこれを表示
- `zoomMode` は undo 対象外の一時状態。ロードで `.fit` にリセット

### ジェスチャ(CanvasView.swift:540-589)

- **スクロールパン**: `.percent` モードのみ、注釈ドラッグ中は無効、コンテンツがビューポートをはみ出す軸がある場合のみ。`pan.dx += scrollingDeltaX; pan.dy -= scrollingDeltaY`(NSView が非フリップ y-up のためマイナス。**y-down Canvas では `+=`**)。clamp 後、開いているテキストエディタのフレームを追従(CanvasView.swift:556-557)
- **ピンチズーム**(カーソルアンカー): `newScale = clampedScale(oldScale * (1 + magnification), ...)`(CanvasView.swift:573)。無変化なら return。テキストエディタが開いていればコミット。`pan = panPreservingPoint(cursor, ...)` → clamp → `setZoom(newScale)` + 即 `reportEffectiveZoomScale`(reconcile がセンター再アンカーするのを防ぐ)。Web では `wheel + ctrlKey`(`scale *= exp(-deltaY * 0.01)`)と Safari `gesturestart/gesturechange`
- **⌘+/⌘−/⌘0**: プリセットステップ / fit。センターアンカー(`panPreservingCenter`)。ズームスケール変化時に開いているテキストエディタをコミット
- fit モードは `outputRect(for: exportBounds)`(pending crop + exportBounds を尊重)で `fittedScale` を再計算。ウィンドウリサイズでライブ再フィット。fit 中は `panOffset = .zero`
- **存在しない**: スクロールホイールズーム、スマートズーム(ダブルタップ)

### ズーム UI

- `ZoomMenuButton`(右下): ライブ % + `chevron.down`(8pt semibold)、フォント miroCaption。メニュー項目 "25% / 50% / 100% / 200% / 400%" + Divider + "Fit to Window"(UI.swift:402-407)

---

## テキスト編集

インライン `<textarea>` 相当(macOS では NSTextView オーバーレイ)。CanvasView.swift:640-731:

- **開始**: text 要素をダブルクリック(全ツール)、または text ツールで空白クリック(新規作成)
- エディタフレーム: `viewRect(element.boundingBox()).insetBy(dx: -2, dy: -2)`(2pt の余白、CanvasView.swift:646)
- フォント: `element.font.pointSize * displayScale`(ズーム倍率を掛ける、CanvasView.swift:725)、family + bold 一致、色 = 要素色
- 背景: `textBackgroundColor @ alpha 0.9`(CanvasView.swift:660)
- 編集中は `controller.isEditingText = true` → 無修飾文字ツールショートカットを無効化
- **ライブ自動サイズ**: 入力ごとに `Renderer.suggestedSize(for:)` で再フレーム(下記式)。スクロールパン後も再同期
- **コミット**トリガー: キャンバス上の mouseDown、フォーカス喪失、ズームスケール変化(reconcile / ピンチ)、別要素の編集開始
  - 空文字 → **要素削除**(選択中なら選択解除)
  - それ以外 → `perform { string 更新; size = suggestedSize }` の undo 1 ステップ
  - **明示キャンセル(元テキスト復元)は存在しない** — 常に現内容を適用
- 編集中もモデル要素は下に描画されたまま(半透明エディタが覆う)。Web 版は `skipElement` で renderer 側をスキップする方式(アーキ決定 §6)

### suggestedSize(Renderer.swift:169-179)— renderer とエディタで単一のラップアルゴリズムを共有

```
空文字     → (e.size.width, e.font.pointSize + 8)
それ以外   → fit = 幅 e.size.width で高さ無制限のラップ計測
             (e.size.width, max(ceil(fit.height) + 2, e.font.pointSize + 8))
```

- 幅は不変(ラップ制約)。`+2` は端数丸めで最終行が切れるのを防ぐ(Renderer.swift:178)
- テスト不変条件: 長文の高さ > 短文 > 初期 44; 空文字の高さ == pointSize + 8 ちょうど

### FontSpec(Geometry.swift:28-50)

| 項目 | 値 | 参照 |
|---|---|---|
| デフォルト | family `"Helvetica Neue"`, pointSize `28`, bold `true` | Geometry.swift:33 |
| `suggestedPointSize(forStrokeWidth w)` | `max(18, w * 4)` | Geometry.swift:42 |
| `strokeWidth(forPointSize p)` | `p / 4`(クランプなし) | Geometry.swift:48 |

Web: バンドルした Inter を既定 family とし、レガシー "Helvetica Neue" はデコード時にマップ(アーキ決定 §1)。

---

## カラー・線幅

### 状態と同期(CanvasController.swift)

- `strokeColor` デフォルト `.red`、`strokeWidth` デフォルト `6`(CanvasController.swift:26,29)
- **選択 → コントロール同期**(`syncToolStateFromSelection`、`isSyncing` 再入ガード付き):
  - text 要素: `strokeWidth = pointSize / 4`
  - それ以外で strokeWidth 非 nil: 採用
  - color 非 nil: 採用
- **コントロール → 選択要素適用**(didSet フック、isSyncing 中はスキップ):
  - `strokeWidth` 変更 → text は `pointSize = max(18, w*4)` + `size = suggestedSize` 再計測 / 非 text は width 書き込み
  - `strokeColor` 変更 → 500 ms デバウンス undo(前節)。rect/ellipse では**ストローク色のみ**(fill は不変)
- `strokeWidth`/`color` アクセサ: text・pixelate は strokeWidth nil(setter no-op)、pixelate は color も nil(Annotation.swift:34-76)

### カラープリセット(8 色、パネル上→下順。RGBAColor 宣言順と異なり White が Black より先)

| 名前 | RGBA (0–1) | Hex | 参照 |
|---|---|---|---|
| Red | (0.90, 0.16, 0.22, 1) | ≈#E62938 | Geometry.swift:18 |
| Orange | (0.98, 0.55, 0.10, 1) | ≈#FA8C1A | Geometry.swift:19 |
| Yellow | (1.0, 0.80, 0.0, 1) | #FFCC00 | Geometry.swift:20 |
| Green | (0.16, 0.70, 0.30, 1) | ≈#29B34D | Geometry.swift:21 |
| Blue | (0.0, 0.48, 1.0, 1) | ≈#007AFF | Geometry.swift:22 |
| Pink | (0.96, 0.40, 0.68, 1) | ≈#F566AD | Geometry.swift:23 |
| White | (1, 1, 1, 1) | #FFFFFF | Geometry.swift:25 |
| Black | (0, 0, 0, 1) | #000000 | Geometry.swift:24 |

- スウォッチ: 22×22 円 + padding 3、miroDivider 1pt 枠。選択中(r/g/b/a の厳密等値)は miroBlue 2pt リング。クリック → `selectStrokeColor`(UI.swift:289-315)
- カスタム色: システム ColorPicker(opacity 対応、tooltip "Custom color…")、**`strokeColor` 直接代入**(selectStrokeColor 経由でない → デバウンス経路、UI.swift:322-324)
- プリセットパネルはスウォッチボタンでトグル、選択後も開いたまま。トランジション scale 0.95 (anchor leading) + opacity、easeOut 0.1s(UI.swift:159-167)

### 線幅スライダー(MiroSlider、UI.swift:214-271)

| 項目 | 値 |
|---|---|
| 範囲 | 1…40、連続値(スナップなし)、幅 140 |
| ノブ / トラック | 直径 16 / 高さ 4 |
| 塗り幅 | `knob/2 + fraction * (width - knob)`、色 miroBlue |
| ノブ装飾 | 白、黒 12% 0.5pt 枠、影 (黒 25%, radius 1, y 0.5) |
| ドラッグ式 | `x = clamp(loc.x - knob/2, 0, usable)`; `value = lower + (x/usable) * span` |
| undo | ドラッグ開始/終了で `beginInteraction()` / `commitInteraction()` |

ポップオーバー: lineweight アイコン + スライダー、padding 12、arrowEdge trailing(UI.swift:214-227)。

---

## キーボードショートカット一覧

### アプリコマンド(KakicoApp.swift:205-268)

| ショートカット | 動作 | 無効条件 | 参照 |
|---|---|---|---|
| ⌘O | Open Image… | — | KakicoApp.swift:205 |
| ⇧⌘O | Open Kakico Document… | — | KakicoApp.swift:207 |
| ⇧⌘V | Paste Image(明示エイリアス) | — | KakicoApp.swift:211 |
| ⌘W | Close(終了確認へルート) | — | KakicoApp.swift:218 |
| ⌘S | Save Kakico Document… | ドキュメントなし | KakicoApp.swift:221 |
| ⌘E | Export Image… | ドキュメントなし | KakicoApp.swift:224 |
| ⇧⌘C | Copy Image to Clipboard | ドキュメントなし | KakicoApp.swift:227 |
| ⌘Z | Undo | `!canUndo` | KakicoApp.swift:240 |
| ⇧⌘Z | Redo | `!canRedo` | KakicoApp.swift:243 |
| ⌘+ | Zoom In(effectiveScale から次プリセット) | ドキュメントなし | KakicoApp.swift:251 |
| ⌘− | Zoom Out | ドキュメントなし | KakicoApp.swift:254 |
| ⌘0 | Fit to Window | ドキュメントなし | KakicoApp.swift:257 |

### ツール切替(無修飾)

| キー | ツール | 無効条件 | 参照 |
|---|---|---|---|
| v / a / l / r / o / t / p / c | Select / Arrow / Line / Rectangle / Ellipse / Text / Pixelate / Crop | `isEditingText` | Tool.swift:29-40; KakicoApp.swift:263-268 |
| 0–7(無修飾数字) | `Tool.allCases[digit]`(0=Select … 7=Crop) | 修飾キー押下時・テキスト入力中 | KakicoApp.swift:90-100 |

### キーモニタ(メニュー外)

| キー | 動作 | 条件 | 参照 |
|---|---|---|---|
| ⌘V(⌘のみ) | 画像ペースト(ドキュメントありなら置換確認) | テキスト入力中はパススルー | KakicoApp.swift:74-77 |
| ⌘C(⌘のみ) | flatten 画像をクリップボードへ | `hasDocument && selection == nil` のときのみ消費。選択中はパススルー(将来の要素コピー予約) | KakicoApp.swift:82-86 |

### キャンバス keyDown(CanvasView.swift:593-616)

| keyCode | キー | 動作 |
|---|---|---|
| 51 / 117 | Delete / Fwd-Delete | `deleteSelection()` |
| 36 / 76 | Return / keypad Enter | pending crop あり → `applyCrop()`; なければパススルー |
| 53 | Escape | pending crop あり → `cancelCrop()`; なければ選択解除 |

Web 実装: capture-phase keydown、`isEditingText` 中は文字キー抑止(`src/keyboard/shortcuts.ts`)。

---

## エクスポート・クリップボード・ドラッグアウト

### flatten パイプライン(Renderer.swift:29-58)— 画面とエクスポートで同一関数(WYSIWYG)

1. `out = doc.outputRect(for: bounds)`
2. `pixelW = Int((out.width * scale).rounded())`、高さも同様
3. ガード: `pixelW > 0 && pixelH > 0 && pixelW <= 268435456 && pixelH <= 268435456 && pixelW*pixelH <= 268435456`(256·1024·1024)を満たさなければ nil(Renderer.swift:35-36)
4. ビットマップ: sRGB、8 bpc、RGBA premultipliedLast(Renderer.swift:38-41)
5. **`.expandToFit` のとき出力矩形全体を不透明白 (1,1,1,1) で塗る**。`.clipToImage` はベース外が透明のまま(Renderer.swift:51-54)
6. ベース画像を `(0,0,canvasSize)` へ描画 → 要素を**配列順**に描画
7. アプリの全呼び出しは `scale: 1`(Retina 乗算なし。エクスポート画素 == モデル単位)

### ExportBounds(Document.swift:4-46)

| 項目 | 値 | 参照 |
|---|---|---|
| rawValue | `"expandToFit"` / `"clipToImage"` | Document.swift:4-7 |
| 永続化 | UserDefaults キー `"exportBounds"`、デフォルト `.expandToFit` | CanvasController.swift:32,38 |
| `outputRect` | `crop ?? (0,0,canvasSize)` | Document.swift:27-29 |
| `expandedOutputRect()` | outputRect ∪ 全要素 boundingBox → `.integral`(要素なしなら outputRect のまま)。負の origin あり得る | Document.swift:31-39 |
| flatten デフォルト | `.clipToImage`(パラメータ既定。アプリは常に controller 値を渡す) | Renderer.swift:31 |
| メニューラベル | "Expand to Fit Annotations" / "Clip at Image Boundary" | KakicoApp.swift:234-235 |

### エンコード(Renderer.swift:61-70)

- PNG / JPEG。`jpegQuality = 0.9`(PNG では無視)。PNG マジック `89 50 4E 47` をテストで確認

### エクスポートパネル(ExportService.swift:44-68)

- 形式 `[.png, .jpeg]`。既定ファイル名 `"{sourceBasename}.png"`、source なし(ペースト由来)は `"annotated.png"`(ExportService.swift:49-50)
- 拡張子 `jpg`/`jpeg`(小文字比較)→ JPEG、それ以外は全部 PNG(ExportService.swift:53-54)

### クリップボードコピー(ExportService.swift:24-42)

- scale 1 で flatten → **具象バイト**(PNG + TIFF)をペーストボードへ(遅延プロミス不可 — クリップボードマネージャ互換のため)。失敗はビープ
- 成功時トースト **"Copied to clipboard"**(ExportService.swift:41)
- Web: `ClipboardItem({'image/png': Promise<Blob>})`(Safari のジェスチャ要件のため Promise 値で)

### ドラッグアウト(UI.swift:442-513)

| 項目 | 値 | 参照 |
|---|---|---|
| ウェル | ActionBar 内 32×32、アイコン `square.and.arrow.up` 18×18 中央、無効時 alpha 0.3、tooltip "Drag out to share as PNG" | UI.swift:339,470-475 |
| 動作 | **mouseDown 時点で同期的に PNG 生成**(現 exportBounds・pending crop を尊重)。ドロップ内容はドラッグ開始時のスナップショット | UI.swift:479-492 |
| ファイル名 | `"{sourceBasename}.png"` / `"annotated.png"` | UI.swift:497-498 |
| 操作 | `.copy` | UI.swift:492 |

Web: Chromium の `DownloadURL` + `image/png` アイテム。非対応環境ではウェルを隠す。

### ActionBar(右上、UI.swift:337-357)

HStack spacing 4、floating panel。順: DragOutWell → `doc.on.clipboard`(tooltip "Copy image to clipboard")→ `square.and.arrow.down`(tooltip "Export image")。タイルは icon 16pt / 36×36、ドキュメントなしで disabled。

### サイズバッジ(UI.swift:418-440)

- `out = document.outputRect(for: exportBounds).integral`; ラベル `"\(Int(out.width)) × \(Int(out.height))"`(U+00D7、前後スペース)
- pending crop あり: `"<outW> × <outH> (<canvasW> × <canvasH>)"`(元サイズを括弧書き)
- exportBounds と pending crop の両方をライブ追跡

### トースト(UI.swift:75-105; CanvasController.swift:53-66)

- 下部中央カプセル、bottom padding 24、`checkmark.circle.fill`(miroSuccess)+ miroControl フォント、hit-testing 無効
- **1.8 秒**で自動消滅(再表示でタイマーリスタート)。アニメーション easeOut 0.18s、opacity + y+8 オフセット(Reduce Motion 時は opacity のみ)

---

## .kakicoフォーマット

単一 JSON ファイル。Swift `JSONEncoder`/`JSONDecoder` の合成 Codable 形式(カスタムキーなし)。レガシーフィクスチャデコードテストで固定(Tests/AnnotationModelTests/AnnotationModelTests.swift:68-87)。**Web codec はこの形状を推測でなく Mac アプリ出力のゴールデンフィクスチャに対して実装する。**

### 保存・読み込みの挙動(ExportService.swift:116-154)

- 保存(⌘S): 既定ファイル名 **`"untitled.kakico"`**(常に。source 由来にしない)。保存時に現 `baseImage` を PNG 再エンコードし `baseImage = .pngData(png)` に置換(自己完結化)。保存しても undo/sourceURL/dirty は変化なし(dirty 追跡自体が存在しない)
- 読み込み(⇧⌘O): `.pngData` かつ CGImage デコード可能が必須。**`.file` 参照のドキュメントはビープして開けない**。成功時: 画像ロード(undo 等リセット)→ `document = doc` で全要素と pending crop を復元。zoom は Fit、sourceURL は nil
- UTType: `UTType(filenameExtension: "kakico") ?? .json`(ExportService.swift:119,138)

### JSON スキーマ全体

```json
{
  "baseImage": { "pngData": { "_0": "<base64 PNG>" } },
  "canvasSize": [800, 600],
  "elements": [ /* Annotation の配列(描画順) */ ],
  "crop": [[10, 20], [300, 200]]
}
```

- `crop` は nil のとき**キー省略**。`baseImage` のもう一形態: `{"file": {"path": "/abs/path.png"}}`
- CoreGraphics 型の Foundation Codable 表現(必ず再現):
  - `CGPoint` → `[x, y]` / `CGSize` → `[w, h]` / `CGRect` → `[[x, y], [w, h]]`
  - `UUID` → 正準 8-4-4-4-12 文字列(Swift は大文字出力、デコードは大小無視 — 小文字フィクスチャも通す)
  - `Data` → base64 文字列。数値は float64、整数形/小数形どちらも受理

**Annotation**(enum-with-payload: ケース名 1 キーのオブジェクト、ペイロードは `"_0"`):

```json
{"arrow":     {"_0": SegmentElement}}
{"line":      {"_0": SegmentElement}}
{"rectangle": {"_0": ShapeElement}}
{"ellipse":   {"_0": ShapeElement}}
{"text":      {"_0": TextElement}}
{"pixelate":  {"_0": RedactionElement}}
```

**要素ペイロード**:

```json
SegmentElement:  {"id": "<uuid>", "start": [x,y], "end": [x,y], "color": RGBAColor, "width": 6}
ShapeElement:    {"id": "<uuid>", "rect": [[x,y],[w,h]], "color": RGBAColor, "width": 6, "fill": RGBAColor?}   // fill は nil で省略
TextElement:     {"id": "<uuid>", "origin": [x,y], "size": [w,h], "string": "…", "font": FontSpec, "color": RGBAColor}
                 // origin/size キーは必須(テスト固定)。computed rect はエンコードされない
RedactionElement:{"id": "<uuid>", "rect": [[x,y],[w,h]], "amount": 14}
RGBAColor:       {"r": 0.9, "g": 0.16, "b": 0.22, "a": 1}
FontSpec:        {"family": "Helvetica Neue", "pointSize": 28, "bold": true}
```

レガシーフィクスチャ(逐語、必ずデコード可能であること):

```json
[{"arrow":{"_0":{"color":{"a":1,"b":0.22,"g":0.16,"r":0.9},"end":[3,4],"id":"11111111-1111-1111-1111-111111111111","start":[1,2],"width":6}}}]
```

- `ExportBounds` は Document には含まれない(設定側の rawValue `"expandToFit"` / `"clipToImage"`)
- Web 追加: トップレベルに `"version": 1` を追加(Mac 版は無視される想定の付加フィールド)。`'blur'` / `'stamp'` ディスクリミナントはコーデックに予約のみ(パリティ後拡張)

---

## UIテーマトークン

### 色(Theme.swift、全 sRGB)

| トークン | RGB (0–1) | Hex | 役割 | 参照 |
|---|---|---|---|---|
| miroBoard | 0.961, 0.961, 0.969 | #F5F5F7 | ライト背景 | Theme.swift:8 |
| miroGrid | 0.843, 0.843, 0.871 | #D7D7DE | ライトグリッドドット | Theme.swift:9 |
| miroSurfaceGray | 0.945, 0.945, 0.957 | #F1F1F4 | ライト hover / 二次ボタン背景 | Theme.swift:10 |
| miroSurfacePressed | 0.902, 0.902, 0.922 | #E6E6EB | ライト pressed | Theme.swift:11 |
| miroDivider | 0.890, 0.890, 0.910 | #E3E3E8 | ヘアライン・枠・トラック | Theme.swift:12 |
| miroDarkBoard | 0.125, 0.125, 0.141 | #202024 | ダーク背景 | Theme.swift:15 |
| miroDarkGrid | 0.220, 0.220, 0.247 | #38383F | ダークドット / ダーク pressed | Theme.swift:16 |
| miroDarkSurface2 | 0.192, 0.192, 0.220 | #313138 | ダーク hover / surface | Theme.swift:17 |
| miroInk | 0.020, 0.000, 0.220 | #050038 | ライト主文字・選択ツールアイコン | Theme.swift:20 |
| miroTextSecondary | 0.420, 0.420, 0.482 | #6B6B7B | ライト副文字 | Theme.swift:21 |
| miroDarkTextPrimary | 0.925, 0.925, 0.937 | #ECECEF | ダーク主文字 | Theme.swift:22 |
| miroYellow | 1.000, 0.816, 0.184 | #FFD02F | ブランドアクセント(選択ツール背景・Primary ボタン) | Theme.swift:25 |
| miroBlue | 0.259, 0.384, 1.000 | #4262FF | インタラクティブアクセント + 選択枠(ライト/ダーク同一) | Theme.swift:26,34 |
| miroSuccess | 0.180, 0.647, 0.416 | #2EA56A | トーストチェック | Theme.swift:29 |

スキームリゾルバ: `textSecondary(dark)` = miroDarkTextPrimary **@ 65% opacity**(Theme.swift:51)。`board/grid/textPrimary/surface` はライト/ダークで上表を切替。ダークモードはシステム追従(アプリ内トグルなし)→ Web は `prefers-color-scheme`。

### タイポグラフィ(Theme.swift:61-64、システムフォント)

| トークン | 値 |
|---|---|
| miroBody | 16pt regular |
| miroControl | 15pt semibold |
| miroButton | 15pt bold |
| miroCaption | 12pt semibold |

### ドットグリッド(Theme.swift:71,85)

- タイル **28pt**、ドット **1.5×1.5pt** をタイル左上に配置。**ウィンドウ固定**(パン・ズームに追従しない)。Web: 28×28 `radial-gradient` の `background-repeat`

### ボタン・パネル(Theme.swift:105-201)

| 項目 | 値 |
|---|---|
| MiroPressStyle | pressed scale 0.98、spring(response 0.25, damping 0.7)(Reduce Motion で無効) |
| PrimaryButton | miroButton、miroInk on miroYellow、padding v10/h20、radius 10 |
| SecondaryButton | miroControl、textPrimary on surface、padding v10/h20、radius 10 |
| TileButtonStyle | radius 11 塗り: pressed = dark miroDarkGrid / light miroSurfacePressed; hover = dark miroDarkSurface2 / light miroSurfaceGray。pressed scale 0.96 |
| FloatingPanel | padding 8、RoundedRect radius 16(Toast は Capsule)、`.regularMaterial`(Web: 半透明背景 + `backdrop-filter: blur`)、影 黒 22% radius 16 y14、枠 miroDivider@50% 1pt |

### レイアウト定数(UI.swift)

| 項目 | 値 | 参照 |
|---|---|---|
| キャンバス padding | leading 76 / trailing 24 / vertical 24 | UI.swift:41-43 |
| パレット leading | 16 | UI.swift:51 |
| ActionBar padding | 16 | UI.swift:57 |
| CropActionBar bottom | 20 | UI.swift:63 |
| ズーム+バッジ | spacing 8 / padding 16 | UI.swift:68,72 |
| トースト bottom | 24 | UI.swift:78 |
| パレットタイル | icon 20pt / 40×40、contentShape radius 11 | UI.swift:133-138 |
| ActionBar タイル | icon 16pt / 36×36 | UI.swift:337,357 |
| パレット VStack spacing | 4; 区切り線 幅 28 pad 4(パレット)/ 幅 22 pad 2(プリセット) | UI.swift:171,192,320 |
| ツール選択アニメ | easeOut 0.12s; crop バー easeOut 0.12s; トースト easeOut 0.18s | UI.swift:82-83,177 |
| スウォッチボタン | RoundedRect r7、22×22 in 40×40、miroDivider 1pt 枠 | UI.swift:197-202 |

### 文言(逐語)

ツールチップ: `"<Label> (<KEY>)"` ×8、"Stroke color"、"Stroke width"、各プリセット色名、"Custom color…"、"Drag out to share as PNG"、"Copy image to clipboard"、"Export image"、"Apply the crop (Return)"、"Cancel the crop (Esc)"、"Zoom"。
メニュー/UI: "Open Image…"、"Open Kakico Document…"、"Paste Image"、"Close"、"Save Kakico Document…"、"Export Image…"、"Copy Image to Clipboard"、"Export Bounds"、"Undo"、"Redo"、"Zoom In"、"Zoom Out"、"Fit to Window"、"Apply Crop"、"Cancel"、"Copied to clipboard"。

Reduce Motion(Web: `prefers-reduced-motion`)で無効化: ツール選択アニメ、プリセットパネル scale、press spring、トースト offset。

---

## 座標系とRetina

### モデル空間(Geometry.swift:4-6、逐語)

> Model coordinate space is image pixel space with a top-left origin and y increasing downward.

- 全ジオメトリ(start/end/rect/origin/size/crop/canvasSize)は**ベース画像ピクセル**単位。1 モデル単位 = 1 画像ピクセル。モデル層はスケール係数を一切知らない
- **HTML Canvas 2D とネイティブに一致** — Swift 側の Y フリップ機構(`Renderer.withYFlip`、flatten の CTM、scrollWheel の `dy -=`、DisplayInfo の Y 反転)は**すべて AppKit/CG が y-up であることへの補正**であり、Web 移植では丸ごと不要。ただし結果(正立出力)は同一であること
- `CGRect(corner: a, b)` = `(min(ax,bx), min(ay,by), |bx-ax|, |by-ay|)`(負方向ドラッグ正規化、Geometry.swift:100-105)
- `corners`: topLeft=(minX,minY)、"top" は **y が小さい側**(画面規約、Geometry.swift:107-112)
- CGRect 意味論を再現: `insetBy`(負 d で拡大)、`union`、`intersection`(非交差で null → clampedCrop nil)、`contains`(半開: max 辺排他)、`integral`(origin floor、max 辺 ceil)、`offsetBy`

### ビュー空間とズーム

- ビュー空間 = macOS ビュー**ポイント**。`ZoomMode.percent(1.0)` = **1 画像ピクセル / 1 ビューポイント**(ZoomMath.swift:3-5)。Retina バッキングスケールはどの式にも登場しない(OS が処理)
- Web 対応: ビューポイント ≙ CSS px。エンジンコードは全部 CSS px で書き、`ctx.setTransform(dpr,0,0,dpr,0,0)` を毎フレーム適用

### DisplayInfo 変換式(CanvasView.swift:138-160)— Web では Y フリップを除去

```
// Swift(y-up ビュー):
modelToView(p) = (rect.minX + (p.x - canvas.origin.x) * scale,
                  rect.minY + (canvas.height - (p.y - canvas.origin.y)) * scale)
viewToModel(p) = (canvas.origin.x + (p.x - rect.minX) / scale,
                  canvas.origin.y + canvas.height - (p.y - rect.minY) / scale)   // scale <= 0 → (0,0)
modelTolerance = 8 / max(scale, 0.0001)

// Web(y-down)等価:
modelToView(p) = (rect.minX + (p.x - canvas.origin.x) * scale,
                  rect.minY + (p.y - canvas.origin.y) * scale)
viewToModel(p) = (canvas.origin.x + (p.x - rect.minX) / scale,
                  canvas.origin.y + (p.y - rect.minY) / scale)
```

- `canvas` = crop を除去した document の `outputRect(for: exportBounds)`(expandToFit なら注釈込みでライブ成長)、`rect` = `ZoomMath.imageRect(...)`

### 描画パイプラインの解像度

- 画面: flatten キャッシュは **scale 1**(1 ビットマップ px / モデル単位)で生成し、ビュー矩形へ高品質補間で拡縮(CanvasView.swift:256,272)。キャッシュキー: `documentVersion` + crop 除去 document の値等値 + base 画像同一性 + exportBounds
- Web 改良(アーキ決定 §5、拘束): Layer A = base + pixelate のラスタキャッシュ / Layer B = ベクタ注釈を `devicePixelRatio × zoom` で毎 rAF 直描き(Mac 版よりシャープ、WYSIWYG は render() 共有で保証)
- バッキングストア: `ResizeObserver` の `devicePixelContentBoxSize`(Safari フォールバック `contentRect × devicePixelRatio`)+ `matchMedia('(resolution: …dppx)')` 再帰リスナーで DPR 変化(モニタ移動・ブラウザズーム)を捕捉
- エクスポート: 常に scale 1(Retina 乗算なし)。出力ピクセル == モデル単位

### CoreImage の Y 変換(参考、Web 不要)

- pixelate の CIImage 変換 `flippedY = canvasSize.height - rect.maxY`(Renderer.swift:202)は CI が y-up のための補正。Canvas 2D では rect をそのまま使う
