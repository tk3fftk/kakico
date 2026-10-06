# Kakico → TypeScript PWA 移行計画（インデックス）

## 目的

macOS アプリ Kakico（Swift / SwiftUI、`Sources/**`）を TypeScript 製 PWA「kakico-web」として書き直す。既存の UI/UX（Miro 風クローム、Skitch 風カラープリセット、ツール群、ズーム/パン、クロップ、エクスポート）を機能同等（parity）で継承する。実装は AI コーディングモデルが本計画のドキュメントを順番に実行して行う。

対象機能はモデル実装済みの 6 種（`arrow | line | rectangle | ellipse | text | pixelate`）+ `crop`。`blur` / `stamp` は post-parity（コーデックに discriminant のみ予約）。

### 移行の動機

動作中のネイティブアプリを新機能ゼロのパリティで書き直す投資であるため、目的を明記する。

- **配布**: 署名・公証・手動アップデート配布（現状は ad-hoc 署名の `build/Kakico.app`）を、URL 配布 + PWA 自動更新に置き換える。
- **クロスプラットフォーム**: macOS 15 限定の実装を Windows / Linux / ChromeOS を含む任意のモダンブラウザへ広げる。
- **将来機能の土台**: `blur` / `stamp` / `share_target` などの post-parity 拡張は Web 側で実装する前提。パリティ達成が拡張の前提条件。

### スコープ規則

- 本ディレクトリ `docs/migrate-to-typescript/` は計画ドキュメントのみ。実装コードは置かない。
- 新アプリはリポジトリ直下の `kakico-web/` に作成する。
- 既存 Swift アプリ（`Sources/`、`Tests/`、`scripts/`）は一切変更しない。移植の参照元および golden fixture（`.kakico`、レンダリング結果）の生成元として使う。
- サードパーティ UI の模倣・コピーはしない。アイコンは SF Symbols の代わりにオリジナル SVG を `src/ui/icons.tsx` に作成する。
- ランタイム依存は `preact` のみ。それ以外はすべて dev dependency またはブラウザ標準 API。
- アーキテクチャ上の決定（スタック、ディレクトリ構成、状態管理、レンダリング方式、命名規約）は `01-architecture.md` が唯一の正。各ステップドキュメントはこれに従属する。

## ドキュメント構成

| # | ドキュメント | 種別 | 内容（1 行） | 規模 |
|---|---|---|---|---|
| 00 | `00-feature-inventory.md` | 参照資料 | Swift 版の全機能・全定数・全ショートカットの棚卸し。実装ステップではなく、各ステップから随時参照する | — |
| 01 | `01-architecture.md` | 決定事項 | スタック（Vite + Preact + strict TS + vitest）、ディレクトリツリー、Swift→TS モジュール対応表、レンダリング 2 層構成、命名規約。全ステップの拘束仕様 | — |
| 02 | `02-project-setup.md` | 実装 | scaffold: Vite + Preact + strict tsconfig + ESLint 境界ルール + `theme.css` トークン + ドットグリッド背景 + EmptyState + CI | S |
| 03 | `03-model.md` | 実装 | `src/model/` 全体（geometry / elements / annotation / handle / document / pointerTarget / codec）+ Swift モデルテスト移植 + Mac 版出力の golden `.kakico` round-trip | M |
| 04 | `04-renderer.md` | 実装 | `src/render/`（renderer / text wrap / pixelate / flatten / encode）+ ブラウザモード pixel golden テスト + 開発用確認ページ | M |
| 05 | `05-state-controller.md` | 実装 | `src/state/`（store / history / tool）+ 画像読み込み（open / paste / drop）+ DPR 対応 CanvasHost の fit 表示 + サイズバッジ + PNG ダウンロード。この時点でアプリが最小限使える | M |
| 06 | `06-canvas-interactions.md` | 実装 | `src/engine/`（displayMapping / dragMachine / 選択オーバーレイ / テキスト編集 / crop + marching ants / zoomMath + ピンチ・パン） | L |
| 07 | `07-ui-chrome.md` | 実装 | `src/ui/` クローム全部（ToolPalette / ColorPresetPanel / StrokeWidthPopover / ActionBar / ZoomControl / Toast / ConfirmDialog）+ ショートカット表 + ダークモード | M |
| 08 | `08-io-export.md` | 実装 | クリップボードコピー、PNG/JPEG エクスポート、`.kakico` 保存/読み込み + handle 再利用、ドラッグアウト、beforeunload ガード、IndexedDB 自動保存 | M |
| 09 | `09-pwa.md` | 実装 | manifest / Service Worker precache / 更新トースト / `file_handlers` + launchQueue / オフライン検証 / a11y パス / Playwright スモーク | M |
| 10 | `10-parity-checklist.md` | 最終受け入れ | Mac 版との機能同等チェックリスト。全項目 pass で移行完了 | — |

依存関係は番号順に一直線（02 → 03 → … → 09 → 10）。並列実行は想定しない。

## 進め方

AI 実装者は以下の手順で進める。

1. `01-architecture.md` を全文読み、拘束事項（ディレクトリ構成、lint 境界、命名規約 §9）を把握する。
2. `02-project-setup.md` から番号順に 1 ドキュメント = 1 作業単位（PR 相当）として実装する。
3. 各ステップは、そのドキュメントの「受け入れ基準」が全項目 green になってから次に進む。飛ばし・先回りはしない。
4. 各ステップ共通の CI ゲート:

   ```
   cd kakico-web
   npx tsc --noEmit && npx eslint . && npx vitest run && npx vite build
   ```

5. 不明点は推測せず、対応する Swift ソースを読む。各ドキュメントの「定数・仕様表」に `file:line` 参照があるので、値が疑わしければ原典と突き合わせる。移植した関数は Swift の関数名を維持する（`01-architecture.md` §9）。
6. Swift 版のテスト（`Tests/**`）が挙動仕様。移植テストを先に書き、実装をそれに合わせる。
7. コミット/PR には移植元の Swift 関数名を記載する（例: `port CanvasNSView.drawCropOverlay`）。

## 完了の定義

以下すべてを満たしたとき、移行完了とする。

- [ ] ステップ 02–09 の全「受け入れ基準」が pass 済み。
- [ ] `kakico-web/` で CI ゲート（`tsc --noEmit` / `eslint` / `vitest run` / `vite build`）がすべて green。
- [ ] `10-parity-checklist.md` の全項目が Chrome で pass（Safari / Firefox はフォールバック動作を含め pass）。
- [ ] Mac 版 Kakico がエクスポートした `.kakico` を kakico-web が開けて、kakico-web が保存した `.kakico` を Mac 版が開ける（golden fixture テスト + 手動相互確認）。
- [ ] PWA としてインストール後、ネットワーク遮断状態で起動・全機能（I/O 系除く）が動作する。
- [ ] Lighthouse の PWA 監査が pass。
- [ ] 既存 Swift アプリに差分がない（`git diff --stat Sources/ Tests/ scripts/` が空）。
