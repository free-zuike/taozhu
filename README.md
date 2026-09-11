# 陶朱（taozhu）

通用进销存记账系统——管理客户、商品（多单位/进价/出价）、出货、进货、收款结账、两级分类与多用户权限。菜铺、批发、小店都能用，部署在 Cloudflare Workers（零主机）。

## 功能

- **商品管理**：商品 + 单位价格组合（同商品可 斤/袋/箱 多价：进价 → 出价），支持编辑、改价、停用价格、按名称搜索
- **记录**：出货记单（选店铺 → 商品 → 数量 → 自动带价，可改日期补录）、进货记单（同），AI 拍照识别小票自动填单；常用商品/店铺按本地使用频率置顶
- **账本**：出货 / 进货 / 收款历史，按店铺+日期筛选，单笔可**编辑、删除**，一键**复制 CSV** 到 Excel（纠错入口）
- **附件**：交易可挂凭证图片（拍照扫描/相册选择），**本地存一份 + 云端 R2 存一份**（断网可见、防记录错误）
- **对账单**：按店铺 + 周期（本月/上月/自定义）汇总出货/收款/期末欠款明细，一键复制文本发送给客户或复制 CSV 粘贴到 Excel
- **结账**：收款登记（金额/日期/方式/备注），欠款 = 累计出货 − 累计收款（按店铺）
- **统计**：工作台卡片、按店（出货/收款/欠款/毛利）、按月/按日、商品出货排行、自定义区间汇总
- **分类**：商品分类 / 店铺分类，两级（一级 → 子级，一级可挂多个子分类）
- **多用户**：老板/店员两角色（店员记单查看，管理操作仅老板；**店员统计隐藏毛利**；账号管理页面管理）
- **检查更新**：App「我的 → 检查更新」由后端代查 GitHub Release 对比版本（仓库公开，国内网络可用）
- **AI 拍照识别**：拍小票/价签自动识别商品清单（OpenAI 兼容，后台自配地址/Key/模型，默认智谱免费 `glm-4v-flash`）

## 技术栈

- 后端：Cloudflare Workers + D1（SQLite）+ Hono + JWT（角色权限）
- 前端主端：Flutter（Android App / Web / Windows / iOS 一套代码）
- 微信小程序：uni-app（功能与主端逐步对齐）
- CI：GitHub Actions —— push 自动部署后端+Web、构建 APK、构建小程序，产物上传 GitHub Release

## 本地开发

```bash
# 1. 起后端（本地模拟 D1 + 静态资源）
npm install
cp .dev.vars.example .dev.vars   # 写入 JWT_SECRET（本地测试值）
npx wrangler dev

# 2. 另开终端起 Flutter 端
cd frontend-flutter
flutter pub get
flutter run -d chrome   # 或 -d <安卓设备>；App 登录页需填服务器地址
```

测试：`npm test`（后端端到端，sql.js 内存库 + 真路由）、`npm run typecheck`（后端类型检查）
前端编译验证由 CI 完成（本机可不装 Flutter：push 后触发 Actions 构建）。

## 部署（GitHub Actions 自动）

1. 创建 GitHub 仓库并推送 main
2. 设置 Actions secrets：
   - `CLOUDFLARE_API_TOKEN`（权限：Workers Scripts Edit + D1 Edit + 账户 Read）
   - `JWT_SECRET`（随机 32 字节 hex，生产登录签名密钥）
   - Android 签名相关（`ANDROID_KEYSTORE_*`）——仅构建 APK 需要
3. push main → 自动：创建/复用 D1 → 构建 Flutter Web（注入生产 API 地址）→ `wrangler deploy`
4. 首次访问 `/` → 创建老板账号

Worker 名/域名见 `wrangler.toml`（默认 `taozhu`）；D1 自动创建，无需手动建库。

## 版本管理

- 版本号**手动维护**，两处同步：`frontend-flutter/lib/version.dart` 与 `src/version.ts`（四段 x.y.z.w）
- CI 读取 `version.dart` 命名产物并创建 GitHub Release `taozhu-v<版本>`，不自动递增
- 发版流程：改两个版本文件 → push main → Actions 自动构建并发布所有端
- 规则：正式版发布前保持 `0.x` 递增；`1.0.0.0` 只在正式对外发布时启用
- Android 应用版本（versionName/versionCode）由 CI 构建时按版本号同步（`--build-name/--build-number`）

## 目录

```
src/                     后端（Hono 路由 + D1 schema + 认证 + AI）
frontend-flutter/        Flutter 主端（lib/pages 各业务页，lib/api.dart 请求封装）
frontend-uni/            微信小程序（uni-app）
tests/                   后端端到端测试（sql.js 内存库 + 真路由）
.github/workflows/       deploy（含 Web 构建与 release 上传）/ build-flutter / build-miniprogram / build-desktop-ios / build-linux
public/                  部署时由 Flutter Web 构建产物覆盖（勿手动提交）
```