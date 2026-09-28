/**
 * 小程序全局主题：主色持久化 + 页面根 view 绑定 CSS 变量。
 * 主题设置页保存后写 storage（taozhu_theme_primary），各页面 onShow 读取并应用。
 */
import { ref } from 'vue';
import { onShow } from '@dcloudio/uni-app';

const PRIMARY_KEY = 'taozhu_theme_primary';
export const defaultPrimary = '#409EFF';

/** 主题色（hex）→ 半透明后缀色（hex8，供浅底/装饰使用） */
function alpha(color: string, a: string): string {
  return /^#[0-9a-fA-F]{6}$/.test(color) ? `${color}${a}` : color;
}

export function getThemePrimary(): string {
  return (uni.getStorageSync(PRIMARY_KEY) as string) || defaultPrimary;
}

export function setThemePrimary(color: string) {
  uni.setStorageSync(PRIMARY_KEY, color);
}

/** 页面根 view :style 绑定：提供 --primary / --primary-soft（主色 12% 装饰）/ --primary-fade（主色 8% 背景渐变）*/
export function useThemeVars() {
  const vars = ref<Record<string, string>>({ '--primary': defaultPrimary });
  const load = () => {
    const primary = getThemePrimary();
    vars.value = {
      '--primary': primary,
      '--primary-soft': alpha(primary, '1F'), // 12%（hex alpha ~1F）
      '--primary-fade': alpha(primary, '14'), // 8%
    };
  };
  load();
  onShow(load);
  return vars;
}