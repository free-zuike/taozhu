/**
 * 小程序全局主题：主色持久化 + 明暗模式 + 背景图案 + 页面根 view 绑定 CSS 变量。
 * 主题设置页保存后写 storage（taozhu_theme_primary / taozhu_theme_mode / taozhu_theme_skin），
 * 各页面 onShow 读取并应用。
 */
import { ref } from 'vue';
import { onShow } from '@dcloudio/uni-app';

const PRIMARY_KEY = 'taozhu_theme_primary';
const MODE_KEY = 'taozhu_theme_mode';
const SKIN_KEY = 'taozhu_theme_skin';
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

/** 背景图案 id（''=渐变 / 'none'=纯色 / coin|bamboo|ledger|flow|ripple，对齐 App/Web） */
export function getThemeSkin(): string {
  return (uni.getStorageSync(SKIN_KEY) as string) || '';
}

export function setThemeSkin(id: string) {
  uni.setStorageSync(SKIN_KEY, id);
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
 * 页面背景 CSS（按图案 id 生成；小程序无 CustomPainter，用 CSS 渐变/圆点模拟图案，
 * 图案颜色跟随主题主色 --primary 派生）。
 * skinId: ''=渐变 / 'none'=纯色 / coin 铜钱·圆环 / bamboo 竹韵·竖条 / ledger 账本·网格
 *        / flow 进销·斜浪 / ripple 涟漪·同心圆
 */
function pageBackgroundCss(primary: string, dark: boolean, skin: string): string {
  const ink = dark ? 'rgba(255,255,255,0.16)' : alpha(primary, '26'); // 图案墨色（主题色 15%）
  const ink2 = dark ? 'rgba(255,255,255,0.1)' : alpha(primary, '18');
  const baseTop = dark ? '#181b22' : alpha(primary, '14');
  const baseBottom = dark ? '#12151c' : '#f5f7fa';
  switch (skin) {
    case 'none':
      return dark ? 'linear-gradient(180deg, #181b22, #12151c)' : `linear-gradient(180deg, ${alpha(primary, '14')} 0%, #f5f7fa 34%)`;
    case 'coin':
      return `radial-gradient(circle at 18% 15%, transparent 0 9rpx, ${ink} 9rpx 13rpx, transparent 13rpx 17rpx, ${ink2} 17rpx 19rpx, transparent 19rpx),
        radial-gradient(circle at 72% 28%, transparent 0 7rpx, ${ink} 7rpx 10rpx, transparent 10rpx 13rpx, ${ink2} 13rpx 15rpx, transparent 15rpx),
        radial-gradient(circle at 42% 55%, transparent 0 11rpx, ${ink} 11rpx 16rpx, transparent 16rpx 20rpx, ${ink2} 20rpx 22rpx, transparent 22rpx),
        radial-gradient(circle at 82% 72%, transparent 0 6rpx, ${ink} 6rpx 9rpx, transparent 9rpx 12rpx, ${ink2} 12rpx 14rpx, transparent 14rpx),
        linear-gradient(180deg, ${baseTop} 0%, ${baseBottom} 60%)`;
    case 'bamboo':
      return `linear-gradient(90deg, transparent 0 17%, ${ink} 17% 19%, transparent 19% 38%, ${ink2} 38% 39.5%, transparent 39.5% 62%, ${ink} 62% 64%, transparent 64% 82%, ${ink2} 82% 83.5%, transparent 83.5%),
        linear-gradient(180deg, ${baseTop} 0%, ${baseBottom} 60%)`;
    case 'ledger':
      return `linear-gradient(0deg, transparent 0 12%, ${ink2} 12% 12.8%, transparent 12.8% 30%, ${ink2} 30% 30.8%, transparent 30.8% 48%, ${ink2} 48% 48.8%, transparent 48.8% 70%, ${ink2} 70% 70.8%, transparent 70.8%),
        linear-gradient(90deg, transparent 0 22%, ${ink} 22% 23%, transparent 23% 78%, ${ink} 78% 79%, transparent 79%),
        linear-gradient(180deg, ${baseTop} 0%, ${baseBottom} 60%)`;
    case 'flow':
      return `linear-gradient(135deg, transparent 0 44%, ${ink2} 44% 46%, transparent 46% 56%, ${ink2} 56% 58%, transparent 58%),
        linear-gradient(315deg, transparent 0 44%, ${ink} 44% 46%, transparent 46% 56%, ${ink} 56% 58%, transparent 58%),
        linear-gradient(180deg, ${baseTop} 0%, ${baseBottom} 60%)`;
    case 'ripple':
      return `radial-gradient(circle at 30% 25%, transparent 0 12rpx, ${ink} 12rpx 17rpx, transparent 17rpx 24rpx, ${ink2} 24rpx 28rpx, transparent 28rpx 34rpx, ${ink} 34rpx 38rpx, transparent 38rpx),
        radial-gradient(circle at 72% 62%, transparent 0 8rpx, ${ink2} 8rpx 12rpx, transparent 12rpx 18rpx, ${ink} 18rpx 22rpx, transparent 22rpx 27rpx, ${ink2} 27rpx 30rpx, transparent 30rpx),
        radial-gradient(circle at 15% 78%, transparent 0 6rpx, ${ink} 6rpx 9rpx, transparent 9rpx 13rpx, ${ink2} 13rpx 16rpx, transparent 16rpx),
        linear-gradient(180deg, ${baseTop} 0%, ${baseBottom} 60%)`;
    default:
      return `linear-gradient(180deg, ${baseTop} 0%, ${baseBottom} 60%)`;
  }
}

/**
 * 页面根 view :style 绑定：提供主题色、明暗变量与页面背景（按所选图案）。
 * --primary / --primary-soft(12% 装饰) / --primary-fade(8% 渐变顶)
 * --page-bg（完整背景 CSS，含图案层）/ --card-bg / --text-main / --text-sub / --divider / --input-bg
 */
export function useThemeVars() {
  const vars = ref<Record<string, string>>({ '--primary': defaultPrimary, '--page-bg': '#f5f7fa', '--card-bg': '#ffffff' });
  const load = () => {
    const primary = getThemePrimary();
    const dark = isDark();
    const skin = getThemeSkin();
    const cardBg = dark ? '#232833' : '#ffffff';
    const textMain = dark ? '#e8eaf1' : '#303133';
    const textSub = dark ? '#9aa2b3' : '#909399';
    const divider = dark ? '#2e3440' : '#f0f2f5';
    const inputBg = dark ? '#2a303c' : '#f5f7fa';
    vars.value = {
      '--primary': primary,
      '--primary-soft': alpha(primary, '1F'), // 12%（hex alpha ~1F）
      '--primary-fade': alpha(primary, '14'), // 8%
      '--page-bg': pageBackgroundCss(primary, dark, skin),
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