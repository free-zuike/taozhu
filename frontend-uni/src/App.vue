<script setup lang="ts">
import { onLaunch, onShow, onHide } from "@dcloudio/uni-app";
import { startWs, stopWs } from "./ws";
import { getToken } from "./api";
import { MATERIAL_ICONS_BASE64 } from "./static/fonts/material-icons-base64";
// 加载 Material Icons 字体（与 App 端同款字体，码点一致——小程序图标与 App 完全一致）。
// 微信小程序 loadFontFace 不支持本地文件路径（只支持网络 URL 或 base64），
// 故用 base64 内联（约 167KB）；H5 端走 @font-face 本地路径。
function loadIconFont() {
  // @ts-expect-error 各平台 loadFontFace 挂载点（uni/wx/tt/qq…）
  const api = typeof wx !== 'undefined' ? wx : (typeof uni !== 'undefined' ? uni : null);
  if (api?.loadFontFace) {
    api.loadFontFace({
      family: 'MaterialIcons',
      source: MATERIAL_ICONS_BASE64,
      global: true,
      fail: () => {},
    });
  }
}
onLaunch(() => {
  loadIconFont();
  // 已登录则启动实时同步（其他端删除/修改 → WS 通知 → 当前页自动刷新）
  if (getToken()) startWs();
});
onShow(() => {
  // 前台恢复：未连接则重连
  if (getToken()) startWs();
});
onHide(() => {
  stopWs();
});
</script>
<style>
/* 全局：页面根 view 建 stacking context——背景图案层 .bg-pattern 用 z-index:-1，
   若不隔离会被压到 page 宿主之下；微信 darkmode 声明后 page 默认背景变黑，
   负 z 图案会被黑底盖住（暗色模式"背景变纯黑"根因）。position:relative+z-index:0
   让 -1 图案稳定显示在页面渐变之上、内容之下。 */
.page {
  position: relative;
  z-index: 0;
}

/* Material Icons（与 App 端同款字体/码点）：图标一致铁律——
   页面内图标统一用 <text class="mi">（unicode 码点），H5 端走 @font-face，小程序端 wx.loadFontFace */
@font-face {
  font-family: 'MaterialIcons';
  src: url('/static/fonts/MaterialIcons-Regular.woff2') format('woff2');
  font-weight: normal;
  font-style: normal;
}
.mi {
  font-family: 'MaterialIcons';
  font-weight: normal;
  font-style: normal;
  font-size: 32rpx;
  line-height: 1;
  display: inline-block;
  -webkit-font-smoothing: antialiased;
  /* 图标线条=主题主色（对齐 App：图标与设置的颜色一致，线条深色、背景浅底；
     个别需要其他色的位置用更具体的类覆盖） */
  color: var(--primary);
}
</style>