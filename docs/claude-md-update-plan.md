# CLAUDE.md 更新計画

## 背景

SwiftAgents/AGENTS.md の内容を CLAUDE.md に追記することを検討。
ただし元のファイルはiOSアプリ向けであり、このプロジェクト（Kakico: macOSアプリ）に
そのまま適用すると誤った前提が含まれる。macOS向けに修正した上で追記する。

**あわせて行う変更:**
- macOS最小ターゲットを 13 → 15 へ引き上げ
- `ObservableObject` + `@Published` → `@Observable` へ移行

---

## AGENTS.md 内容の評価と修正方針

### Role セクション
- **変更:** `Senior iOS Engineer` → `Senior macOS Engineer, specializing in SwiftUI, AppKit`

### Core instructions

| 元の記述 | 対応 |
|---------|------|
| `Target iOS 26.0 or later` | `Target macOS 15.0 or later` に変更 |
| `Swift 6.2 or later` | そのまま（プロジェクトは6.3.2を使用） |
| `@Observable classes` | そのまま（macOS 14+で使用可能。15に引き上げるため問題なし） |
| `Do not introduce third-party frameworks` | そのまま |
| `Avoid UIKit unless requested` | `Avoid AppKit unless complex interaction requires NSView`（CanvasViewはNSViewを使うため） |

### Swift instructions
変更なし。すべてmacOSでも有効。

### SwiftUI instructions

macOS 15へ引き上げることで以下のAPIが全て使用可能になる：

| API | 必要バージョン |
|-----|--------------|
| `@Observable` / `@Bindable` | macOS 14+ |
| `clipShape(.rect(cornerRadius:))` | macOS 14+ |
| `containerRelativeFrame()` | macOS 14+ |
| `ScrollPosition` / `defaultScrollAnchor` | macOS 14+ |
| `Tab` API | macOS 15+ |

→ macOS 15ターゲットに引き上げれば、元の指示をほぼそのまま適用可能。

### SwiftData instructions
**丸ごと削除。** プロジェクトでSwiftDataを使用していない。

### Project structure / PR instructions / Xcode MCP
変更なし。そのまま適用可能。

---

## 変更ステップ

### 1. Package.swift: デプロイターゲット変更

```swift
// Before
.macOS(.v13)

// After
.macOS(.v15)
```

対象: 全ターゲット（AnnotationModel, AnnotationRender, Kakico, テスト群）

### 2. CanvasController.swift: @Observable 移行

```swift
// Before
class CanvasController: ObservableObject {
    @Published var document: Document
    @Published var selectedIDs: Set<Selector>
    // ...
}
```

```swift
// After
@MainActor
@Observable
class CanvasController {
    var document: Document
    var selectedIDs: Set<Selector>
    // ...
}
```

### 3. UI.swift / KakicoApp.swift: プロパティラッパー更新

| Before | After |
|--------|-------|
| `@StateObject` | `@State` |
| `@ObservedObject` | `@Bindable`（書き込みが必要な場合）または直接参照 |
| `@EnvironmentObject` | `@Environment` |

### 4. CLAUDE.md: macOS向けに修正したAGENTS.md内容を追記

修正後の構成:
```
## Build
（既存）

## Agent Guide for Swift and SwiftUI (macOS)
### Role
### Core instructions
### Swift instructions
### SwiftUI instructions
### Project structure
### PR instructions
### Xcode MCP（オプション）
```

---

## 検証

```bash
swift build          # コンパイルエラーなし
swift test           # 30テスト全パス
bash scripts/build-app.sh  # Kakico.app生成・検証
```

実機確認: アプリを起動し、注釈ツール（矢印・テキスト・PixelateなどAll）が正常動作すること。
