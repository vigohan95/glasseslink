# Owner 迁移：把眼镜的所有权从安卓搬到 iPhone（只做一次）

做完这一步，iPhone 就是这副眼镜的主人：以后连眼镜、拍照、取文件、改设置全部在 iPhone 上完成，
不再需要 Meta 云、不再需要那台安卓手机。

---

## 0. 先理解一件事

眼镜只认"持有那把私钥的设备"。私钥是 Visor 配对时生成的普通 P-256 软件密钥，
但官方 Visor 把它锁进了 AndroidKeyStore（设备外解不开），所以：

> 用一个肯导出私钥的 Visor 版本重新做一次配对，把新的私钥带走。

代价：安卓上原来那把 owner key 作废，Meta 账号不变、眼镜里的照片不丢（**不要恢复出厂**）。

---

## 1. 装打过补丁的 Visor（安卓，约 5 分钟）

1. 手机上下载：<https://github.com/vigohan95/glasseslink/releases/tag/visor-patched>
   （`visor-owner-export.apk`，92.6 MB）
2. 先卸载官方 Visor（签名不同不能覆盖安装；这会清掉旧 owner key，是预期行为）。
3. 安装这个 APK。
4. 打开 Visor → 允许权限 → 登录 Meta（同你之前的账号）→ 眼镜进配对模式（折叠镜腿 + 长按拍摄键 5 秒，蓝灯闪）。
5. 一直点到「准备好了。本手机现已成为 … 的主设备。」
6. 去文件管理 `Download/`（或 `下载/`）里找 **`visor-owner-4V0ZW04H7J046N.json`**。

> 如果没看到文件：Visor 需要「所有文件访问」权限；到系统设置里给它，再重进一次 app 就会落盘。

---

## 2. 转成 iOS 用的格式（电脑，10 秒）

```powershell
cd C:\Users\lokla\Documents\deepseek-harness\default-workspace\meta-gen2
python -P tools/owner_to_ios.py visor-owner-4V0ZW04H7J046N.json owner-export.json
```

输出 `owner-export.json`：`serial` / `publicKeyXy`（64B）/ `privateKeyPkcs8`（PKCS#8 DER）。
把它传到 iPhone（AirDrop / iCloud 云盘 / 微信文件传输都行）。

---

## 3. 导入 GlassesLink（iPhone，30 秒）

1. 打开 GlassesLink（v0.5.0+）。
2. 第 2 节 → **「从文件 App 导入 owner-export.json」** → 选那个文件。
3. 日志出现 `已导入 owner-export.json（4V0ZW04H7J046N）`。
4. 第 1 节 → 扫描 → 连接眼镜 → **「重新握手」**（trust 链路）。
5. 日志出现 `trust ok` 就成功了：接着「刷新状态」「刷新清单」「打开设置」都能用。

---

## 4. 验证真的不碰 Meta

- 安卓关机、拔卡、挪到另一个房间。
- iPhone 关掉飞行模式外的任何代理（不需要 Meta 网络），只开蓝牙。
- 依次：连眼镜 → 刷新状态（有电量）→ 按眼镜拍摄键 → 相册刷新 → 取回照片 → 改一个设置（比如通知音量）→ 读回一致。

全部通过 = 迁移完成，安卓可以退休。

---

## 5. 常见失败

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| trust 握手报 `0x1044 INVALID_SIGNATURE` | 私钥和眼镜里的 owner 不配对（导错了文件 / 又用官方 Visor 配对过一次） | 重做第 1 步，用最新导出的 json |
| 报 `0x1010 KEY_NOT_FOUND` | 眼镜里没有这把公钥 | 同上 |
| 报 `0x1042 INVALID_USER_ID` | 改 owner 用的是另一个 Meta 账号 | 用配这副眼镜时的那个账号登录 |
| 连接后立刻断开、日志无 trust | 眼镜折叠休眠 | 展开镜腿、放近一点、再点一次连接 |
| 状态/设置一直超时 | 安卓端 Visor 还连着（眼镜同时只允许一个会话） | 关掉安卓 Visor 或关机 |
| 换 iOS 签名后 owner 丢失 | 换签名主体会清 Keychain | 重新导入 `owner-export.json`（文件在就不怕） |

---

## 6. 私钥安全

`owner-export.json` 里的私钥 = 这副眼镜的所有权。谁拿到它，谁就能连这副眼镜。

- 存一份到 iCloud 私有云盘 / 密码管理器。
- 不要贴到聊天群、issue、公开仓库。
- 丢了就得重做一次 owner 迁移（眼镜没恢复出厂就还能做）。
