# 买签名：怎么买、跟卖家说什么、装完怎么验

你已经决定买签名。下面这份是**照着做就行**的清单，不需要再问我。

---

## 1. 买哪种

| 类型 | 价格区间 | 有效期 | 会不会掉 | 建议 |
| --- | --- | --- | --- | --- |
| **UDID 定制 / 超级签名** | ¥10–50 | 1 年 | 极少（掉签会补） | **买这个** |
| 企业签名 | ¥5–20 | 不定 | 会集体吊销 | 别买 |
| TestFlight | 需 $99 开发者 | 90 天/build | 到期要重新发 | 想给别人用时才考虑 |
| Apple Developer 自签 | $99/年 | 1 年 | 不会 | 最稳，你自己有 Mac 时最省心 |

关键词就说「**UDID 定制签名，装我自己的 ipa，不越狱，iOS 27.2**」。

---

## 2. 下单前必须确认的三件事

1. **能装自己的 ipa**（不是只能装他们提供的应用）。有些卖家只卖"已签好的 app"，那不行。
2. **保留 bundle id `dev.local.glasseslink`**，不要改。改了 Keychain 里的 owner key 就读不到（虽然我们还有文件备份，但省事）。
3. **不要求越狱**、不改 entitlements。我们只用：蓝牙（`NSBluetoothAlwaysUsageDescription`）、本地网络、相册读写、文件共享。这些都是普通权限，不需要特殊 entitlement。

---

## 3. 要发给卖家的东西

```
ipa：GlassesLink.ipa（GitHub release v0.25.0 里的 asset，约 590 KB）
Bundle ID：dev.local.glasseslink
Display Name：GlassesLink
最低系统：iOS 17.0
设备：iPhone（arm64），iOS 27.2
UDID：<他们给的链接取，或用 iMazing / 爱思助手看>
```

他们会回一个 `itms-services://` 链接，**用 Safari 打开**（不要用微信内置浏览器），点安装。

---

## 4. 装完立刻做的四步

1. **信任描述文件**（如果是企业/超级签名通常不需要；如果是免费签才需要）
   设置 → 通用 → VPN 与设备管理 → 开发者 App → 信任。
2. **开通知使用权**
   设置 → 通知 → 通知使用权 → GlassesLink 打开。
   不给的话眼镜收不到手机通知（不影响拍照/取照）。
3. **跑自检**：打开 app →「2 · 自检」→ 看是否全 ✓。
   特别看两条：
   - `Security 能导入私钥` —— ✗ 也没关系，会走自研 P-256；
   - `参考向量签名一致` —— 必须是 ✓，否则说明装错包了。
4. **导出备份**：成功后「3 · 成为主人」→「导出 owner-export.json」→ 存 iCloud。
   **换签名会清 Keychain**，这个文件是唯一可靠的恢复手段。

---

## 5. 掉签了怎么办

现象：点图标闪退 / 提示「无法验证 App」。

1. 找卖家补签（UDID 定制一般都包补）。
2. 重新 OTA 装。
3. 打开 app →「3 · 成为主人」→「从文件 App 导入 owner-export.json」→「1 · 连接」。
4. **不需要**重新登录 Meta、**不需要**再碰安卓。

---

## 6. 如果你想上架 / 给别人用

- TestFlight 需要 $99 开发者账号 + 每个 build 过 beta 审核（比 App Store 松，但仍有审核）。
- 上 App Store 前必须处理 **AGPL-3.0**：`Resources/varm_template.bin`、`Resources/settings.tsv`、`Resources/settings_ui.json` 三份数据来自 Visor（`github.com/macedonga/visor`）。要么以 AGPL 开源整个 app，要么把这三份换成自己逆出来的等价数据。
  目前仓库是 public 的，已经在 AGPL 下满足"提供对应源码"这一条。
