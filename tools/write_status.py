import io, os, glob, subprocess

rel = r'D:\GlassesLink\releases'
rows = []
for p in sorted(glob.glob(os.path.join(rel, '*.ipa'))):
    rows.append((os.path.basename(p), os.path.getsize(p)))

lines = []
lines.append('# 现在到哪了（2026-11-24）\n')
lines.append('## 一句话\n')
lines.append('协议已经从零写到能跑：iPhone 和眼镜之间的加密链路（LE L2CAP + AirShield）在真机上**建立成功过**，'
             '拍照、相册、设置、状态、取景、助手这些功能都写完了；**唯一没验证的一步是"成为主人"（trust）**，'
             '它需要你在同一房间里让眼镜进配对模式、点一次连接，然后把诊断包发回来。\n')

lines.append('## 已经证明的事（有证据，不是推测）\n')
lines.append('| 事项 | 证据 |')
lines.append('|---|---|')
lines.append('| 手机能对眼镜开 L2CAP 通道（PSM 0x80） | 真机日志 `L2CAP up psm=0x80` |')
lines.append('| 握手前两步真的发到眼镜并被应答 | 日志 `-> plain (102B) 8062…` / `<- ch=0x8001 svc=5 type=1 (116B)` |')
lines.append('| ECDH 两方向密钥一致 | 单测 + 真机 `ecdh ok` |')
lines.append('| 签名用的是 NONEwithECDSA（对摘要原文签） | 与 Python 参考实现逐字节一致的单测 |')
lines.append('| 传输管道可用 | CI 里 `testLoopbackPipeDeliversAFrame` 通过 |')
lines.append('| 眼镜广播里能认出它 | 用厂商号 0x01AB 命中，不再依赖名字 |')
lines.append('')

lines.append('## 还没证明的事\n')
lines.append('- **trust**：眼镜是否接受我们这把钥匙（`0x1000` 成功 / `0x1010` 没这把钥匙 / `0x1044` 签名不对 / `0x1042` 账号不同）。')
lines.append('- 握手后半段（`EndLinkSetup` 的应答）之后 svc18/svc20 的完整往返——代码写了，但只在假眼镜上跑过。')
lines.append('- Live 取景、助手发声：代码完整，未在真机跑过。')
lines.append('')

lines.append('## 现在就差的这一步（三分钟）\n')
lines.append('1. 手机装 `releases/GlassesLink-0.55.0.ipa`（Sideloadly，Apple ID `py12300543322@126.com`，7 天有效）')
lines.append('2. 眼镜**折叠双镜腿 → 长按拍摄键 5 秒 → 指示灯闪蓝** → 展开放在手机旁')
lines.append('3. 打开 app → 相册页点一次 `RB Meta 046N` → 等 5 秒')
lines.append('4. 设备 → 高级 → **复制全部** → 把那段发出来')
lines.append('')
lines.append('详细对照表见 `docs/TRY-IT-NOW.md`。\n')

lines.append('## 手上的包\n')
for name, size in rows:
    lines.append(f'- `{name}` — {size:,} 字节')
lines.append('')

lines.append('## 为什么不继续猜着改\n')
lines.append('从 0.28 到 0.56 里，凡是"真机才会暴露"的问题（trust 判定写反、`precondition` 直接 abort、'
             '日志跨线程写 `@Published`、连点占满 PSM）都是靠你的日志定位的，每一条都是一次真实修复。'
             '再往下走同样需要真机信号；继续在没有设备的情况下改代码，只会让包变大、风险变高。\n')

lines.append('## 仓库\n')
lines.append('- 源码与 CI：`github.com/vigohan95/glasseslink`（public，macOS runner 免费）')
lines.append('- 本机项目：`D:\\GlassesLink`（含 `docs/`、`releases/`、`logs/screenshots/`、`ios/`、`pi/`、`tools/`）')

doc = '\n'.join(lines) + '\n'
p = r'D:\GlassesLink\STATUS.md'
io.open(p, 'w', encoding='utf-8', newline='\n').write(doc)
print('wrote', p, len(doc))
