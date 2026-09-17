# 陶朱（taozhu）— 通用进销存

菜铺/批发记账系统：店铺、商品（多单位双价）、进货、出货（进价快照计毛利）、收款（平账减免）、库存联动、两级分类、统计报表、对账单分享、凭证附件、数据备份 / 导入导出、多端（Android / iOS / Windows / macOS / Linux / Web / 微信小程序）。

> 架构：Cloudflare Workers + Hono + D1（SQLite） + R2（附件与自动备份）；App 本地优先（sembast）+ 变更流同步（`sale_item`/`purchase_item` 行级主记录，无"整单"容器，每条商品独立记录）。

---

## 一、自托管部署（主仓库）

### 1. 前置

- GitHub 账号，Fork 或直接 Clone 本仓库（构建发布依赖 GitHub Actions）。
- Cloudflare 账号（Workers 免费额度即可）。

### 2. 仓库 Secrets（Settings → Secrets and variables → Actions）

| Secret | 说明 | 必填 |
|---|---|---|
| `CLOUDFLARE_API_TOKEN` | Cloudflare API Token（权限：Workers Scripts Edit + D1 Edit + R2 Edit 或全权限） | 是 |
| `JWT_SECRET` | 任意随机长字符串（登录令牌签名密钥） | 是 |
| `ANDROID_KEYSTORE_BASE64` | Android 签名 keystore（base64），配套 `ANDROID_KEYSTORE_STORE_PASS` / `ANDROID_KEYSTORE_KEY_PASS` / `ANDROID_KEYSTORE_ALIAS` | 打包 APK 时 |
| `WX_APPID` / `WX_PRIVATE_KEY` | 微信小程序 AppID 与上传密钥（base64） | 上传小程序时 |

### 3. 触发发布

- 修改 `src/version.ts`、`frontend-flutter/lib/version.dart`、`frontend-uni/src/version.ts`、`frontend-uni/src/manifest.json`、`tests/api.test.ts` 五处版本号（一致递增，三位如 `0.17.125`），推送到 `main`。
- GitHub Actions `Build All Platforms` 自动执行：测试 → 创建 Release → 五大平台产物并行构建 → 微信小程序 → 最后部署 Worker + Web 到你的 Cloudflare。
- 版本守卫：同名 tag 已存在且非当前提交时构建失败——**每次发版必须递增版本号**，不要复用已发布版本号。

### 4. 验证

- 部署完成后访问 `https://taozhu.<你的子域>.workers.dev` 或自定义域名。
- 首次打开网页自动初始化建表（`/api/v1/auth/bootstrap` 创建老板账号）。

### 5. 数据备份

- 「我的」页 → 数据备份：手动导出 JSON / 导入恢复；自动备份每天按「我的」页 → 自动备份时间（默认 03:05 北京时间）自动导出到 R2 `taozhu/backups/`（保留最近 14 份）。

---

## 二、Fork 用户说明

Fork 后默认**只构建测试 + 微信小程序 + Web（若配置 Cloudflare）**，不构建 Android / 桌面端产物：

| 你的配置 | 会执行 |
|---|---|
| 未配置任何 secrets | 什么都不跑（连测试都跳过） |
| 配置了 `CLOUDFLARE_API_TOKEN` + `JWT_SECRET` | 测试 → 构建 Web → 部署到你自己的 Cloudflare |
| 配置了 `WX_APPID` / `WX_PRIVATE_KEY` | 测试 → 小程序构建 + 上传微信 + 打 zip |

- 修改五处版本号后推送 `main` 即自动构建部署。
- 你的 Cloudflare 会自动创建 Worker（名称 `taozhu`）、D1 数据库（`taozhu`）、R2 bucket（`taozhu-attachments`）。
- 未配置 secrets 时不会部署，也不打 zip——避免无意义的构建。

---

## 三、本地开发

```bash
npm install            # 后端依赖（Hono / Wrangler）
npm run typecheck      # TS 类型检查
npm test               # vitest 全量测试（sql.js 内存库，无需真实 D1）
npx wrangler dev       # 本地起 Worker（需 wrangler.toml 填真实 database_id）
```

前端（Flutter）：`frontend-flutter/`（`flutter run`，Web 用 API_BASE 注入）；小程序（uni-app）：`frontend-uni/`（`npm run dev:mp-weixin`）。

---

## 四、测试

- 后端：`npm test`（vitest + sql.js，覆盖路由 / 同步 / 统计 / 附件 / 迁移 / 审计 / 限流等）。
- 前端：`frontend-flutter/` 下 `flutter test`（版本函数等纯逻辑单测）。
- CI：`Build All Platforms` 首个 job 为 `Test（vitest + typecheck）`，任一平台构建失败则全部中止（全通过或全不通过）。