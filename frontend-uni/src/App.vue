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
<style></style>