/**
 * 附件/凭证统一图标（图片图标 SVG data URI，主色描边——对齐 App Icons.image_outlined）。
 * 小程序无图标库：用 SVG data URI 供 <image> 渲染，与背景图案同技术路线；
 * 所有凭证入口（交易流水/进货流水/账本行）统一用此图标 + 数量徽标，不用文字/emoji。
 */
const svg =
  '<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="#409eff" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">' +
  '<rect x="3" y="3" width="18" height="18" rx="2" ry="2"/>' +
  '<circle cx="8.5" cy="8.5" r="1.5"/>' +
  '<polyline points="21 15 16 10 5 20"/></svg>';

// ASCII-only base64（小程序无 btoa）
const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
let b64 = '';
for (let i = 0; i < svg.length; i += 3) {
  const b0 = svg.charCodeAt(i);
  const b1 = i + 1 < svg.length ? svg.charCodeAt(i + 1) : NaN;
  const b2 = i + 2 < svg.length ? svg.charCodeAt(i + 2) : NaN;
  b64 += chars[b0 >> 2];
  b64 += chars[((b0 & 3) << 4) | (isNaN(b1) ? 0 : b1 >> 4)];
  b64 += isNaN(b1) ? '=' : chars[((b1 & 15) << 2) | (isNaN(b2) ? 0 : b2 >> 6)];
  b64 += isNaN(b2) ? '=' : chars[b2 & 63];
}

/** 附件图标 data URI（<image :src="attachIconSrc" />） */
export const attachIconSrc = 'data:image/svg+xml;base64,' + b64;
