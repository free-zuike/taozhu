<script setup lang="ts">
import { onLaunch, onShow, onHide } from "@dcloudio/uni-app";
import { startWs, stopWs } from "./ws";
import { getToken } from "./api";
onLaunch(() => {
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
</style>