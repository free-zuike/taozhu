/**
 * 小程序全局主题：主色持久化 + 明暗模式 + 页面根 view 绑定 CSS 变量。
 * 主题设置页保存后写 storage（taozhu_theme_primary / taozhu_theme_mode），各页面 onShow 读取并应用。
 */
import { ref } from 'vue';
import { onShow } from '@dcloudio/uni-app';

const PRIMARY_KEY = 'taozhu_theme_primary';
const MODE_KEY = 'taozhu_theme_mode';
export const defaultPrimary = '#409EFF';

/** 明暗模式：follow=跟随系统 / light=浅色 / dark=深色（对齐 App 的主题明暗设置） */
export type ThemeMode = 'follow' | 'light' | 'dark';

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

export function getThemeMode(): ThemeMode {
  const m = (uni.getStorageSync(MODE_KEY) as string) || 'follow';
  return m === 'light' || m === 'dark' ? m : 'follow';
}

export function setThemeMode(m: ThemeMode) {
  uni.setStorageSync(MODE_KEY, m);
}

/** 当前是否深色：显式 dark 优先；follow 时随系统（小程序端 systemInfo theme；Web fallback false） */
export function isDark(): boolean {
  const m = getThemeMode();
  if (m === 'dark') return true;
  if (m === 'light') return false;
  try {
    // 微信小程序：系统深色模式（基础库 2.11.0+）
    const si = uni.getSystemInfoSync() as Record<string, unknown>;
    return si.theme === 'dark';
  } catch {
    return false;
  }
}

/**
 * 页面根 view :style 绑定：提供主题色与明暗变量。
 * --primary / --primary-soft(12% 装饰) / --primary-fade(8% 渐变顶)
 * --page-bg / --card-bg / --text-main / --text-sub / --divider / --input-bg（深色适配）
 */
export function useThemeVars() {
  const vars = ref<Record<string, string>>({ '--primary': defaultPrimary, '--page-bg': '#f5f7fa', '--card-bg': '#ffffff' });
  const load = () => {
    const primary = getThemePrimary();
    const dark = isDark();
    const pageBg = dark ? '#181b22' : '#f5f7fa';
    const cardBg = dark ? '#232833' : '#ffffff';
    const textMain = dark ? '#e8eaf1' : '#303133';
    const textSub = dark ? '#9aa2b3' : '#909399';
    const divider = dark ? '#2e3440' : '#f0f2f5';
    const inputBg = dark ? '#2a303c' : '#f5f7fa';
    vars.value = {
      '--primary': primary,
      '--primary-soft': alpha(primary, '1F'), // 12%（hex alpha ~1F）
      '--primary-fade': alpha(primary, '14'), // 8%
      '--page-bg': pageBg,
      '--card-bg': cardBg,
      '--text-main': textMain,
      '--text-sub': textSub,
      '--divider': divider,
      '--input-bg': inputBg,
    };
  };
  load();
  onShow(load);
  return vars;
}