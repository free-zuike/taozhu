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
        s = s.replace('android:name=".MainActivity"',
                      'android:name=".MainActivity"\n            android:launchMode="singleTask"')
open(p, 'w', encoding='utf-8').write(s)
