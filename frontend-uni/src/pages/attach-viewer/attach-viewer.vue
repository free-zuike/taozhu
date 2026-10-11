<template>
  <view class="viewer" @click.stop>
    <!-- 有图：swiper 大图 -->
    <swiper v-if="list.length > 0" class="viewer-swiper" :current="index" @change="onViewerChange">
      <swiper-item v-for="a in list" :key="a.key">
        <image class="viewer-img" :src="attachmentUrl(a.key)" mode="aspectFit" @click.stop />
      </swiper-item>
    </swiper>
    <!-- 无图：全屏空态（可添加） -->
    <view v-else class="viewer-empty">
      <text class="viewer-empty-tx">暂无凭证，点上方「添加」上传</text>
    </view>
    <view class="viewer-top">
      <text class="viewer-close" @click="closeAttach">✕</text>
      <text class="viewer-count">{{ list.length > 0 ? index + 1 + '/' + list.length : '' }}</text>
      <view class="viewer-ops">
        <text class="viewer-op" @click="uploadAttach">添加</text>
        <text v-if="list.length > 0" class="viewer-op" @click="downloadAttach">下载</text>
        <text v-if="list.length > 0" class="viewer-op viewer-op-del" @click="removeAttach(list[index].key)">删除</text>
      </view>
    </view>
  </view>
</template>

<script setup lang="ts">
/**
 * 独立附件查看器（对齐 App attachment_viewer）：账本/记单/进货历史点凭证 → navigateTo 本页。
 * 独立子页面保证安卓返回键/全面屏侧滑手势只会 pop 本页回到原页面，不会退出小程序
 * （此前页内全屏遮罩在 tabBar 根页上手势返回直接退出小程序——onBackPress 拦不住侧滑手势）。
 * 参数：entity,id（行级/单据级实体）+ 可选 fbEntity,fbId（行级空时回退单据级）。
 */
import { ref } from 'vue';
import { onLoad, onUnload } from '@dcloudio/uni-app';
import { request, getAttachments, uploadAttachment, deleteAttachment, attachmentUrl } from '../../api';
import { attachIconSrc } from '../../attach-icon';

const list = ref<Array<{ key: string }>>([]);
const index = ref(0);
const entity = ref('');
const id = ref('');
const fbEntity = ref('');
const fbId = ref('');

onLoad(async (options) => {
  entity.value = String(options?.entity || '');
  id.value = String(options?.id || '');
  fbEntity.value = String(options?.fbEntity || '');
  fbId.value = String(options?.fbId || '');
  await load();
});

const confirm = (title: string, content: string) =>
  new Promise<boolean>((resolve) => {
    uni.showModal({ title, content, success: (r) => resolve(!!r.confirm) });
  });

async function load() {
  let rows: Array<{ key: string }> = [];
  try {
    const d = await getAttachments(entity.value, id.value);
    rows = d.attachments || [];
  } catch (_) {}
  if (rows.length === 0 && fbEntity.value && fbId.value) {
    try {
      const d = await getAttachments(fbEntity.value, fbId.value);
      rows = d.attachments || [];
    } catch (_) {}
  }
  list.value = rows;
}

function closeAttach() {
  uni.navigateBack({});
}

function onViewerChange(e: { detail: { current: number } }) {
  index.value = e.detail.current;
}

function uploadAttach() {
  uni.chooseImage({
    count: 1,
    sourceType: ['camera', 'album'],
    success: async (res) => {
      const path = res.tempFilePaths?.[0];
      if (!path) return;
      try {
        const d = await uploadAttachment(entity.value, id.value, path);
        list.value.push({ key: d.key });
        uni.showToast({ title: '已添加', icon: 'success' });
        notifyChanged();
      } catch (e) {
        uni.showToast({ title: (e as Error).message || '上传失败', icon: 'none' });
      }
    },
  });
}

function downloadAttach() {
  const it = list.value[index.value];
  if (!it) return;
  uni.showLoading({ title: '下载中…' });
  uni.downloadFile({
    url: attachmentUrl(it.key),
    success(res) {
      if (res.statusCode !== 200) {
        uni.hideLoading();
        uni.showToast({ title: '下载失败', icon: 'none' });
        return;
      }
      uni.saveImageToPhotosAlbum({
        filePath: res.tempFilePath,
        success() {
          uni.hideLoading();
          uni.showToast({ title: '已保存到相册', icon: 'success' });
        },
        fail(e) {
          uni.hideLoading();
          uni.showToast({ title: e.errMsg?.includes('auth') ? '需要相册权限' : '保存失败', icon: 'none' });
        },
      });
    },
    fail() {
      uni.hideLoading();
      uni.showToast({ title: '下载失败', icon: 'none' });
    },
  });
}

async function removeAttach(key: string) {
  if (!(await confirm('删除凭证', '确定删除这张凭证图片吗？'))) return;
  try {
    await deleteAttachment(key);
    const idx = list.value.findIndex((a) => a.key === key);
    list.value = list.value.filter((a) => a.key !== key);
    if (idx >= 0 && index.value >= idx && index.value > 0) index.value -= 1;
    uni.showToast({ title: '已删除', icon: 'success' });
    notifyChanged();
  } catch (e) {
    uni.showToast({ title: (e as Error).message || '删除失败', icon: 'none' });
  }
}

// 变更后通知原页刷新附件计数（navigateBack 时原页 onShow 已触发 WS/重载；显式事件双保险）
let _notify: () => void = () => {};
function notifyChanged() {
  try {
    uni.$emit('attach-changed', {});
    _notify();
  } catch (_) {}
}

onUnload(() => {
  try { uni.$off('attach-changed'); } catch (_) {}
});
</script>

<style>
.viewer { position: fixed; left: 0; right: 0; top: 0; bottom: 0; background: #000; display: flex; flex-direction: column; z-index: 999; }
.viewer-swiper { flex: 1; width: 100%; }
.viewer-img { width: 100%; height: 100%; }
.viewer-top { position: absolute; left: 0; right: 0; top: 0; display: flex; align-items: center; justify-content: space-between; padding: 24rpx 28rpx; background: linear-gradient(rgba(0,0,0,0.5), transparent); box-sizing: border-box; }
.viewer-close { color: #fff; font-size: 40rpx; line-height: 1; padding: 8rpx; }
.viewer-count { color: rgba(255,255,255,0.85); font-size: 26rpx; }
.viewer-ops { display: flex; gap: 28rpx; }
.viewer-op { color: #fff; font-size: 28rpx; background: rgba(255,255,255,0.18); border-radius: 28rpx; padding: 10rpx 26rpx; }
.viewer-op-del { color: #ff6d6d; }
.viewer-empty { flex: 1; display: flex; align-items: center; justify-content: center; }
.viewer-empty-tx { color: rgba(255,255,255,0.7); font-size: 28rpx; }
</style>
