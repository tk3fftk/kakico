# トラックパッドのピンチズーム対応

## Context

前回のズーム機能(メニュー + ⌘+/⌘-/⌘0 + スクロールパン、コミット済み `2bed9cc`, `907e5dc`)で意図的に後回しにしたピンチ(magnify)ジェスチャを追加する。既存インフラ(`ZoomMath` の純粋関数群、`CanvasNSView.panOffset`、`reconcileZoom()`、`CanvasController.zoomMode`)はすべて流用でき、新規要素は次の2点のみ:

1. **カーソル位置アンカー**: プレビュー.app 同様、ピンチ中はマウスカーソル直下のモデル点を固定してズームする(既存の `panPreservingCenter` はビュー中心固定なのでピンチには不適)。
2. **連続倍率**: ピンチはプリセット外の任意倍率(例 137%)になる。ラベルは既に実効倍率をライブ表示、⌘+/⌘- のプリセットステップも epsilon 比較で任意値から正しく動くため、対応済み。

## 変更ファイル

### 1. `Sources/Kakico/ZoomMath.swift` — アンカー保持パン関数を追加

```swift
/// Keeps the model point under `viewPoint` fixed across a scale change
/// (pinch zoom anchored at the cursor).
static func panPreservingPoint(_ viewPoint: CGPoint, oldPan: CGVector,
                               oldScale: CGFloat, newScale: CGFloat,
                               canvas: CGSize, viewport: CGSize) -> CGVector
```

導出(x軸、y軸同形。すべてビュー座標なのでモデルのY反転は無関係):
- `rectX = (V − C)/2 + pan.dx`(C = canvas.width × scale)
- アンカーのコンテンツ内オフセット `u = viewPoint.x − rectX`
- 新スケールで同じモデル点を同じビュー位置に: `rectX' = viewPoint.x − u × (newScale/oldScale)`
- `pan'.dx = rectX' − (V − C')/2`

検算済み: `viewPoint = ビュー中心` のとき `pan' = pan × (newScale/oldScale)` となり既存 `panPreservingCenter` と一致する(この性質をテストにする)。

### 2. `Sources/Kakico/CanvasView.swift` — `magnify(with:)` override

`scrollWheel` の直後(`// MARK: Pan` セクション)に追加:

```swift
override func magnify(with event: NSEvent) {
    guard let controller, controller.hasDocument,
          case .none = drag else {  // never zoom mid-annotation-drag
        super.magnify(with: event)
        return
    }
    let info = displayInfo
    let oldScale = info.scale
    let minScale = min(ZoomMath.presets.first!, ZoomMath.fittedScale(canvas: info.canvas.size, viewport: bounds.size))
    let newScale = min(max(oldScale * (1 + event.magnification), minScale), ZoomMath.presets.last!)
    guard newScale != oldScale, oldScale > 0 else { return }
    if textEditor != nil { commitTextEditing() }  // font has old scale baked in
    let anchor = convert(event.locationInWindow, from: nil)
    let pan = ZoomMath.panPreservingPoint(anchor, oldPan: panOffset,
                                          oldScale: oldScale, newScale: newScale,
                                          canvas: info.canvas.size, viewport: bounds.size)
    let content = CGSize(width: info.canvas.width * newScale, height: info.canvas.height * newScale)
    panOffset = ZoomMath.clampedPan(pan, content: content, viewport: bounds.size)
    lastAppliedScale = newScale  // pan already adjusted; keep reconcileZoom from re-anchoring at center
    controller.zoomMode = .percent(newScale)
    needsDisplay = true
}
```

ポイント:
- `event.magnification` は増分(1ピンチイベントあたり ±数%)。`oldScale × (1 + magnification)` で累積。
- **クランプ範囲**: 上限 400%(プリセット最大)。下限は `min(25%, fittedScale)` — 巨大画像で fit が 25% 未満でも、ピンチアウトで fit 相当まで戻れるようにする。
- `lastAppliedScale = newScale` を先に書くことで、直後の `reconcileZoom()`(zoomMode 変更 → observation → draw)が `panPreservingCenter` で二重にパン調整するのを防ぐ。クランプは reconcile 側でも再度かかるので安全。
- ドラッグ中は無視(`scrollWheel` と同じガード)。テキスト編集中はコミット(`reconcileZoom` のスケール変化時と同じ扱い。ここは draw 外なので直接呼んで良い)。
- スマートマグニファイ(2本指ダブルタップ)は今回対象外。

### 3. `Tests/KakicoTests/ZoomMathTests.swift` — `panPreservingPoint` のテスト追加

- アンカー不変性: 任意の viewPoint 直下のモデル点がスケール変更後も同じビュー位置に来る(既存 `testPanPreservingCenterKeepsCenterModelPointFixed` と同じ構成で、`imageRect` を合成して検証)
- 中心一致: `viewPoint = viewport 中心` のとき `panPreservingCenter` と同値
- スケール不変(oldScale == newScale)で pan がそのまま返る

## 検証

1. `swift test`(新テスト含め全件グリーン)
2. `bash scripts/build-app.sh`
3. 手動確認:
   - ピンチイン/アウトでカーソル直下の点が動かずにズームする(プレビュー.app と比較)
   - ラベルの % がピンチ中ライブ更新、ピンチ後に ⌘+/⌘- でプリセットへスナップ
   - 400% で頭打ち、巨大画像でも fit 相当までピンチアウトできる
   - ピンチ後のスクロールパン・クランプが正常
   - テキスト編集中のピンチでエディタがコミットされる
   - 注釈ドラッグ中のピンチは無視される

## 完了後

このプランファイルをリポジトリの `docs/` 以下へコピーして格納する(例: `docs/pinch-zoom-plan.md`。既存の `docs/claude-md-update-plan.md` などと同様の置き方)。
