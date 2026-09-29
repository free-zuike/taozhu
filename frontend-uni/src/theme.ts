/**
 * 小程序全局主题：主色持久化 + 明暗模式 + 背景图案（SVG 与 App CustomPainter 同几何：铜钱方孔/竹竿竹叶/账本表格/进销箭头/涟漪圆环）
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
    const si = uni.getSystemInfoSync() as unknown as { theme?: string };
    return si.theme === 'dark';
  } catch {
    return false;
  }
}

/** hex → rgba 字符串（SVG 描边/填充用） */
function rgba(color: string, a: number): string {
  const m = /^#([0-9a-fA-F]{6})$/.exec(color);
  if (!m) return `rgba(64,158,255,${a})`;
  const n = parseInt(m[1], 16);
  return `rgba(${(n >> 16) & 255},${(n >> 8) & 255},${n & 255},${a})`;
}

/** 确定性伪随机（Dart Random(seed) 同款 LCG 近似：seed 固定 → 每次渲染位置一致） */
function dartRand(seed: number): () => number {
  let s = (seed & 0x7fffffff) | 1;
  return () => {
    // Dart VM Random: xorshift32 变体（nextDouble = state / 2^32 近似）
    s ^= s << 13;
    s ^= s >>> 17;
    s ^= s << 5;
    return (s >>> 0) / 4294967296;
  };
}

// ── SVG 图案（与 App/Web theme.dart CustomPainter 同几何与透明度：亮=主题主色 0.14~0.26，暗=白 0.14~0.26）──
// 视口 360×640（对齐 App size.width 基准）；非 compact（全屏）形态

/** 铜钱：8 枚外圆 + 方孔（Random(11)），r=W*0.05，cy 0.08~0.9 */
function svgCoin(ink: string, ink2: string): string {
  const W = 360, H = 640;
  const rnd = dartRand(11);
  const r = W * 0.05;
  const parts: string[] = [`<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}" viewBox="0 0 ${W} ${H}">`];
  for (let i = 0; i < 8; i++) {
    const cx = rnd() * W;
    const cy = H * (0.08 + rnd() * 0.82);
    const cr = r * (0.8 + rnd() * 0.5);
    parts.push(`<circle cx="${cx.toFixed(1)}" cy="${cy.toFixed(1)}" r="${cr.toFixed(1)}" fill="none" stroke="${ink}" stroke-width="${(cr * 0.13).toFixed(1)}"/>`);
    const hole = cr * 0.34;
    parts.push(`<rect x="${(cx - hole).toFixed(1)}" y="${(cy - hole).toFixed(1)}" width="${(hole * 2).toFixed(1)}" height="${(hole * 2).toFixed(1)}" fill="none" stroke="${ink2}" stroke-width="${(cr * 0.09).toFixed(1)}"/>`);
  }
  parts.push('</svg>');
  return parts.join('');
}

/** 竹韵：4 竿竖竹 + 竹节 + 竹叶（Random(17)），叶为 quadraticBezier 叶片 */
function svgBamboo(ink: string, ink2: string): string {
  const W = 360, H = 640;
  const rnd = dartRand(17);
  const parts: string[] = [`<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}" viewBox="0 0 ${W} ${H}">`];
  for (let i = 0; i < 4; i++) {
    const x = W * (0.14 + i * 0.26 + rnd() * 0.05);
    const w = W * 0.02;
    const topY = H * (0.08 + i * 0.02);
    const h = H * (0.34 + (i % 2) * 0.2) + H * 0.2;
    // 竹竿
    parts.push(`<line x1="${x.toFixed(1)}" y1="${topY.toFixed(1)}" x2="${x.toFixed(1)}" y2="${(topY + h).toFixed(1)}" stroke="${ink}" stroke-width="${w.toFixed(1)}" stroke-linecap="round"/>`);
    // 竹节 3 道
    for (let n = 0; n < 3; n++) {
      const ny = topY + h * (0.2 + n * 0.24);
      parts.push(`<line x1="${(x - w * 0.7).toFixed(1)}" y1="${ny.toFixed(1)}" x2="${(x + w * 0.7).toFixed(1)}" y2="${ny.toFixed(1)}" stroke="${ink2}" stroke-width="${(w * 0.28).toFixed(1)}"/>`);
    }
    // 竹叶 3 片（quadraticBezier 叶形：凸背+凹腹闭合）
    for (let l = 0; l < 3; l++) {
      const lx = x + w * (0.6 + rnd() * 0.5);
      const ly = topY + h * (0.1 + rnd() * 0.8);
      const len = W * 0.035;
      const dir = rnd() < 0.5 ? 1 : -1;
      const p1x = lx + len * 0.5 * dir, p1y = ly - len * 0.5;
      const p2x = lx + len * dir, p2y = ly - len * 0.12;
      const p3x = lx + len * 0.5 * dir, p3y = ly + len * 0.18;
      parts.push(`<path d="M ${lx.toFixed(1)} ${ly.toFixed(1)} Q ${p1x.toFixed(1)} ${p1y.toFixed(1)} ${p2x.toFixed(1)} ${p2y.toFixed(1)} Q ${p3x.toFixed(1)} ${p3y.toFixed(1)} ${lx.toFixed(1)} ${ly.toFixed(1)} Z" fill="${ink2}"/>`);
    }
  }
  parts.push('</svg>');
  return parts.join('');
}

/** 账本：3 本账本轮廓 + 表头 + 3 行账目线 + 中竖线 */
function svgLedger(ink: string, ink2: string): string {
  const W = 360, H = 640;
  const parts: string[] = [`<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}" viewBox="0 0 ${W} ${H}">`];
  for (let i = 0; i < 3; i++) {
    const cx = W * 0.5;
    const cy = H * (0.16 + i * 0.3);
    const w = W * 0.34;
    const h = w * 0.4;
    const rx = w * 0.04;
    // 账本框
    parts.push(`<rect x="${(cx - w / 2).toFixed(1)}" y="${(cy - h / 2).toFixed(1)}" width="${w.toFixed(1)}" height="${h.toFixed(1)}" rx="${rx.toFixed(1)}" fill="none" stroke="${ink}" stroke-width="${(W * 0.009).toFixed(2)}"/>`);
    // 表头线
    parts.push(`<line x1="${(cx - w * 0.3).toFixed(1)}" y1="${(cy - h * 0.3).toFixed(1)}" x2="${(cx + w * 0.3).toFixed(1)}" y2="${(cy - h * 0.3).toFixed(1)}" stroke="${ink2}" stroke-width="${(W * 0.007).toFixed(2)}"/>`);
    // 3 行账目线
    for (let r = 0; r < 3; r++) {
      const y = cy - h * 0.08 + r * h * 0.2;
      parts.push(`<line x1="${(cx - w * 0.34).toFixed(1)}" y1="${y.toFixed(1)}" x2="${(cx + w * 0.34).toFixed(1)}" y2="${y.toFixed(1)}" stroke="${ink2}" stroke-width="${(W * 0.007).toFixed(2)}"/>`);
    }
    // 中竖线
    parts.push(`<line x1="${(cx + w * 0.2).toFixed(1)}" y1="${(cy - h * 0.42).toFixed(1)}" x2="${(cx + w * 0.2).toFixed(1)}" y2="${(cy + h * 0.42).toFixed(1)}" stroke="${ink2}" stroke-width="${(W * 0.007).toFixed(2)}"/>`);
  }
  parts.push('</svg>');
  return parts.join('');
}

/** 进销：3 条进出双向箭头曲线 */
function svgFlow(ink: string, ink2: string): string {
  const W = 360, H = 640;
  const parts: string[] = [`<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}" viewBox="0 0 ${W} ${H}">`];
  const curves = 3;
  for (let cIdx = 0; cIdx < curves; cIdx++) {
    const cy = H * (0.2 + cIdx * 0.3);
    const amp = H * (0.1 + cIdx * 0.02);
    const strokeW = W * 0.02;
    // S 曲线（cubic）
    parts.push(`<path d="M ${(W * 0.08).toFixed(1)} ${cy.toFixed(1)} C ${(W * 0.35).toFixed(1)} ${(cy - amp).toFixed(1)}, ${(W * 0.65).toFixed(1)} ${(cy + amp).toFixed(1)}, ${(W * 0.92).toFixed(1)} ${cy.toFixed(1)}" fill="none" stroke="${ink}" stroke-width="${strokeW.toFixed(1)}" stroke-linecap="round"/>`);
    const len = W * 0.035;
    // 右箭头（angle 0）
    const tipR = W * 0.92, tipRY = cy;
    parts.push(`<line x1="${tipR.toFixed(1)}" y1="${tipRY.toFixed(1)}" x2="${(tipR - len * 0.9 * Math.cos(0.32)).toFixed(1)}" y2="${(tipRY - len * 0.9 * Math.sin(0.32)).toFixed(1)}" stroke="${ink}" stroke-width="${strokeW.toFixed(1)}" stroke-linecap="round"/>
<line x1="${tipR.toFixed(1)}" y1="${tipRY.toFixed(1)}" x2="${(tipR - len * 0.9 * Math.cos(-0.32)).toFixed(1)}" y2="${(tipRY - len * 0.9 * Math.sin(-0.32)).toFixed(1)}" stroke="${ink}" stroke-width="${strokeW.toFixed(1)}" stroke-linecap="round"/>`);
    // 左箭头（angle pi）
    const tipL = W * 0.08, tipLY = cy;
    parts.push(`<line x1="${tipL.toFixed(1)}" y1="${tipLY.toFixed(1)}" x2="${(tipL - len * 0.9 * Math.cos(Math.PI - 0.32)).toFixed(1)}" y2="${(tipLY - len * 0.9 * Math.sin(Math.PI - 0.32)).toFixed(1)}" stroke="${ink2}" stroke-width="${strokeW.toFixed(1)}" stroke-linecap="round"/>
<line x1="${tipL.toFixed(1)}" y1="${tipLY.toFixed(1)}" x2="${(tipL - len * 0.9 * Math.cos(Math.PI + 0.32)).toFixed(1)}" y2="${(tipLY - len * 0.9 * Math.sin(Math.PI + 0.32)).toFixed(1)}" stroke="${ink2}" stroke-width="${strokeW.toFixed(1)}" stroke-linecap="round"/>`);
  }
  parts.push('</svg>');
  return parts.join('');
}

/** 涟漪：5 组同心圆环（3 环，透明度递减） */
function svgRipple(ink: string, ink2: string): string {
  const W = 360, H = 640;
  const rnd = dartRand(29);
  const parts: string[] = [`<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}" viewBox="0 0 ${W} ${H}">`];
  const groups = 5;
  for (let g = 0; g < groups; g++) {
    const cx = W * (0.22 + (g % 2) * 0.3 + rnd() * 0.1);
    const cy = H * (0.14 + g * 0.18 + rnd() * 0.05);
    const baseR = W * 0.036;
    for (let ring = 0; ring < 3; ring++) {
      const r = baseR * (1 + ring * 0.9);
      const col = ring === 0 ? ink : ink2;
      parts.push(`<circle cx="${cx.toFixed(1)}" cy="${cy.toFixed(1)}" r="${r.toFixed(1)}" fill="none" stroke="${col}" stroke-width="${(W * 0.006).toFixed(2)}"/>`);
    }
  }
  parts.push('</svg>');
  return parts.join('');
}

/** 背景图案 SVG data URI（与 App/Web CustomPainter 同几何；图案色随主题主色）
 *  返回 base64 data URI 供 <image> 组件 src 使用——微信小程序 WXSS background 不渲染 SVG data URI
 *  （显示白屏），必须用 image 组件铺背景层。 */
function skinSvgSrc(skin: string, click: { ink: string; ink2: string }): string {
  const { ink, ink2 } = click;
  let svg = '';
  switch (skin) {
    case 'coin': svg = svgCoin(ink, ink2); break;
    case 'bamboo': svg = svgBamboo(ink, ink2); break;
    case 'ledger': svg = svgLedger(ink, ink2); break;
    case 'flow': svg = svgFlow(ink, ink2); break;
    case 'ripple': svg = svgRipple(ink, ink2); break;
    default: return '';
  }
  // 小程序 btoa/TextEncoder 可能缺失：自实现 base64（UTF-8 安全），image 组件 src 直接用
  return 'data:image/svg+xml;base64,' + utf8ToBase64(svg);
}
function utf8ToBase64(s: string): string {
  // UTF-8 编码（手写，不依赖 TextEncoder）
  const bytes: number[] = [];
  for (let i = 0; i < s.length; i++) {
    const c = s.charCodeAt(i);
    if (c < 0x80) bytes.push(c);
    else if (c < 0x800) bytes.push(0xc0 | (c >> 6), 0x80 | (c & 0x3f));
    else bytes.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 0x3f), 0x80 | (c & 0x3f));
  }
  // base64（手写，不依赖 btoa）
  const b64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  let out = '';
  for (let i = 0; i < bytes.length; i += 3) {
    const b0 = bytes[i];
    const b1 = i + 1 < bytes.length ? bytes[i + 1] : -1;
    const b2 = i + 2 < bytes.length ? bytes[i + 2] : -1;
    out += b64[b0 >> 2];
    out += b64[((b0 & 3) << 4) | (b1 < 0 ? 0 : b1 >> 4)];
    out += b1 < 0 ? '=' : b64[((b1 & 15) << 2) | (b2 < 0 ? 0 : b2 >> 6)];
    out += b2 < 0 ? '=' : b64[b2 & 63];
  }
  return out;
}

/** 背景图案迷你预览（设置页缩略图）：与全屏同几何，色用主题主色高对比（对齐 App compact 预览） */
export function skinPreviewCss(skin: string, primary: string): string {
  if (skin === '') return 'linear-gradient(180deg, rgba(64,158,255,0.10), rgba(64,158,255,0.02))';
  if (skin === 'none') return '#f5f7fa';
  const ink = rgba(primary, 0.55);
  const ink2 = rgba(primary, 0.32);
  const uri = skinSvgSrc(skin, { ink, ink2 });
  return uri ? `url("${uri}") center / cover no-repeat, #ffffff` : '#f5f7fa';
}

/** 页面背景：渐变底色（CSS 渲染，小程序支持）+ SVG 图案（image 组件铺层，base64 兼容）
 *  返回 { patternSrc: 图案 image src（''=无图案）, gradientCss: 渐变底 } */
function pageBackgroundVars(primary: string, dark: boolean, skin: string): { patternSrc: string; gradientCss: string } {
  const ink = dark ? 'rgba(255,255,255,0.24)' : rgba(primary, 0.22);
  const ink2 = dark ? 'rgba(255,255,255,0.15)' : rgba(primary, 0.14);
  const baseTop = dark ? '#181b22' : alpha(primary, '14');
  const baseBottom = dark ? '#12151c' : '#f5f7fa';
  const gradient = `linear-gradient(180deg, ${baseTop} 0%, ${baseBottom} 60%)`;
  if (skin === 'none') return { patternSrc: '', gradientCss: gradient };
  return { patternSrc: skinSvgSrc(skin, { ink, ink2 }), gradientCss: gradient };
}

/**
 * 页面主题变量：根 view :style 绑定（主题色/明暗变量/渐变底色）+ 背景图案 image src。
 *  patternSrc：背景图案 base64 SVG（''=无图案），供页面 <image class="bg-pattern"> 铺底使用。
 */
export function useThemeVars() {
  const vars = ref<Record<string, string>>({ '--primary': defaultPrimary, '--page-bg': '#f5f7fa', '--card-bg': '#ffffff' });
  const patternSrc = ref('');
  const load = () => {
    try {
      const primary = getThemePrimary();
      const dark = isDark();
      const skin = getThemeSkin();
      const cardBg = dark ? '#232833' : '#ffffff';
      const textMain = dark ? '#e8eaf1' : '#303133';
      const textSub = dark ? '#9aa2b3' : '#909399';
      const divider = dark ? '#2e3440' : '#f0f2f5';
      const inputBg = dark ? '#2a303c' : '#f5f7fa';
      const bg = pageBackgroundVars(primary, dark, skin);
      patternSrc.value = bg.patternSrc;
      vars.value = {
        '--primary': primary,
        '--primary-soft': alpha(primary, '1F'),
        '--primary-fade': alpha(primary, '14'),
        // 页面 CSS 背景只用渐变（小程序 WXSS 支持；SVG 图案由 image 组件铺层，不依赖 CSS data URI）
        '--page-bg': bg.gradientCss,
        '--card-bg': cardBg,
        '--text-main': textMain,
        '--text-sub': textSub,
        '--divider': divider,
        '--input-bg': inputBg,
        // 语义浅底（成功/警告/危险/紫强调）：亮暗通用半透明，深色下协调不刺眼
        '--ok-bg': 'rgba(34,197,94,0.14)',
        '--warn-bg': 'rgba(230,162,60,0.14)',
        '--danger-bg': 'rgba(245,108,108,0.14)',
        '--violet-bg': 'rgba(124,77,255,0.12)',
      };
      applyTabBar(dark, primary);
    } catch (e) {
      // 主题渲染任何异常都不中断页面 setup（历史上 TextEncoder/btoa 缺失曾致整页 CSS 变量全空）
      // eslint-disable-next-line no-console
      console.warn('[theme] load 异常（保持默认变量）', e);
    }
  };
  load();
  onShow(load);
  return { tv: vars, patternSrc, refresh: load };
}

/** tabBar 深色适配：微信原生 tabBar 不随页面 CSS 变量，主题加载/切换时动态设置底部栏配色 */
function applyTabBar(dark: boolean, primary: string) {
  try {
    uni.setTabBarStyle({
      color: dark ? '#9aa2b3' : '#909399',
      selectedColor: primary,
      backgroundColor: dark ? '#181b22' : '#ffffff',
      borderStyle: dark ? 'black' : 'white',
    });
  } catch (_) {}
}