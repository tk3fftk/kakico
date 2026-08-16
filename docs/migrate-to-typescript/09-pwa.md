# 09. PWA 化と仕上げ — manifest / Service Worker / file_handlers / オフライン / Playwright smoke

## 目的

kakico-web を「インストール可能・完全オフライン動作・OS ファイル関連付け対応」の PWA として完成させる。02 で `injectRegister: false` のまま保留していた Service Worker を有効化し、更新トースト・install prompt UX・`file_handlers`/`launchQueue`・reduced-motion/ARIA パス・Playwright smoke スイートまでを一括で仕上げる。本ステップ完了で機能パリティのマイルストーン(02–09)が完結する。

## 前提

以下の全ドキュメントの完了が必須。

- `02-project-setup.md` — `vite.config.ts` に `VitePWA`(manifest 生成のみ、`injectRegister: false`)、アイコン `icon-192.png`/`icon-512.png`、`theme.css` トークン。
- `03-model.md` / `04-renderer.md` — 直接依存なし(CI ゲートの一部として全テスト green が前提)。
- `05-state-controller.md` — `canvasStore` と `flashToast`、画像ロード経路(`loadImageFile` 相当)。
- `07-ui-chrome.md` — `Toast.tsx`、`ActionBar.tsx`、`EmptyState.tsx`、`icons.tsx`。
- `08-io-export.md` — `platform/files.ts` の `.kakico` オープン経路(`openKakicoFile` 相当)と `FileSystemFileHandle` 再利用、`beforeunload` ガード、IndexedDB オートセーブ。

## 作成・変更ファイル

すべて `kakico-web/` 配下(絶対パス: `/Users/hiroki.takatsuka/github.com/kakico/kakico-web/`)。

| パス | 種別 | 内容 |
|---|---|---|
| `vite.config.ts` | 変更 | manifest 完成(`launch_handler`/`file_handlers` 追加)、SW 登録有効化(`registerType: 'prompt'`)、workbox 設定確定 |
| `index.html` | 変更 | CSP meta タグ追加(手順 11) |
| `playwright.config.ts` | 新規 | e2e 設定(preview サーバー + chromium) |
| `package.json` | 変更 | `@playwright/test` devDep 追加、`preview`/`e2e` scripts |
| `src/platform/swUpdate.ts` | 新規 | SW 登録 + 更新検知(`onNeedRefresh`)+ `reloadToUpdate()` + 定期 update ポーリング + 登録失敗の可視化 |
| `src/platform/installPrompt.ts` | 新規 | `beforeinstallprompt` 捕捉と `prompt()` 実行 |
| `src/platform/files.ts` | 変更 | `routeLaunchFile()` と `consumeLaunchQueue()` 追加 |
| `src/state/canvasStore.ts` | 変更 | `updateAvailable` / `canInstall` フィールドとアクション追加 |
| `src/main.tsx` | 変更 | SW 登録・launchQueue・installPrompt の初期化配線 |
| `src/ui/UpdateToast.tsx` | 新規 | 「Reload to update」永続トースト(Reload ボタン付き) |
| `src/ui/App.tsx` | 変更 | `UpdateToast` のマウント |
| `src/ui/ActionBar.tsx` | 変更 | Install タイル(`canInstall && document` 時のみ表示) |
| `src/ui/EmptyState.tsx` | 変更 | 「Install App」三次ボタン(`canInstall` 時のみ表示) |
| `src/ui/theme.css` | 変更 | `prefers-reduced-motion` ブロック追加 |
| `src/ui/Toast.tsx` ほか chrome 各所 | 変更 | ARIA パス(後述の手順 7 の表どおり) |
| `src/engine/cropOverlay.ts` | 変更 | reduced-motion 時にマーチングアンツ位相を固定 |
| `tests/engine/cropOverlay.test.ts` | 新規 | reduced-motion 時のマーチングアンツ静止テスト(06 のテストは zoomMath / displayMapping / dragMachine のみで、本ファイルは未存在のため新規作成)。最小ハーネスで `prefersReducedMotion: () => boolean` を AntsScheduler に注入し、tick を複数回進めて `lineDashOffset` の変化を検証する |
| `tests/platform/launchRouting.test.ts` | 新規 | `routeLaunchFile` 単体テスト |
| `tests/state/pwaFlags.test.ts` | 新規 | store の PWA フラグテスト |
| `tests/ui/UpdateToast.test.tsx` | 新規 | 更新トーストのコンポーネントテスト |
| `tests/e2e/smoke.spec.ts` | 新規 | Playwright smoke スイート |

## 実装手順

### 1. manifest の完成(`vite.config.ts`)

02 の `VitePWA` 設定を以下に置き換える。差分: `injectRegister: false` の削除(デフォルト `'auto'` に戻す)、`launch_handler`・`file_handlers` の追加、workbox 設定の確定。

```ts
VitePWA({
  // 'prompt': 新 SW は Reload まで waiting に留まり、旧 precache を保持する。
  // 'autoUpdate'(skipWaiting + clientsClaim + cleanupOutdatedCaches)は新 SW activate 時に
  // 旧 precache を即削除するため、表示中の旧ページが動的 import(遅延チャンク)を要求した瞬間に
  // 旧ハッシュが消えており navigateFallback が HTML を返してチャンクロードが壊れる。
  // 「トースト + 手動 Reload」の UX には prompt が正。
  registerType: 'prompt',
  manifest: {
    name: 'Kakico',
    short_name: 'Kakico',
    description: 'Annotate screenshots — arrows, shapes, text, pixelate, crop.',
    display: 'standalone',
    start_url: '/',
    scope: '/',
    // Theme.swift miroBoard #F5F5F7(§定数・仕様表)
    theme_color: '#F5F5F7',
    background_color: '#F5F5F7',
    icons: [
      { src: '/icons/icon-192.png', sizes: '192x192', type: 'image/png', purpose: 'any maskable' },
      { src: '/icons/icon-512.png', sizes: '512x512', type: 'image/png', purpose: 'any maskable' },
    ],
    // シングルウィンドウモデル(アーキテクチャ仕様 §8)
    launch_handler: { client_mode: 'focus-existing' },
    file_handlers: [
      {
        action: '/',
        accept: { 'application/x-kakico': ['.kakico'] },
      },
      {
        action: '/',
        accept: {
          'image/png': ['.png'],
          'image/jpeg': ['.jpg', '.jpeg'],
          'image/webp': ['.webp'],
        },
      },
    ],
    // share_target は v1 スコープ外(アーキテクチャ仕様 §8)
  },
  workbox: {
    // アプリシェル全体(バンドルフォント含む)をプリキャッシュ — オフラインファースト
    globPatterns: ['**/*.{js,css,html,svg,png,woff2}'],
    navigateFallback: '/index.html',
    cleanupOutdatedCaches: true,
    maximumFileSizeToCacheInBytes: 5 * 1024 * 1024,
    // runtimeCaching は定義しない。ユーザーデータ(画像・.kakico)は
    // ファイル / IndexedDB に置き、SW キャッシュには決して入れない(アーキテクチャ仕様 §8)。
  },
}),
```

`index.html` の `theme-color` meta(light `#F5F5F7` / dark `#202024`)は 02 のまま変更しない。manifest の `theme_color` は単一値しか持てないため light 値で固定し、dark は meta 側で対応する。

### 2. SW ライフサイクルと更新フロー(`src/platform/swUpdate.ts`)

方針(binding): `registerType: 'prompt'` により新 SW は install 後 **waiting に留まり**、旧 precache は削除されない。表示中の旧ページは動的 import(遅延チャンク)を含め旧アセット一式で動き続ける — 混在なし・チャンク破壊なし。永続トースト「Reload to update」を表示し、ユーザー操作の Reload で `updateSW(true)`(skipWaiting → activate → reload)により新アセットへ一括切替する。`cleanupOutdatedCaches` による旧 precache 削除は新 SW activate 時 = Reload 時に起きる。

ライフサイクル全文:

1. 初回訪問: SW install → precache(アプリシェル全ファイル)→ activate。以後オフライン動作可。`onOfflineReady` で通常トースト表示。
2. デプロイ後の再訪問: ブラウザが新 SW を検出 → install(新 precache manifest を差分ダウンロード)→ **waiting のまま停止** → `onNeedRefresh` コールバック → store の `updateAvailable = true` → `UpdateToast` 表示。表示中のページは旧 SW + 旧 precache のまま動き続ける。
3. タブを開いたまま長時間経過: 60 分間隔の `registration.update()` ポーリングで新 SW を検出(以降は 2 と同じ)。
4. Reload ボタン → `reloadToUpdate()`(内部で `updateSW(true)`: waiting SW に skipWaiting をポストし、activate 後にページをリロード)。`dirty` 時は 08 の `beforeunload` ガードが先に確認を出す。IndexedDB オートセーブ(08)がリロード後の復元を担う。
5. SW 登録そのものが失敗した場合(HTTPS 要件・ホスティング設定ミス等)は `onRegisterError` → `flashToast('Offline mode unavailable')` + `logError('sw-register-failed', e)`(08 の errorLog)。オフライン機能の沈黙死を運用可視化する。

```ts
// src/platform/swUpdate.ts
export interface SWUpdateCallbacks {
  onOfflineReady(): void;      // 初回 precache 完了
  onUpdateAvailable(): void;   // 新 SW が waiting に入った(Reload で新アセット)
  onRegisterError(e: unknown): void;
}

export const SW_UPDATE_POLL_MS = 60 * 60 * 1000; // 60 min

let updateFn: (() => void) | null = null;

/** UpdateToast の Reload ボタンが呼ぶ。waiting SW を activate してリロード。
 *  registerSW 前に呼ばれた場合のフォールバックは location.reload()。 */
export function reloadToUpdate(): void { (updateFn ?? (() => location.reload()))(); }

export function registerServiceWorker(cb: SWUpdateCallbacks): void {
  if (!('serviceWorker' in navigator)) return;
  // virtual:pwa-register は vite-plugin-pwa が生成(dev では no-op)
  import('virtual:pwa-register').then(({ registerSW }) => {
    const updateSW = registerSW({
      immediate: true,
      onNeedRefresh: cb.onUpdateAvailable,   // 'prompt' モード: 新 SW が waiting に入った
      onOfflineReady: cb.onOfflineReady,
      onRegisteredSW(_url, registration) {
        if (registration) setInterval(() => void registration.update(), SW_UPDATE_POLL_MS);
      },
      onRegisterError: cb.onRegisterError,
    });
    updateFn = () => void updateSW(true);
  });
}
```

`virtual:pwa-register` の型は `vite-env.d.ts`(または `tsconfig` の `types`)に `/// <reference types="vite-plugin-pwa/client" />` を追加して解決する。

### 3. store 拡張(`src/state/canvasStore.ts`)

`CanvasState` に 2 フィールド追加(いずれも undo 対象外・永続化対象外)。

```ts
readonly updateAvailable: boolean;  // 初期値 false。true になったら false に戻らない(リロードで消える)
readonly canInstall: boolean;       // beforeinstallprompt 捕捉中のみ true

// actions
setUpdateAvailable(): void;             // updateAvailable = true
setCanInstall(value: boolean): void;
```

### 4. install prompt UX(`src/platform/installPrompt.ts` + UI)

```ts
// src/platform/installPrompt.ts
export interface BeforeInstallPromptEvent extends Event {
  prompt(): Promise<void>;
  readonly userChoice: Promise<{ outcome: 'accepted' | 'dismissed' }>;
}

// beforeinstallprompt を捕捉して preventDefault し、モジュール内変数に保持。
// appinstalled で破棄。捕捉状態の変化を onChange で通知する。
export function initInstallPrompt(onChange: (canInstall: boolean) => void): void;

// 保持中のイベントで prompt() を実行。accepted/dismissed を返し、
// どちらでも保持イベントを破棄して onChange(false)。未保持なら 'unavailable'。
export async function promptInstall(): Promise<'accepted' | 'dismissed' | 'unavailable'>;
```

UI 配置(表示条件を機械的に固定):

- `EmptyState.tsx`: 既存 2 ボタンの下に三次テキストボタン `Install App`。表示条件 `canInstall === true`。クリックで `promptInstall()`。
- `ActionBar.tsx`: 右端に Install タイル(`icons.tsx` にダウンロード系アイコンを追加、`aria-label="Install Kakico"`、tooltip 同文)。表示条件 `canInstall === true && document !== null`。
- `promptInstall()` が `'accepted'` を返したら `flashToast('Installed')`(1.8 s 通常トースト)。
- `beforeinstallprompt` は Chromium 系のみ発火。Safari/Firefox では `canInstall` が false のまま → ボタンは一切出ない(それが正しい挙動。手順 8 参照)。

### 5. `file_handlers` + `launchQueue`(`src/platform/files.ts`, `src/main.tsx`)

```ts
// src/platform/files.ts に追加
export type LaunchFileKind = 'kakico' | 'image';

// 拡張子 .kakico(大文字小文字無視)→ 'kakico'、それ以外 → 'image'
export function routeLaunchFile(fileName: string): LaunchFileKind {
  return /\.kakico$/i.test(fileName) ? 'kakico' : 'image';
}

export function consumeLaunchQueue(handlers: {
  openKakico(file: File, handle?: FileSystemFileHandle): Promise<void>;
  openImage(file: File, handle?: FileSystemFileHandle): Promise<void>;
}): void {
  const lq = (window as { launchQueue?: LaunchQueue }).launchQueue;
  if (!lq) return; // Safari / Firefox: file_handlers 非対応 — 静かに no-op
  lq.setConsumer(async (params) => {
    const handle = params.files[0];
    if (!handle) return;
    const file = await handle.getFile();
    if (routeLaunchFile(file.name) === 'kakico') await handlers.openKakico(file, handle);
    else await handlers.openImage(file, handle);
  });
}

// 最小限の型(lib.dom.d.ts 未収録のため自前宣言)
interface LaunchQueue {
  setConsumer(consumer: (params: { files: FileSystemFileHandle[] }) => void): void;
}
```

配線ルール:

- `openKakico` は 08 の `.kakico` オープン経路を呼び、渡された `handle` を ⌘S の silent re-save 用に保持する(08 の handle 再利用と同一機構)。
- `openImage` は 05 の画像ロード経路を呼び、`sourceName = file.name` を設定(エクスポートファイル名の継承)。
- ドキュメントが既に開いている場合、置換確認(08 の `ConfirmDialog`、paste-replace と同文)を経てからロードする。
- `launch_handler: focus-existing` により、起動済みウィンドウがあれば新規ウィンドウは開かず既存クライアントに `launchQueue` イベントが届く。

### 6. `src/main.tsx` の配線

bootstrap 末尾(store 生成・Preact マウント後)に追加:

```ts
registerServiceWorker({
  onOfflineReady: () => store.flashToast('Ready to work offline'),
  onUpdateAvailable: () => store.setUpdateAvailable(),
  onRegisterError: (e) => { store.flashToast('Offline mode unavailable'); logError('sw-register-failed', e); },
});
initInstallPrompt((v) => store.setCanInstall(v));
consumeLaunchQueue({ openKakico, openImage }); // 08/05 の経路を束ねたもの
```

`UpdateToast.tsx` の仕様:

- 表示条件 `updateAvailable === true`。既存 `Toast.tsx` と同じ bottom-center capsule チェーンだが、**自動消滅なし・`pointer-events: auto`**(通常トーストの 1.8 s / `pointer-events: none` 仕様からの意図的逸脱)。
- 文言: `Reload to update` + ボタン `Reload`(クリックで `reloadToUpdate()` — §2。素の `location.reload()` ではない: waiting SW を activate しないと新アセットに切り替わらない)。
- `role="status"` `aria-live="polite"`。
- 通常トーストと同時表示になる場合は UpdateToast を上に積む(縦スタック、gap 8px)。

### 7. reduced-motion / ARIA パス

`theme.css` に追加:

```css
@media (prefers-reduced-motion: reduce) {
  /* トーストは opacity のみ(UI.swift:78-83 の Reduce Motion 分岐と同義) */
  .kk-toast { transition-property: opacity; transform: none; }
  * { animation-duration: 0.01ms !important; transition-duration: 0.01ms !important; }
}
```

`src/engine/cropOverlay.ts`: コンストラクタ(または factory)に `prefersReducedMotion: () => boolean` を注入(デフォルト実装 `() => matchMedia('(prefers-reduced-motion: reduce)').matches`)。true の間は `lineDashOffset` を 0 に固定(破線は静止表示、~12 Hz の位相更新を停止)。

ARIA 割り当て表(07 のコンポーネントへ追記):

| コンポーネント | 属性 |
|---|---|
| `ToolPalette` | コンテナ `role="toolbar"` `aria-label="Tools"`; 各タイル `<button>` に `aria-label`(ツール名)+ `aria-pressed`(アクティブ時 true) |
| `ActionBar` / `ZoomControl` / `CropActionBar` | 各アイコンボタンに `aria-label`(tooltip と同文) |
| `ColorPresetPanel` | 各スウォッチに `aria-label`(色名: Red/Orange/…)+ `aria-pressed` |
| `StrokeWidthPopover` | slider に `aria-label="Stroke width"` `aria-valuemin=1` `aria-valuemax=40` |
| `Toast` / `UpdateToast` | `role="status"` `aria-live="polite"` |
| `ConfirmDialog` | `<dialog>` ネイティブセマンティクスのまま(追加不要)、見出しに `aria-labelledby` 接続 |
| canvas 要素 | `role="img"` `aria-label="Annotation canvas"` |
| `ImageSizeBadge` | `aria-hidden="true"`(装飾情報) |

### 8. クロスブラウザ差異とフォールバック(確認マトリクス)

本ステップで新設した機能のデグレード仕様。08 までのフォールバック(pickers/clipboard/drag-out)も再確認対象。

| 機能 | Chrome/Edge | Safari (macOS 26 系) | Firefox |
|---|---|---|---|
| SW precache / オフライン | ○ | ○ | ○ |
| インストール | `beforeinstallprompt` + omnibox アイコン | イベントなし → Install ボタン非表示。ユーザーは 共有 > 「Dock に追加」で手動インストール(オフライン動作は同等) | デスクトップ PWA インストール非対応 → ボタン非表示。ブラウザタブ内で全機能動作 |
| `file_handlers` / `launchQueue` | ○(インストール済み + 初回にファイルオープン許可ダイアログ) | 非対応 → `consumeLaunchQueue` no-op。⌘O / ドロップで開く | 同左 |
| `launch_handler: focus-existing` | ○ | 無視される(実害なし) | 無視される |
| File System Access(08) | ○ handle 再利用で silent ⌘S | 非対応 → `<a download>` フォールバック(毎回ダウンロード) | 同左 |
| `ClipboardItem` copy(08) | ○ | ○(Promise 値 + ユーザージェスチャ必須 — 実装済み前提) | 近年対応。不可時は beep 相当のエラートースト。paste イベント経路は全ブラウザ共通 |
| drag-out `DownloadURL`(08) | ○ | 非対応 → well 非表示 | 非対応 → well 非表示 |

手動チェック手順は §受け入れ基準の手動項目として列挙。

### 9. Playwright smoke スイート

`package.json`:

```json
{
  "scripts": { "preview": "vite preview", "e2e": "playwright test" },
  "devDependencies": { "@playwright/test": "^1.x" }
}
```

`playwright.config.ts`(全文):

```ts
import { defineConfig } from '@playwright/test';

export default defineConfig({
  testDir: 'tests/e2e',
  timeout: 30_000,
  use: { baseURL: 'http://localhost:4173' },
  webServer: {
    // SW は本番ビルド + preview でのみ動く(dev では devOptions 無効のため)。
    // build は webServer で行わない — ビルド失敗が e2e の flake(120s タイムアウト)として
    // 現れるのを防ぐため、ビルドは前段の明示ステップで行い preview は dist を指すだけにする。
    command: 'npm run preview -- --port 4173 --strictPort',
    url: 'http://localhost:4173',
    reuseExistingServer: false,
    timeout: 30_000,
  },
  projects: [
    {
      name: 'chromium',
      use: {
        browserName: 'chromium',
        permissions: ['clipboard-read', 'clipboard-write'],
      },
    },
  ],
});
```

`package.json` の `e2e` script は build を前置する: `"e2e": "npm run build && playwright test"`(CI では build 済み dist を再利用するため `npx playwright test` を直接呼ぶ)。

vitest が `tests/e2e/*.spec.ts` を拾わないこと(02 の include は `*.test.ts(x)` のみだが、明示的に `exclude: ['tests/e2e/**']` を `vite.config.ts` の `test` に追加)。

`tests/e2e/smoke.spec.ts` のテストケースは §テスト参照。CI(既存 `kakico-web-ci.yml`)への追記:

- Playwright ブラウザは 04 で導入済みの `actions/cache`(`~/.cache/ms-playwright`、key = lockfile ハッシュ)をそのまま使う。`npx playwright install --with-deps chromium` はキャッシュヒット時にブラウザ再ダウンロード(~150 MB)をスキップする。**毎 run のフル DL を CI に入れないこと。**
- 既存の `npm run build` ステップの後に `npx playwright test` を追加する(build は共有し二重ビルドしない)。ゲートに含める。

### 10. オフライン検証手順(手動)

1. `npm run build && npm run preview -- --port 4173`
2. Chrome で `http://localhost:4173` を開き、DevTools > Application > Service workers で activated を確認。
3. DevTools > Network > Offline に切り替え、ハードリロード → アプリシェルが描画され、EmptyState とフォント(Inter)が正常表示。
4. オフラインのまま画像をドラッグイン → 注釈 → PNG エクスポート(ダウンロードフォールバック)まで通ること(全処理がクライアントサイドである確認)。
5. Chrome でインストール(omnibox アイコン)→ Wi-Fi を OS レベルで切断 → インストール済みアプリを再起動 → 起動して操作可能。
6. `.kakico` ファイルを Finder でダブルクリック(初回は「Kakico で開く」許可)→ アプリがフォーカスされドキュメントが復元される。

### 11. ホスティング要件 — Cache-Control / CSP(デプロイ仕様)

計画にホスティング手順が無いままだと、静的ホスト既定の長期キャッシュで `sw.js` がキャッシュされた瞬間に**新 SW が永久に検出されず更新機構ごと本番で死ぬ**。デプロイ先(任意の静的ホスト)には以下の HTTP ヘッダ設定を必須要件として課す。ホスト選定時にこの表を設定できることを確認する(Cloudflare Pages / Netlify / GitHub Pages + CDN いずれも可)。

| パス | Cache-Control | 理由 |
|---|---|---|
| `/sw.js` | `no-cache`(毎回再検証) | これがキャッシュされると `registration.update()` が新 SW を検出できない |
| `/index.html`(`navigateFallback` 含む) | `no-cache` | 新 precache manifest への入口 |
| `/manifest.webmanifest` | `no-cache` | file_handlers / アイコン更新の反映 |
| `/assets/*`(ハッシュ付き JS/CSS) | `public, max-age=31536000, immutable` | 内容 = ハッシュで不変 |
| `/fonts/*`, `/icons/*`(ハッシュなし public 資産) | `public, max-age=86400` | 差し替え頻度が低い。即時反映が要るなら短縮 |

CSP: `index.html` の `<head>` に meta タグで宣言する(02 で作成した `index.html` を本ステップで変更):

```html
<meta http-equiv="Content-Security-Policy"
      content="default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' blob: data:; font-src 'self'; connect-src 'self'; worker-src 'self'; object-src 'none'; base-uri 'none'">
```

- `style-src 'unsafe-inline'` は Vite / Preact のインライン style 属性に必要(nonce 化はスコープ外)。
- `img-src blob: data:` は ImageBitmap / objectURL / drag-out 経路に必要。
- `frame-ancestors` は **meta CSP では無効**。クリックジャッキング対策が必要ならホスティング側ヘッダで `frame-ancestors 'none'`(または `X-Frame-Options: DENY`)を併せて配る。
- ホスティング側でヘッダ CSP を設定できる場合は同内容をヘッダで配る方が強い(meta は先行して読み込まれたリソースを守れない)が、meta を最低ラインとしてリポジトリに固定する。

## 定数・仕様表

| 項目 | 値 | 原典 |
|---|---|---|
| manifest `name` / `short_name` | `Kakico` | アーキテクチャ仕様 §8 |
| manifest `display` | `standalone` | アーキテクチャ仕様 §8 |
| manifest `theme_color` / `background_color` | `#F5F5F7`(miroBoard) | Sources/Kakico/Theme.swift:8 |
| dark `theme-color` meta | `#202024`(miroDarkBoard) | Sources/Kakico/Theme.swift:15 |
| icons | 192×192 / 512×512 PNG、`purpose: any maskable` | アーキテクチャ仕様 §8(02 で生成済み) |
| `launch_handler.client_mode` | `focus-existing` | アーキテクチャ仕様 §8(シングルウィンドウ = Mac 版 `applicationShouldTerminateAfterLastWindowClosed` の単一窓モデル対応) |
| `file_handlers` 受理 | `.kakico`(`application/x-kakico`)、`.png`/`.jpg`/`.jpeg`/`.webp` | アーキテクチャ仕様 §8; Mac 版 Resources/Info.plist:29-51(`public.image` + 拡張子 `kakico` の CFBundleDocumentTypes に相当) |
| `registerType` | `prompt`(新 SW は Reload まで waiting・旧 precache 保持。autoUpdate は表示中ページの遅延チャンクを破壊するため不採用) | アーキテクチャ仕様 §8(本レビューで autoUpdate から変更) |
| SW キャッシュ方針 | アプリシェル全プリキャッシュ、runtimeCaching なし、ユーザーデータ非キャッシュ | アーキテクチャ仕様 §8 |
| SW update ポーリング | `SW_UPDATE_POLL_MS = 3_600_000`(60 min) | web 新規定数(Swift 対応物なし) |
| offline-ready トースト文言 | `Ready to work offline`(1.8 s 自動消滅) | トースト機構は Sources/Kakico/CanvasController.swift:63(1.8 s) |
| 更新トースト文言 | `Reload to update` + ボタン `Reload`(永続・自動消滅なし) | web 新規(通常トースト仕様 UI.swift:75-105 からの意図的逸脱) |
| インストール完了トースト | `Installed` | web 新規 |
| トーストアニメーション | `.easeOut 0.18s`、y offset 8、bottom pad 24;Reduce Motion 時 opacity のみ | Sources/Kakico/UI.swift:78-83 |
| マーチングアンツ | `setLineDash([5,4])`、~12 Hz 位相;reduced-motion 時は位相 0 固定 | Sources/Kakico/CanvasView.swift(drawCropOverlay);アーキテクチャ仕様 §6 |
| launchQueue ルーティング | `/\.kakico$/i` → kakico、他 → image | web 新規(Mac 版 doc-type 宣言の等価物) |
| Cache-Control | `sw.js` / `index.html` / `manifest` = `no-cache`、ハッシュ付きアセット = `immutable` 長期(手順 11 の表) | web 新規(デプロイ必須要件) |
| CSP | `index.html` meta(`script-src 'self'`、`object-src 'none'`、`base-uri 'none'` ほか手順 11) | web 新規 |
| SW 登録失敗時 | トースト `Offline mode unavailable` + `logError('sw-register-failed')` | web 新規(08 errorLog) |
| 置換確認文言(launchQueue 経由でも同一) | "Replace the current image?" / "Pasting will replace the image you are editing. Unsaved annotations will be lost." / "Replace" | Sources/Kakico/ExportService.swift:93-95 |
| `share_target` | v1 では追加しない | アーキテクチャ仕様 §8 |

## 受け入れ基準

- [ ] `cd kakico-web && npx tsc --noEmit && npx eslint . && npx vitest run` が exit 0。
- [ ] `npm run build` が exit 0 で、SW と manifest が出力される: `test -f dist/sw.js && test -f dist/manifest.webmanifest`
- [ ] manifest 内容: `grep -q 'focus-existing' dist/manifest.webmanifest && grep -q 'file_handlers' dist/manifest.webmanifest && grep -q '.kakico' dist/manifest.webmanifest && grep -q 'any maskable' dist/manifest.webmanifest`
- [ ] precache にフォントが含まれる: `grep -q 'woff2' dist/sw.js`
- [ ] precache の取りこぼしなし: `[ -z "$(find dist -type f -size +5M)" ]`(`maximumFileSizeToCacheInBytes` 超のアセットは**無警告で** precache から除外され、当該ファイルだけオフラインで欠落するため、上限超の emit asset が存在しないことをビルド後にアサートする)
- [ ] CSP meta が配信物に含まれる: `grep -q 'Content-Security-Policy' dist/index.html`
- [ ] SW がユーザーデータをキャッシュしない: `! grep -q 'runtimeCaching' vite.config.ts`(runtimeCaching 定義が存在しないこと)
- [ ] `npx playwright install --with-deps chromium && npm run e2e` が exit 0(§テストの e2e 5 ケース全 pass。CI では build 済み dist に対し `npx playwright test`)。
- [ ] Lighthouse PWA カテゴリ pass(PWA カテゴリは Lighthouse 12 で削除済みのため v11 を明示指定):
      `npm run preview -- --port 4173 &` の後
      `npx lighthouse@11 http://localhost:4173 --only-categories=pwa --chrome-flags="--headless=new" --output=json --output-path=$TMPDIR/lh.json`
      を実行し、`node -e "const r=require(process.env.TMPDIR+'/lh.json');const f=Object.values(r.audits).filter(a=>a.score!==null&&a.score<1);if(f.length){console.error(f.map(a=>a.id));process.exit(1)}"` が exit 0。
- [ ] 手動(Chrome): §実装手順 10 の 1–6 を実施し全項目成功(オフラインリロード、インストール後のネット切断起動、`.kakico` ダブルクリック起動)。
- [ ] 手動(Chrome): 適当なファイルを 1 バイト変更して再ビルド → preview リロード 2 回目で「Reload to update」トーストが出て、Reload で新アセットに切り替わる。初回訪問では出ない。
- [ ] 手動(Safari / Firefox): Install ボタンが表示されず、アプリ機能(開く/注釈/エクスポート/オフラインリロード)は動作する。手順 8 の表どおりのデグレードのみ。
- [ ] 手動: DevTools > Rendering > `prefers-reduced-motion: reduce` エミュレーションで、クロップのマーチングアンツが静止し、トーストがフェードのみで出る。
- [ ] 手動: ToolPalette を Tab キーで巡回でき、各ボタンが VoiceOver でツール名を読み上げる(macOS: ⌘F5)。

## テスト

### vitest(node / happy-dom)

| ファイル | テスト名 | アサーション |
|---|---|---|
| `tests/platform/launchRouting.test.ts` | `routes .kakico to kakico` | `routeLaunchFile('doc.kakico') === 'kakico'` |
| 〃 | `routing is case-insensitive` | `routeLaunchFile('DOC.KAKICO') === 'kakico'` |
| 〃 | `routes images to image` | `'shot.png'`/`'a.jpg'`/`'b.jpeg'`/`'c.webp'` すべて `'image'` |
| 〃 | `routes unknown extensions to image` | `routeLaunchFile('x.bin') === 'image'`(画像デコード失敗は 05 のロード経路が beep 相当で処理) |
| `tests/state/pwaFlags.test.ts` | `setUpdateAvailable flips flag once` | 初期 `false` → action 後 `true`、subscribe 通知が 1 回(microtask バッチ) |
| 〃 | `setCanInstall round-trips` | `true` → `false` の往復が snapshot に反映 |
| 〃 | `pwa flags are not part of undo` | `setUpdateAvailable()` 後に `undo()` してもフラグ不変、document 不変 |
| `tests/ui/UpdateToast.test.tsx` | `hidden when no update` | `updateAvailable: false` で DOM に出ない |
| 〃 | `renders and reloads on click` | `updateAvailable: true` で `role="status"` 要素(文言 `Reload to update`)と `Reload` ボタンが出現、click で注入した `reloadToUpdate` spy が 1 回呼ばれる(swUpdate の関数は DI で差し替え) |
| `tests/engine/cropOverlay.test.ts`(新規) | `marching ants freeze under reduced motion` | `prefersReducedMotion: () => true` 注入時、tick を複数回進めても `lineDashOffset === 0`;`false` 時は位相が進む |

### Playwright(`tests/e2e/smoke.spec.ts`)

| テスト名 | 内容 |
|---|---|
| `loads app shell with SW registered` | ページロード → EmptyState 表示 → `navigator.serviceWorker.ready` 解決 → manifest link が存在 |
| `offline reload works` | 初回ロードで SW activate を待つ → `context.setOffline(true)` → `page.reload()` → EmptyState が再描画される |
| `open image, annotate, undo` | `<input type=file>` フォールバックで `tests/fixtures/` の PNG を開く → canvas 出現 → mouse drag で arrow 作成 → ImageSizeBadge の文言確認 → `Meta+Z` で undo |
| `copy to clipboard shows toast` | 画像を開く → Copy ボタン click → トースト `Copied to clipboard` が出現し 1.8 s 後に消える |
| `paste replaces with confirmation` | 画像を開いた状態で clipboard に画像を書き込み(`page.evaluate` + `ClipboardItem`)→ paste → ConfirmDialog の "Replace the current image?" → Replace → canvas が新画像サイズに変わる |

インストールフローと `file_handlers` は Playwright で自動化不可(ブラウザ UI 外)のため、§受け入れ基準の手動項目でカバーする。
