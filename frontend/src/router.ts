/** 路由：未登录跳登录；布局子页面 */
import { createRouter, createWebHistory } from 'vue-router';
import { getToken } from './api';

const router = createRouter({
  history: createWebHistory(),
  routes: [
    { path: '/login', name: 'login', component: () => import('./views/LoginView.vue') },
    {
      path: '/',
      component: () => import('./views/Layout.vue'),
      children: [
        { path: '', redirect: '/dashboard' },
        { path: 'dashboard', name: 'dashboard', component: () => import('./views/DashboardView.vue'), meta: { title: '工作台' } },
        { path: 'items', name: 'items', component: () => import('./views/ItemsView.vue'), meta: { title: '商品管理' } },
        { path: 'clients', name: 'clients', component: () => import('./views/ClientsView.vue'), meta: { title: '饭店管理' } },
        { path: 'sale', name: 'sale', component: () => import('./views/SaleView.vue'), meta: { title: '出货记单' } },
        { path: 'purchase', name: 'purchase', component: () => import('./views/PurchaseView.vue'), meta: { title: '进货记单' } },
        { path: 'payments', name: 'payments', component: () => import('./views/PaymentsView.vue'), meta: { title: '收款结账' } },
        { path: 'stats', name: 'stats', component: () => import('./views/StatsView.vue'), meta: { title: '统计' } },
        { path: 'users', name: 'users', component: () => import('./views/UsersView.vue'), meta: { title: '账号管理', adminOnly: true } },
      ],
    },
  ],
});

router.beforeEach((to) => {
  if (to.name !== 'login' && !getToken()) return { name: 'login' };
  if (to.name === 'login' && getToken()) return { path: '/' };
  return true;
});

export default router;