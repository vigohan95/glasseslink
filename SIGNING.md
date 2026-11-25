# 签名与安装：四条路，按预算选

iOS 27.2 没有免费的永久签名：免费 Apple ID 7 天、SideStore 端上续签、或付费开发者账号，只有这三类。
所以「装上去」这件事只有四种现实做法。所有做法用的都是同一个 `GlassesLink.ipa`，不用重新构建。

---

## 方案 1：免费 Apple ID + Sideloadly（0 元，7 天）

**需要**：Windows 电脑 + USB 线 + 你的 Apple ID。

```
1. 装 Sideloadly（sideloadly.io）
2. 拖入 GlassesLink.ipa
3. Apple ID 填你的，密码栏填 App 专用密码
   （appleid.apple.com → 登录与安全 → App 专用密码 → 生成一个）
4. Start → 它会重签并把 app 装进手机
5. 手机：设置 → 通用 → VPN 与设备管理 → 信任你的 Apple ID
```

- 有效期 **7 天**，到期 app 打不开，需要再插一次电脑重签（数据不丢，但见下面的「重签之后」）。
- 免费账号同时最多 3 个自签 app、10 个 App ID。
- 装完就可以拔线，眼镜、照片、模型都不依赖电脑。

---

## 方案 2：SideStore（0 元，手机自己续签）

**需要**：先按方案 1 装一次 SideStore 本体，然后它能在手机上自动续签。

```
1. 按方案 1 的方式装 SideStore（altstore 的社区分支，带 StosVPN）
2. SideStore 里登录同一个 Apple ID，把 GlassesLink.ipa 导入并安装
3. 打开 StosVPN（本机回环 VPN），SideStore 靠它在设备上完成重签
4. 设置里开「后台刷新」，续签周期 7 天，会自动续
```

- 不用每次插电脑，但 StosVPN 必须能起（部分系统版本需要开着它才能续签）。
- 依然受 7 天周期约束，只是自动化了。

---

## 方案 3：超级签名 / UDID 定制（约 ¥10–50/年，OTA 装，不用电脑）

闲鱼、签名站都能找到；关键是**要「UDID 定制」那种**，把你手机的 UDID 加进他们的描述文件。

```
1. 用他们的工具取 UDID（Safari 打开他们给的链接即可，或用 iMazing 看）
2. 把 GlassesLink.ipa 发给他们，或让他们重签你给的 ipa
3. 他们回一个 itms-services 安装链接，Safari 打开 → 装
4. 有效期通常 1 年，掉签会重装
```

- **坑**：企业签名（¥5–20）会被集体吊销，随时打不开；要买就买 UDID 定制/超级签名。
- 装完不需要电脑、不需要 VPN。

---

## 方案 4：Apple Developer（$99/年，最稳）

```
1. 注册 Apple Developer Program（个人 $99/年）
2. Xcode 或 GitHub Actions 用你的证书签名（tools/ 里已有 workflow 可改）
3. 或继续用 Sideloadly，但用开发者证书签：有效期 1 年，不再是 7 天
4. 想给别人用：TestFlight（每个 build 90 天，需要过 App Review 的 beta 审核）
```

- 只有这条路能长期稳定 + 分发给别人 + 上 TestFlight。
- 想上架 App Store 还要处理 AGPL（`varm_template.bin`、`settings.tsv`、`settings_ui.json` 来自 Visor，AGPL-3.0）。

---

## 重签之后必须做的一件事

iOS 的 Keychain 条目绑定签名主体（team/bundle 标识）。**换证书重签 = Keychain 清空**，owner 私钥会丢。

所以：

1. 第一次成功 trust 后，立刻在 app 里「导出 owner-export.json」，存到 iCloud Drive / 文件 App。
2. 每次重签后：打开 app →「3 · 成为主人」→「从文件 App 导入 owner-export.json」→ 回「1 · 连接」。
3. 文件版不受签名影响，这是唯一可靠的备份方式。

另外每次重装要重新点一遍系统权限（蓝牙、通知使用权、相册、位置）。通知使用权在「设置 → 通知 → 通知使用权」里给 `GlassesLink` 打开。

---

## 怎么确认装好了

- 桌面出现 GlassesLink 图标，能打开不闪退。
- 「2 · 自检」跑一遍，全部 ✓（尤其看 `Security 能导入私钥` 那条：真机上如果是 ✗，说明会走自研 P-256，也能用，但要留意 trust 时是否回 `0x1044`）。
- 「1 · 连接」能扫到 `RB Meta 046N`。

---

## 选哪个

| 你的情况 | 选 |
| --- | --- |
| 只想先跑通、有 Windows 电脑 | 方案 1（免费，7 天重签） |
| 不想老插电脑 | 方案 2（SideStore）或方案 3（¥30 一年） |
| 要长期稳定、可能给别人用 | 方案 4（$99） |

先按方案 1 跑通一次，确认整条链路（trust → 拉照片 → 问模型）都正常，再决定要不要花钱。
