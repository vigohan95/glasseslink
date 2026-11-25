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

关键词就说「**UDID 定制签名，装我自己编译的 ipa，iOS 27.2**」。

---

## 2. 下单前必须确认的三件事

1. **能装自己的 ipa**（不是只能装他们提供的应用）。有些卖家只卖"已签好的 app"，那不行。
2. **保留 bundle id `dev.local.glasseslink`**，不要改。改了 Keychain 里的 owner key 就读不到（虽然我们还有文件备份，但省事）。
3. **不需要系统级修改**、不改 entitlements。我们只用：蓝牙（`NSBluetoothAlwaysUsageDescription`）、本地网络、相册读写、文件共享。这些都是普通权限，不需要特殊 entitlement。

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

## 5.5 如果卖家给的是「p12 + 描述文件」（自己签）

闲鱼上很多「UDID 定制 / 源码 v2」的店铺实际交付两种东西之一，**两种都能用**，但要分清：

| 交付形态 | 拿到什么 | 怎么装 | 备注 |
| --- | --- | --- | --- |
| A. OTA 链接 | `itms-services://` 链接或二维码 | Safari 打开 → 安装 | 最省事，不用电脑 |
| B. 证书包 | `.p12` + 密码 + `.mobileprovision` | Windows 上用 Sideloadly 签 + USB 装 | 需要装 iTunes/Apple Devices，之后可重复自签 |

如果是 B，装 Sideloadly 后这样填：`IPA` 选我们的 ipa、`Apple ID` 那栏留空、勾 `Advanced Options` → 指定 `.p12` 与 `.mobileprovision`、填 p12 密码 → Start。

两种情况都要盯同一件事：**`.mobileprovision` 里的 `application-identifier` 必须允许 `dev.local.glasseslink`**（UDID 定制签名一般是通配符 `*`，那就没问题；如果卖家给的是固定 bundle id，让他改成这个，或者用 `com.xxx.*` 通配）。

**付款前问清这 5 句**（复制发过去）：

1. 是 UDID 定制（Ad Hoc）还是企业签？我要 UDID 的。
2. 能不能装**我自己的 ipa**？（不是只能装你们提供的应用）
3. bundle id 能不能用 `dev.local.glasseslink`？或者给通配符 `*` 的描述文件？
4. 掉签包不包补？补签要不要再付钱？
5. 有效期多久？是 1 年还是跟证书剩余时间走？

只要 1、2、3 都答"可以"，这个就能用。

---

## 5.6 三类闲鱼商品的取舍（判断标准，不看标题看交付）

| 商品说法 | 实际卖的是 | 装法 | 风险 | 结论 |
| --- | --- | --- | --- | --- |
| 「UDID 定制签名」 | 卖家用自己的证书**替你签好**，给你 OTA 链接 | Safari 打开即装 | 证书被吊销会掉，但只影响这一批 UDID | **优先** |
| 「自用 p12 证书」 | 一张 `.p12` + 密码（可能还给描述文件） | 你在 Windows 上用 Sideloadly 或手机上的全能签/轻松签自己签 | p12 若卖给多人 = 共享证书，一人违规全封；p12 泄露等于别人能替你签名 | 次选（要长期反复装才值） |
| 「全能签 / 轻松签 / 万能签」 | 一个**第三方签名 App** + 教程 | 先装这个 App（多半靠企业签），再由它签我们的 ipa | 两层依赖：签名 App 自己掉签就全废；iOS 27 上这类工具支持情况不稳 | 最次 |

一句话判断：**能直接给你「装好的 OTA 链接」的最省事；只给你工具让你自己折腾的，链路最长。**

无论买哪种，都要问：能否装**我自己的 ipa**、bundle id 能否用 `dev.local.glasseslink`（或通配符 `*`）、掉签是否包补。

---

## 6. 如果你想上架 / 给别人用

- TestFlight 需要 $99 开发者账号 + 每个 build 过 beta 审核（比 App Store 松，但仍有审核）。
- 上 App Store 前必须处理 **AGPL-3.0**：`Resources/varm_template.bin`、`Resources/settings.tsv`、`Resources/settings_ui.json` 三份数据来自 Visor（`github.com/macedonga/visor`）。要么以 AGPL 开源整个 app，要么把这三份换成自己逆出来的等价数据。
  目前仓库是 public 的，已经在 AGPL 下满足"提供对应源码"这一条。
