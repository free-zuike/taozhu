import { defineConfig } from 'vite';
import vue from '@vitejs/plugin-vue';

export default defineConfig({
  plugins: [vue()],
  // 相对路径资源引用：Web 同源与 Capacitor App（file:// 加载）都能找到 /assets
  base: './',
  build: {
    outDir: '../public', // Workers assets 静态托管目录（同源）
    emptyOutDir: true,
  },
  server: {
    port: 5173,
    proxy: {
      '/api': 'http://127.0.0.1:8787', // 本地联调：前端 dev → wrangler dev
    },
  },
});