<template>
  <el-container class="layout">
    <el-aside width="200px" class="aside">
      <div class="brand">陶朱</div>
      <el-menu :default-active="$route.path" router class="menu">
        <el-menu-item index="/dashboard"><el-icon><Odometer /></el-icon>工作台</el-menu-item>
        <el-menu-item index="/sale"><el-icon><ShoppingCart /></el-icon>出货记单</el-menu-item>
        <el-menu-item index="/purchase"><el-icon><Box /></el-icon>进货记单</el-menu-item>
        <el-menu-item index="/items"><el-icon><Goods /></el-icon>商品管理</el-menu-item>
        <el-menu-item index="/clients"><el-icon><Shop /></el-icon>饭店管理</el-menu-item>
        <el-menu-item index="/payments"><el-icon><Wallet /></el-icon>收款结账</el-menu-item>
        <el-menu-item index="/stats"><el-icon><TrendCharts /></el-icon>统计</el-menu-item>
        <el-menu-item v-if="auth.isAdmin" index="/users"><el-icon><User /></el-icon>账号管理</el-menu-item>
        <el-menu-item v-if="auth.isAdmin" index="/settings"><el-icon><Setting /></el-icon>系统设置</el-menu-item>
      </el-menu>
    </el-aside>
    <el-container>
      <el-header class="header">
        <span class="page-title">{{ $route.meta.title }}</span>
        <el-dropdown @command="onCommand">
          <span class="user-name">{{ auth.user?.username }}<el-icon><ArrowDown /></el-icon></span>
          <template #dropdown>
            <el-dropdown-menu>
              <el-dropdown-item command="logout">退出登录</el-dropdown-item>
            </el-dropdown-menu>
          </template>
        </el-dropdown>
      </el-header>
      <el-main class="main">
        <router-view />
      </el-main>
    </el-container>
  </el-container>
</template>

<script setup lang="ts">
import { useAuthStore } from '../stores/auth';

const auth = useAuthStore();

function onCommand(cmd: string) {
  if (cmd === 'logout') auth.logout();
}
</script>

<style scoped>
.layout {
  height: 100vh;
  width: 100%;
}
.aside {
  background: #1f2d3d;
  flex-shrink: 0;
}
.brand {
  color: #fff;
  font-size: 18px;
  font-weight: 600;
  text-align: center;
  line-height: 60px;
  background: #18232f;
}
.menu {
  border-right: none;
  background: transparent;
  --el-menu-text-color: #c0c4cc;
  --el-menu-hover-bg-color: #263445;
  --el-menu-active-color: #67c23a;
}
.menu :deep(.el-menu-item.is-active) {
  background: #263445;
}
.header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  border-bottom: 1px solid #e4e7ed;
  background: #fff;
}
.page-title {
  font-size: 16px;
  font-weight: 600;
}
.user-name {
  display: inline-flex;
  align-items: center;
  gap: 4px;
  cursor: pointer;
  color: #303133;
}
.main {
  background: #f5f7fa;
  /* flex 子项默认 min-width:auto，内容最小宽度会撑塌窄屏布局——置 0 让右侧正确占满剩余宽度 */
  min-width: 0;
  overflow-x: auto;
}
</style>