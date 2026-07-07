# 02. プロジェクトセットアップ — kakico-web スキャフォールド

## 目的

TypeScript PWA 版 Kakico の器を作る。Vite + Preact + strict TypeScript + Vitest + ESLint 境界ルール + `theme.css`(Theme.swift トークンの移植) + ドットグリッド背景 + EmptyState(ボタンはまだ無効)+ CI ワークフローまで。アプリロジックは一切実装しない。以降の全マイルストーン(03–09)がこの土台の上に載る。

## 前提

- 先行ステップなし(本ドキュメントが実装の第一歩)。
- アーキテクチャ仕様書(`docs/migrate-to-typescript/` 冒頭の Final Architecture Specification)に準拠すること。ディレクトリ構成・命名規約・依存方針はそちらが正。
- 実行環境: Node.js 22 以上、npm、macOS(アイコン生成に `qlmanage`/`sips` を使用。他 OS の場合は §実装手順 10 の代替手順)。

## 作成・変更ファイル

すべて新規作成。リポジトリルート(`/Users/hiroki.takatsuka/github.com/kakico/`)直下に `kakico-web/` を作る。

```
kakico-web/
├── .gitignore
├── index.html
├── package.json
├── tsconfig.json
├── vite.config.ts
├── eslint.config.js
├── .prettierrc.json
├── public/
│   ├── icons/
│   │   ├── favicon.svg
│   │   ├── icon-192.png        # 生成物(手順10)
│   │   └── icon-512.png        # 生成物(手順10)
│   └── fonts/inter/.gitkeep    # フォント本体は 04 で追加
├── src/
│   ├── main.tsx
│   ├── model/.gitkeep
│   ├── render/.gitkeep
│   ├── state/.gitkeep
│   ├── engine/.gitkeep
│   ├── platform/.gitkeep
│   ├── keyboard/.gitkeep
│   └── ui/
│       ├── App.tsx
│       ├── EmptyState.tsx
│       └── theme.css
└── tests/
    ├── smoke.test.ts
    ├── model/.gitkeep
    ├── render/.gitkeep
    ├── state/.gitkeep
    ├── engine/.gitkeep
    └── fixtures/.gitkeep
```

リポジトリルート側(`kakico-web/` の外):

```
.github/workflows/kakico-web-ci.yml
```

## 実装手順

### 1. ディレクトリ骨格の作成

```bash
cd /Users/hiroki.takatsuka/github.com/kakico
mkdir -p kakico-web/public/icons kakico-web/public/fonts/inter
mkdir -p kakico-web/src/{model,render,state,engine,platform,keyboard,ui}
mkdir -p kakico-web/tests/{model,render,state,engine,fixtures}
mkdir -p .github/workflows
touch kakico-web/public/fonts/inter/.gitkeep
touch kakico-web/src/{model,render,state,engine,platform,keyboard}/.gitkeep
touch kakico-web/tests/{model,render,state,engine,fixtures}/.gitkeep
```

### 2. 依存インストール

```bash
cd kakico-web
npm install preact
npm install -D typescript vite @preact/preset-vite vite-plugin-pwa \
  vitest eslint @eslint/js typescript-eslint prettier
```

ランタイム依存は **`preact` のみ**(アーキテクチャ仕様 §1)。他はすべて devDependencies。バージョンはインストール時の最新を採用し、`package-lock.json` をコミットして固定する。

### 3. `kakico-web/package.json`

`npm install` 後、以下のフィールドを設定(dependencies/devDependencies は npm が書いた内容を保持):

```json
{
  "name": "kakico-web",
  "private": true,
  "version": "0.1.0",
  "type": "module",
  "scripts": {
    "dev": "vite",
    "build": "tsc --noEmit && vite build",
    "preview": "vite preview",
    "test": "vitest run",
    "test:watch": "vitest",
    "typecheck": "tsc --noEmit",
    "lint": "eslint .",
    "format": "prettier --write ."
  }
}
```

### 4. `kakico-web/tsconfig.json`(全文)

```json
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "ESNext",
    "moduleResolution": "bundler",
    "lib": ["ES2022", "DOM", "DOM.Iterable"],
    "strict": true,
    "noUncheckedIndexedAccess": true,
    "exactOptionalPropertyTypes": true,
    "noImplicitOverride": true,
    "noFallthroughCasesInSwitch": true,
    "isolatedModules": true,
    "verbatimModuleSyntax": true,
    "forceConsistentCasingInFileNames": true,
    "skipLibCheck": true,
    "noEmit": true,
    "jsx": "react-jsx",
    "jsxImportSource": "preact",
    "types": ["vite/client"]
  },
  "include": ["src", "tests", "vite.config.ts"]
}
```

注意: `lib` に DOM を含めるが、`src/model/` と `src/render/` の DOM 禁止は手順 6 の ESLint ルールで機械的に強制する(アーキテクチャ仕様 §4)。

### 5. `kakico-web/vite.config.ts`(全文)

```ts
import { defineConfig } from 'vitest/config';
import preact from '@preact/preset-vite';
import { VitePWA } from 'vite-plugin-pwa';

export default defineConfig({
  plugins: [
    preact(),
    VitePWA({
      // Service Worker の登録・更新トーストはマイルストーン 09 で有効化。
      // ここでは manifest 生成のみを目的とする。
      injectRegister: false,
      registerType: 'prompt', // 09 §1 の確定値(新 SW は Reload まで waiting・旧 precache 保持)
      manifest: {
        name: 'Kakico',
        short_name: 'Kakico',
        display: 'standalone',
        start_url: '/',
        // Theme.swift の miroBoard (#F5F5F7)。§定数・仕様表を参照。
        theme_color: '#F5F5F7',
        background_color: '#F5F5F7',
        icons: [
          {
            src: '/icons/icon-192.png',
            sizes: '192x192',
            type: 'image/png',
            purpose: 'any maskable',
          },
          {
            src: '/icons/icon-512.png',
            sizes: '512x512',
            type: 'image/png',
            purpose: 'any maskable',
          },
        ],
        // launch_handler / file_handlers は 09 で追加(アーキテクチャ仕様 §8)。
      },
      workbox: {
        globPatterns: ['**/*.{js,css,html,svg,png,woff2}'],
      },
    }),
  ],
  test: {
    environment: 'node',
    include: ['tests/**/*.test.ts', 'tests/**/*.test.tsx'],
    // 04 で browser mode (playwright provider) の project を追加予定。
  },
});
```

### 6. `kakico-web/eslint.config.js`(全文)と `.prettierrc.json`

```js
// eslint.config.js
import js from '@eslint/js';
import tseslint from 'typescript-eslint';

export default tseslint.config(
  { ignores: ['dist/', 'dev-dist/', 'node_modules/'] },
  js.configs.recommended,
  ...tseslint.configs.strict,

  // 境界ルール1: model/ と render/ は DOM フリー・上位レイヤ非依存
  // (Sources/AnnotationModel, Sources/AnnotationRender が UI 非依存であることの移植)
  {
    files: ['src/model/**/*.ts', 'src/render/**/*.ts'],
    rules: {
      'no-restricted-globals': [
        'error',
        'window',
        'document',
        'navigator',
        'localStorage',
        'indexedDB',
        'fetch',
      ],
      'no-restricted-imports': [
        'error',
        {
          patterns: [
            {
              group: ['preact', 'preact/*', '**/state/*', '**/engine/*', '**/ui/*', '**/platform/*'],
              message: 'model/ and render/ must stay DOM-free (import model only).',
            },
          ],
        },
      ],
    },
  },
  // 境界ルール2: model/ は render/ にも依存しない
  {
    files: ['src/model/**/*.ts'],
    rules: {
      'no-restricted-imports': [
        'error',
        {
          patterns: [
            {
              group: [
                'preact',
                'preact/*',
                '**/render/*',
                '**/state/*',
                '**/engine/*',
                '**/ui/*',
                '**/platform/*',
              ],
              message: 'model/ is the pure bottom layer.',
            },
          ],
        },
      ],
    },
  },
  // 境界ルール3: ui/ は engine/ 内部に触れない(store 経由のみ)
  {
    files: ['src/ui/**/*.ts', 'src/ui/**/*.tsx'],
    rules: {
      'no-restricted-imports': [
        'error',
        {
          patterns: [
            {
              group: ['**/engine/*'],
              message: 'ui/ must not import engine internals; go through state/.',
            },
          ],
        },
      ],
    },
  },
  // 唯一の例外: CanvasMount.tsx は CanvasHost を new する橋渡し役(アーキテクチャ仕様 §2)
  {
    files: ['src/ui/CanvasMount.tsx'],
    rules: { 'no-restricted-imports': 'off' },
  },
);
```

```json
{ "singleQuote": true, "printWidth": 100 }
```

### 7. `kakico-web/index.html`(全文)

```html
<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <meta name="theme-color" content="#F5F5F7" media="(prefers-color-scheme: light)" />
    <meta name="theme-color" content="#202024" media="(prefers-color-scheme: dark)" />
    <link rel="icon" href="/icons/favicon.svg" type="image/svg+xml" />
    <title>Kakico</title>
  </head>
  <body>
    <div id="app"></div>
    <script type="module" src="/src/main.tsx"></script>
  </body>
</html>
```

manifest の `<link>` は `vite-plugin-pwa` がビルド時に注入するため手書きしない。

### 8. `kakico-web/src/ui/theme.css`(全文)

`Sources/Kakico/Theme.swift` のトークンを `--kk-` プレフィックスで 1:1 移植(命名規約はアーキテクチャ仕様 §9)。hex 値は §定数・仕様表で原典と突合済み。

```css
/* theme.css — 1:1 port of Sources/Kakico/Theme.swift tokens */

:root {
  /* Board & Chrome (Light) — Theme.swift:8-12 */
  --kk-miro-board: #f5f5f7;
  --kk-miro-grid: #d7d7de;
  --kk-miro-surface-gray: #f1f1f4;
  --kk-miro-surface-pressed: #e6e6eb;
  --kk-miro-divider: #e3e3e8;

  /* Board & Chrome (Dark) — Theme.swift:15-17 */
  --kk-miro-dark-board: #202024;
  --kk-miro-dark-grid: #38383f;
  --kk-miro-dark-surface2: #313138;

  /* Text — Theme.swift:20-22 */
  --kk-miro-ink: #050038;
  --kk-miro-text-secondary: #6b6b7b;
  --kk-miro-dark-text-primary: #ececef;

  /* Brand / Interactive — Theme.swift:25-26 */
  --kk-miro-yellow: #ffd02f;
  --kk-miro-blue: #4262ff;

  /* Semantic — Theme.swift:29 */
  --kk-miro-success: #2ea56a;

  /* Scheme-resolved aliases (MiroTheme — Theme.swift:39-56) */
  --kk-board: var(--kk-miro-board);
  --kk-grid: var(--kk-miro-grid);
  --kk-text-primary: var(--kk-miro-ink);
  --kk-text-secondary: var(--kk-miro-text-secondary);
  --kk-surface: var(--kk-miro-surface-gray);
  --kk-surface-pressed: var(--kk-miro-surface-pressed);

  /* Typography (Font.miro* — Theme.swift:61-64); chrome は system font
     (canvas 内テキスト用の Inter は 04 でバンドル) */
  --kk-font-family: system-ui, -apple-system, 'Segoe UI', sans-serif;
  --kk-font-body: 400 16px/1.4 var(--kk-font-family);
  --kk-font-control: 600 15px/1.3 var(--kk-font-family);
  --kk-font-button: 700 15px/1.3 var(--kk-font-family);
  --kk-font-caption: 600 12px/1.3 var(--kk-font-family);

  /* Grid geometry (MiroGrid — Theme.swift:71,85): spacing 28px, dot 1.5px */
  --kk-grid-spacing: 28px;
  --kk-grid-dot: 1.5px;
}

@media (prefers-color-scheme: dark) {
  :root {
    --kk-board: var(--kk-miro-dark-board);
    --kk-grid: var(--kk-miro-dark-grid);
    --kk-text-primary: var(--kk-miro-dark-text-primary);
    /* MiroTheme.textSecondary(dark) = miroDarkTextPrimary @ 65% — Theme.swift:51 */
    --kk-text-secondary: color-mix(in srgb, var(--kk-miro-dark-text-primary) 65%, transparent);
    --kk-surface: var(--kk-miro-dark-surface2);
    --kk-surface-pressed: var(--kk-miro-dark-grid);
  }
}

html,
body,
#app {
  height: 100%;
  margin: 0;
}

body {
  font: var(--kk-font-body);
  color: var(--kk-text-primary);
  -webkit-font-smoothing: antialiased;
}

/* Dot-grid board — MiroGrid tile (Theme.swift:69-96) を radial-gradient で再現。
   ドットはタイル左上、直径 1.5px(半径 0.75px、中心 0.75,0.75)。 */
.kk-board {
  height: 100%;
  background-color: var(--kk-board);
  background-image: radial-gradient(
    circle at 0.75px 0.75px,
    var(--kk-grid) 0.75px,
    transparent 0.75px
  );
  background-size: var(--kk-grid-spacing) var(--kk-grid-spacing);
}

/* Buttons — MiroPrimaryButton / MiroSecondaryButton (Theme.swift:111-144) */
.kk-btn {
  font: var(--kk-font-control);
  padding: 10px 20px;
  border: none;
  border-radius: 10px;
  cursor: pointer;
  transition: transform 0.15s ease-out;
}
.kk-btn:active:not(:disabled) {
  transform: scale(0.98); /* MiroPressStyle — Theme.swift:105 */
}
.kk-btn:disabled {
  opacity: 0.4;
  cursor: default;
}
.kk-btn-primary {
  font: var(--kk-font-button);
  color: var(--kk-miro-ink);
  background: var(--kk-miro-yellow);
}
.kk-btn-secondary {
  color: var(--kk-text-primary);
  background: var(--kk-surface);
}

/* Floating panel chrome — miroFloatingPanel (Theme.swift:182-209)。
   .regularMaterial ≈ 半透明サーフェス + backdrop blur。07 のパレット等で使用。 */
.kk-panel {
  padding: 8px;
  border-radius: 16px;
  background: color-mix(in srgb, var(--kk-board) 78%, transparent);
  backdrop-filter: blur(20px) saturate(180%);
  -webkit-backdrop-filter: blur(20px) saturate(180%);
  border: 1px solid color-mix(in srgb, var(--kk-miro-divider) 50%, transparent);
  /* Theme.swift:190 の shadow(radius 16, y 14)。SwiftUI shadow radius 16 ≈ CSS blur 32px */
  box-shadow: 0 14px 32px rgba(0, 0, 0, 0.22);
}

@media (prefers-reduced-motion: reduce) {
  .kk-btn {
    transition: none;
  }
}
```

### 9. エントリポイントと EmptyState(死にボタン)

`kakico-web/src/main.tsx`(全文):

```tsx
import { render } from 'preact';
import { App } from './ui/App';
import './ui/theme.css';

const root = document.getElementById('app');
if (!root) throw new Error('#app not found');
render(<App />, root);
// SW 登録・launchQueue・beforeunload ガードは後続マイルストーンで追加。
```

`kakico-web/src/ui/App.tsx`(全文)— `ContentView`(Sources/Kakico/UI.swift)の骨格のみ:

```tsx
import { EmptyState } from './EmptyState';

export function App() {
  return (
    <div class="kk-board">
      <EmptyState />
    </div>
  );
}
```

`kakico-web/src/ui/EmptyState.tsx`(全文)— UI.swift:106-125 の移植。文言は原典のまま。ボタンは `disabled`(Open は 05、Paste は 05/08 で配線):

```tsx
export function EmptyState() {
  return (
    <div
      style={{
        height: '100%',
        display: 'flex',
        flexDirection: 'column',
        alignItems: 'center',
        justifyContent: 'center',
        gap: '16px',
      }}
    >
      {/* SF Symbol photo.on.rectangle.angled の代替プレースホルダ(56px)。
          正式なオリジナルアイコンは 07 の icons.tsx で置換。 */}
      <svg width="56" height="56" viewBox="0 0 56 56" aria-hidden="true">
        <rect x="6" y="12" width="36" height="28" rx="4" fill="none" stroke="var(--kk-text-secondary)" stroke-width="2.5" />
        <rect x="16" y="20" width="36" height="28" rx="4" fill="var(--kk-board)" stroke="var(--kk-text-secondary)" stroke-width="2.5" />
        <circle cx="26" cy="30" r="3" fill="var(--kk-text-secondary)" />
        <path d="M18 44l10-9 6 5 8-7 10 11" fill="none" stroke="var(--kk-text-secondary)" stroke-width="2.5" />
      </svg>
      <p style={{ font: 'var(--kk-font-body)', color: 'var(--kk-text-secondary)', margin: 0 }}>
        Open or drop an image to start annotating
      </p>
      <div style={{ display: 'flex', gap: '12px' }}>
        <button class="kk-btn kk-btn-primary" disabled>
          Open Image…
        </button>
        <button class="kk-btn kk-btn-secondary" disabled>
          Paste from Clipboard
        </button>
      </div>
    </div>
  );
}
```

### 10. アイコンプレースホルダ

`kakico-web/public/icons/favicon.svg`(全文)— miroYellow 地に miroInk の「K」。全面塗り(full-bleed)にして maskable 兼用:

```svg
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512">
  <rect width="512" height="512" fill="#FFD02F"/>
  <text x="256" y="345" font-family="system-ui, sans-serif" font-size="260"
        font-weight="700" text-anchor="middle" fill="#050038">K</text>
</svg>
```

PNG 生成(macOS。プレースホルダであり、09 で正式アートワークに差し替え):

```bash
cd kakico-web
qlmanage -t -s 512 -o public/icons public/icons/favicon.svg
mv public/icons/favicon.svg.png public/icons/icon-512.png
sips -z 192 192 public/icons/icon-512.png --out public/icons/icon-192.png
```

macOS 以外の環境では、任意のツール(例: `npx svg2png-cli`、ImageMagick `convert`)で同名の 512/192 PNG を生成すればよい。生成物 `icon-192.png` / `icon-512.png` はコミットする。

### 11. スモークテスト

`kakico-web/tests/smoke.test.ts`(全文):

```ts
import { describe, expect, it } from 'vitest';

describe('scaffold smoke', () => {
  it('vitest runs under the strict TS config', () => {
    expect(1 + 1).toBe(2);
  });

  it('ES2022 lib is available (target/lib check)', () => {
    expect([1, 2, 3].at(-1)).toBe(3);
    expect(Object.hasOwn({ kind: 'arrow' }, 'kind')).toBe(true);
  });
});
```

### 12. `.gitignore`

`kakico-web/.gitignore`(全文):

```
node_modules/
dist/
dev-dist/
```

### 13. CI ワークフロー

`.github/workflows/kakico-web-ci.yml`(リポジトリルート側、全文)。マイルストーン共通の CI ゲート `tsc --noEmit && eslint && vitest run`(アーキテクチャ仕様 §7)+ `vite build`:

```yaml
name: kakico-web CI

on:
  push:
    branches: [main]
    paths: ['kakico-web/**', '.github/workflows/kakico-web-ci.yml']
  pull_request:
    paths: ['kakico-web/**', '.github/workflows/kakico-web-ci.yml']

jobs:
  ci:
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: kakico-web
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: 22
          cache: npm
          cache-dependency-path: kakico-web/package-lock.json
      - run: npm ci
      - run: npx tsc --noEmit
      - run: npx eslint .
      - run: npx vitest run
      - run: npm run build
```

### 14. ローカル検証

§受け入れ基準のコマンドを上から順に実行し、全項目のパスを確認してからコミット。PR 説明には「Theme.swift トークン移植」「UI.swift EmptyState 骨格移植」を明記(アーキテクチャ仕様 §10)。

## 定数・仕様表

カラートークン(hex は Theme.swift 内コメントと `red/green/blue` 値(×255, 四捨五入)の双方で照合済み):

| CSS custom property | 値 | Swift トークン | 原典 |
|---|---|---|---|
| `--kk-miro-board` | `#F5F5F7` | `Color.miroBoard` (0.961, 0.961, 0.969) | Sources/Kakico/Theme.swift:8 |
| `--kk-miro-grid` | `#D7D7DE` | `Color.miroGrid` (0.843, 0.843, 0.871) | Sources/Kakico/Theme.swift:9 |
| `--kk-miro-surface-gray` | `#F1F1F4` | `Color.miroSurfaceGray` (0.945, 0.945, 0.957) | Sources/Kakico/Theme.swift:10 |
| `--kk-miro-surface-pressed` | `#E6E6EB` | `Color.miroSurfacePressed` (0.902, 0.902, 0.922) | Sources/Kakico/Theme.swift:11 |
| `--kk-miro-divider` | `#E3E3E8` | `Color.miroDivider` (0.890, 0.890, 0.910) | Sources/Kakico/Theme.swift:12 |
| `--kk-miro-dark-board` | `#202024` | `Color.miroDarkBoard` (0.125, 0.125, 0.141) | Sources/Kakico/Theme.swift:15 |
| `--kk-miro-dark-grid` | `#38383F` | `Color.miroDarkGrid` (0.220, 0.220, 0.247) | Sources/Kakico/Theme.swift:16 |
| `--kk-miro-dark-surface2` | `#313138` | `Color.miroDarkSurface2` (0.192, 0.192, 0.220) | Sources/Kakico/Theme.swift:17 |
| `--kk-miro-ink` | `#050038` | `Color.miroInk` (0.020, 0.000, 0.220) | Sources/Kakico/Theme.swift:20 |
| `--kk-miro-text-secondary` | `#6B6B7B` | `Color.miroTextSecondary` (0.420, 0.420, 0.482) | Sources/Kakico/Theme.swift:21 |
| `--kk-miro-dark-text-primary` | `#ECECEF` | `Color.miroDarkTextPrimary` (0.925, 0.925, 0.937) | Sources/Kakico/Theme.swift:22 |
| `--kk-miro-yellow` | `#FFD02F` | `Color.miroYellow` (1.000, 0.816, 0.184) | Sources/Kakico/Theme.swift:25 |
| `--kk-miro-blue` | `#4262FF` | `Color.miroBlue` (0.259, 0.384, 1.000) | Sources/Kakico/Theme.swift:26 |
| `--kk-miro-success` | `#2EA56A` | `Color.miroSuccess` (0.180, 0.647, 0.416) | Sources/Kakico/Theme.swift:29 |

その他の仕様:

| 項目 | 値 | 原典 |
|---|---|---|
| manifest `name`/`short_name` | `Kakico` | アーキテクチャ仕様 §8 |
| manifest `display` | `standalone` | アーキテクチャ仕様 §8 |
| manifest `theme_color`/`background_color` | `#F5F5F7`(= miroBoard) | Sources/Kakico/Theme.swift:8 |
| dark `theme-color` meta | `#202024`(= miroDarkBoard) | Sources/Kakico/Theme.swift:15 |
| ドットグリッド間隔 | `28px` | Sources/Kakico/Theme.swift:71 (`spacing: CGFloat = 28`) |
| ドット径 | `1.5px`、タイル左上配置 | Sources/Kakico/Theme.swift:85 (`ovalIn: NSRect(0,0,1.5,1.5)`) |
| ダークの二次テキスト | miroDarkTextPrimary の 65% 不透明 | Sources/Kakico/Theme.swift:51 |
| Typography | body 16/400, control 15/600, button 15/700, caption 12/600 | Sources/Kakico/Theme.swift:61-64 |
| ボタン padding / 角丸 | `10px 20px` / `10px` | Sources/Kakico/Theme.swift:120,122 |
| 押下スケール | `0.98`(タイルは `0.96`) | Sources/Kakico/Theme.swift:105,172 |
| パネル: padding/角丸/影/枠線 | `8px` / `16px` / `0 14px 32px rgba(0,0,0,0.22)`(SwiftUI shadow radius 16 ≈ CSS blur 32px)/ miroDivider 50% 1px | Sources/Kakico/Theme.swift:190,194,201 |
| EmptyState 文言 | `Open or drop an image to start annotating` | Sources/Kakico/UI.swift:112-116 |
| EmptyState ボタン | `Open Image…`(primary)/ `Paste from Clipboard`(secondary) | Sources/Kakico/UI.swift:117-124 |
| EmptyState アイコンサイズ | 56pt → 56px | Sources/Kakico/UI.swift:112 |

## 受け入れ基準

すべて `kakico-web/` で実行(明記あるものを除く)。

- [ ] `npm ci` が exit 0(`package-lock.json` がコミット済み)
- [ ] `npm run typecheck` が exit 0
- [ ] `npm run lint` が exit 0
- [ ] `npm test` が exit 0 で、テスト 2 件がパス
- [ ] `npm run build` が exit 0 で、`dist/index.html` と `dist/manifest.webmanifest` が存在する:
      `test -f dist/index.html && test -f dist/manifest.webmanifest`
- [ ] manifest の内容確認: `grep -q '"name":"Kakico"' dist/manifest.webmanifest && grep -q '"display":"standalone"' dist/manifest.webmanifest && grep -q '#F5F5F7' dist/manifest.webmanifest`
- [ ] アイコンが存在する: `test -f public/icons/favicon.svg && test -f public/icons/icon-192.png && test -f public/icons/icon-512.png`
- [ ] 境界 lint が機能する(ルール発火の確認後、一時ファイル削除):
      `echo 'export const x = window;' > src/model/_check.ts; npx eslint src/model/_check.ts; test $? -ne 0 && rm src/model/_check.ts`
- [ ] `npm run dev` を起動し、`curl -s http://localhost:5173/ | grep -q 'id="app"'` が成功する
- [ ] 手動確認(ブラウザで http://localhost:5173/): ドットグリッド背景(#F5F5F7 地に #D7D7DE のドット、28px 間隔)、中央に EmptyState(アイコン + 文言 + 無効ボタン 2 個)が表示される
- [ ] 手動確認: DevTools で `prefers-color-scheme: dark` をエミュレートすると背景が #202024、ドットが #38383F に切り替わる
- [ ] `.github/workflows/kakico-web-ci.yml` がリポジトリルートに存在し、push 後に GitHub Actions の `kakico-web CI` が成功する(`gh run list --workflow=kakico-web-ci.yml` で確認)
- [ ] `git status` に `node_modules/` / `dist/` が現れない
- [ ] `src/` にアプリロジック(model/render/state/engine/platform/keyboard の実装ファイル)が存在しない(`.gitkeep` のみ)

## テスト

本ステップの Vitest は環境健全性の確認のみ(アプリロジック非実装のため)。

| テストファイル | ケース名 | アサーション |
|---|---|---|
| `tests/smoke.test.ts` | `vitest runs under the strict TS config` | `1 + 1 === 2`。Vitest 実行系と tsconfig の解決が機能すること |
| `tests/smoke.test.ts` | `ES2022 lib is available (target/lib check)` | `[1,2,3].at(-1) === 3` と `Object.hasOwn` の存在。`target: ES2022` / `lib: ES2022` の設定ミス検出 |

境界ルール(model/render の DOM フリー)の検証は Vitest ではなく §受け入れ基準の一時ファイルによる ESLint 発火確認で行う。本格的なテスト(Swift テスト移植)は 03 以降。
