#!/usr/bin/env python3
"""CI AndroidManifest 分享 intent-filter 幂等注入（②f）：
MainActivity 接收 ACTION_SEND image/*（微信/系统分享图片 → App 自动识别记账），
launchMode 统一 singleTask（分享到已运行实例走 onNewIntent）。
用 python3 全文件级处理，避免 sed 行级判断在已有 launchMode 的模板追加出重复属性导致 XML 解析失败。
用法：python3 scripts/inject-share-manifest.py <manifest路径>
"""
import re
import sys

p = sys.argv[1]
s = open(p, encoding='utf-8').read()
if 'android.intent.action.SEND' not in s:
    i = s.index('<intent-filter>')
    inj = ('<intent-filter>\n'
           '            <action android:name="android.intent.action.SEND"/>\n'
           '            <category android:name="android.intent.category.DEFAULT"/>\n'
           '            <data android:mimeType="image/*"/>\n'
           '        </intent-filter>\n'
           '        ')
    s = s[:i] + inj + s[i:]
if 'android:launchMode="singleTask"' not in s:
    if 'android:launchMode=' in s:
        s = re.sub(r'android:launchMode="[^"]*"', 'android:launchMode="singleTask"', s, count=1)
    else:
        # 兼容 Flutter 模板用 ${applicationId}.MainActivity 且无 launchMode 属性的情况：
        # 直接在 MainActivity 的 activity 标签（android:name= 之后）插入 launchMode，
        # 避免旧写法（只匹配字面 .MainActivity）在 ${applicationId}.MainActivity 时静默漏加。
        s = re.sub(r'(android:name="(?:\$\{applicationId\}\.)?MainActivity")',
                   r'\1\n            android:launchMode="singleTask"', s, count=1)
# Flutter 模板默认 android:taskAffinity=""：跨应用 NEW_TASK 拉起（微信"用其他应用打开"）时
# 会按空亲和力新建独立任务，与 singleTask 配合仍可能分裂出第二个最近任务。删掉空值改用默认包亲和，
# 确保 launcher 启动与微信分享拉起复用同一任务（单 Activity Flutter 应用改动安全）。
s = s.replace('android:taskAffinity=""', '')
open(p, 'w', encoding='utf-8').write(s)
