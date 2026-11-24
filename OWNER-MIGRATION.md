# 把 owner 从安卓搬到 iPhone（一次性）

> 打补丁的 Visor 包名是 `com.macedonga.visor.owner`，可以和正版并排共存；装它**不会**动到现有 owner key。

## 1. 在安卓上导出钥匙

1. 装 `visor-owner-export-sxs.apk`（release `visor-patched` 里的 asset）。
2. 打开 → 走完「登录 Meta → 让眼镜进配对模式 → 完成设置」这一遍。
3. 设置页里能看到 Downloads/visor-owner-<序列号>.json（app 会提示已导出）。
   - 用 `adb shell ls /sdcard/Download | grep owner` 确认，或用手机的文件管理器。

## 2. 转成 iOS 的格式

```
python -P tools/owner_to_ios.py Downloads/visor-owner-XXXX.json owner-export.json
```

产物字段：`serial` / `source` / `publicKeyXy`（base64，64 字节）/ `privateKeyPkcs8`（base64 DER）。

## 3. 导入 iPhone

1. 把 `owner-export.json` 传到手机（AirDrop / iCloud Drive / 微信文件都行）。
2. 打开 GlassesLink → 「3 · 成为主人」→「从文件 App 导入 owner-export.json」。
3. 回到「1 · 连接」→ 点眼镜 → 走 trust 握手。

## 4. 验证

```
日志应出现：
  handshake: RequestEncryption -> EnableEncryption
  trust: 0x1000 OK
  EndLinkSetup: stream=… link=…
```

## 失败对照

| 现象 | 含义 | 处置 |
| --- | --- | --- |
| `0x1044 INVALID_SIGNATURE` | 签名不被接受 | 看「复制全部」日志里的自检结果：若 Security 那条 ✗，说明走的是自研签名；把日志发我 |
| `0x1010 KEY_NOT_FOUND` | 眼镜里没有这把钥匙 | 你导入的不是当前 owner；回到第 1 步重新导出 |
| `0x1042 INVALID_USER_ID` | 眼镜属于另一个 Meta 账号 | 用同一个账号登录后再导出 |
| 卡在 `RequestEncryption` | 眼镜没回应 | 展开镜腿/靠近，或眼镜正在被别的设备占着（AirShield 只允许一个会话） |