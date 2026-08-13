# Kakico アプリアイコンの構成とビルドの仕組み

このドキュメントでは、Kakico アプリケーションにおけるアイコン（ロゴ）の構成ファイル、開発・更新ワークフロー、およびビルド処理の仕組みについて解説します。

---

## 1. 概要 (Overview)

macOS アプリケーション (`Kakico.app`) では、Finder や Dock、タスク切替画面で表示されるアイコンとして `.icns` 形式のマルチ解像度アイコンが使用されます。
`Resources/Info.plist` にて以下のように指定されています：

```xml
<key>CFBundleIconFile</key>
<string>AppIcon</string>
<key>CFBundleIconName</key>
<string>AppIcon</string>
```

これにより、アプリバンドル内の `Contents/Resources/AppIcon.icns` がアプリアイコンとして読み込まれます。

---

## 2. アセット構成と役割 (Asset Structure & Roles)

リポジトリ内にはアプリアイコンに関連する以下のファイル・ディレクトリが存在します。

| パス | 種類 | 役割・説明 |
| :--- | :--- | :--- |
| `KakicoAppIcon.icon/` | ソースフォルダ | **Icon Composer 用編集データ**。<br>`icon.json`（グラデーションやグラスエフェクト等の設定）と `Assets/image.png` を含む再編集用データ。 |
| `Resources/AppIcon.png` | マスター画像 | **単体マスター PNG 画像** (1024x1024)。アイコン生成の原稿となる画像。 |
| `Resources/AppIcon.icns` | アセット | **事前生成済み macOS アイコン**。16x16 〜 1024x1024 の全スケールを含むコンパイル済み `.icns` ファイル。Git 管理対象。 |
| `scripts/generate-icon.sh` | スクリプト | **オンデマンド生成スクリプト**。`Resources/AppIcon.png` から `Resources/AppIcon.icns` を手動生成・更新する。 |
| `scripts/build-app.sh` | スクリプト | **アプリパッケージングスクリプト**。`Resources/AppIcon.icns` を `Kakico.app` にコピーする。 |

---

## 3. ビルドおよび組み込みの仕組み (Build & Bundling Mechanism)

### 3.1 アプリビルド時の処理 (`scripts/build-app.sh`)
`scripts/build-app.sh` を実行して `Kakico.app` をパッケージングする際、アイコンの組み込みは事前生成された `Resources/AppIcon.icns` のコピーのみで行われます。

```bash
# scripts/build-app.sh
ICON_SRC="$ROOT/Resources/AppIcon.icns"
if [[ -f "$ICON_SRC" ]]; then
    echo "==> copying AppIcon.icns"
    cp "$ICON_SRC" "$APP/Contents/Resources/AppIcon.icns"
fi
```

**事前生成方式を採用している理由:**
- **ビルドの高速化**: ビルドのたびに 10 回の `sips` 画像縮小処理や `iconutil` 実行を行わないため、ビルドが短時間で完了します。
- **決定論的ビルド**: 事前コンパイルされた `.icns` を直接使用することで、環境による画像生成結果のブレを防ぎます。

### 3.2 なぜ CLI ビルドで `KakicoAppIcon.icon` (`icon.json`) を直接処理しないのか？
`.icon` パッケージ（Icon Composer 形式）は Xcode のビルドツールチェーン (`actool`) でコンパイルされることを前提としています。
コマンドラインの CLI ツール (`sips` / `iconutil`) は `icon.json` の設定（背景グラデーション `automatic-gradient` やグラスエフェクト `glass: true` 等）を直接パース・合成レンダリングする機能を持っていません。

そのため、再編集用のマスターデータとしては `KakicoAppIcon.icon` を維持しつつ、ビルドおよび CLI での運用は事前エクスポートした `AppIcon.icns` / `AppIcon.png` を使用する設計としています。

---

## 4. アイコンの更新・開発ワークフロー (Update & Development Workflow)

アプリアイコンのデザインを変更・更新する手順は以下の通りです。

### パターン A: Icon Composer アプリで編集する場合
1. Icon Composer (macOS Sequoia / Xcode 16) で `KakicoAppIcon.icon` またはデザインファイルを開き編集します。
2. デザイン完了後、1024x1024 の PNG 画像（または `.icns`）として書き出します。
3. `Resources/AppIcon.png` に上書き配置します。
4. 以下の生成スクリプトを実行して `Resources/AppIcon.icns` を更新します。

```bash
./scripts/generate-icon.sh
```

### パターン B: `Resources/AppIcon.png` を直接差し替える場合
1. 新しい 1024x1024 PNG 画像を `Resources/AppIcon.png` に配置します。
2. 以下のスクリプトを実行して `Resources/AppIcon.icns` を再生成します。

```bash
./scripts/generate-icon.sh
```

生成後、Git に `Resources/AppIcon.png` と `Resources/AppIcon.icns` をコミットします。
