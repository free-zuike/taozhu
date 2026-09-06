# 陶朱（bizclassic / taozhu）

通用进销存记账系统——管理客户、商品（多单位/进价/出价）、出货、进货、收款结账与多用户权限。
任何生意都能用（送菜、批发、小店…），部署在 Cloudflare Workers（零主机）。

## 功能

- **商品管理**：商品 + 单位价格组合（同一商品可 斤/袋/箱 多价：进价 → 出价）
- **记录**：出货记单（选饭店 → 商品 → 数量 → 自动带价）、进货记单
- **结账**：收款登记，欠款 = 累计出货 − 累计收款（按饭店）
- **统计**：工作台卡片、按店（出货/收款/欠款/毛利）、按月统计（年份随数据动态）
- **多用户**:老板/店员两角色（店员记单查看，管理操作仅老板）
- **AI 拍照识别**：拍小票/价签自动识别商品清单（OpenAI 兼容，后台自配地址/Key/模型，默认智谱免费 `glm-4v-flash`）
- **Android App**：Capacitor 打包，GitHub Actions 云构建 APK

## 技术栈

- 后端：Cloudflare Workers + D1（SQLite）+ Hono + JWT（角色权限）
- 前端：Vite + Vue3 + Element Plus + Pinia（打包产物由 Workers 静态托管，同源）
- 移动端：Capacitor（Android），App 内 API 指向生产域名
- CI：GitHub Actions —— push 自动部署 Web；构建 APK

## 本地开发

```bash
# 1. 起后端（本地模拟 D1 + ASSETS）
npm install
cp .dev.vars.example .dev.vars   # 写入 JWT_SECRET（本地测试值）
npx wrangler dev

# 2. 另开终端起前端（代理 /api → 8787）
cd frontend && npm install && npm run dev
# 打开 http://localhost:5173 → 首次进入创建老板账号
```

测试：`npm test`（后端 44 项）、`cd frontend && npm run build`（类型检查 + 构建）

## 部署（GitHub Actions 自动）

1. 创建 GitHub 仓库并推送 main
2. 设置 Actions secrets：
   - `CLOUDFLARE_API_TOKEN`（权限：Workers Scripts Edit + D1 Edit + 账户 Read）
   - `JWT_SECRET`（随机 32 字节 hex，生产登录签名密钥）
3. push main → 自动：创建/复用 D1 `bizclassic` → 构建前端 → `wrangler deploy` 上线
4. 首次访问 `/` → 创建老板账号

Worker 名/域名见 `wrangler.toml`（默认 `bizclassic`，可改）；D1 自动创建，无需手动建库。

## Android App

- 仓库 Actions → **Build Android APK** 手动运行（或打 `v*` tag）→ 下载 artifact `app-debug.apk` 安装
- App 内 API 地址在构建时注入 `VITE_API_BASE`（指向前端域名）

## 目录

```
src/              后端（Hono 路由 + D1 schema + 认证）
frontend/src/     前端（Vue 页面 + Element Plus）
tests/            后端端到端测试（sql.js 内存库 + 真路由）
.github/workflows/ deploy（部署）+ build-android（APK）
```