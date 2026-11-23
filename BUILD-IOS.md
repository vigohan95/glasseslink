# 让安卓彻底消失：完整 runbook

目标：安卓手机只干一次活（配对 + 交出 owner key），之后你只用 iPhone，眼镜照常拍照、录像、调你自己的模型。

```
一次性安卓 ──配对──▶ 拿到 owner key + receipt ──导出──▶ iPhone 客户端 ──直连──▶ 眼镜
     └── 之后关机、卖掉、扔抽屉，都不影响
```

原理一句话：眼镜每次建链只验一件事 —— 你能用 owner 公钥验证的私钥签出 channel binding。它不关心签名的是哪台设备。所以把 32 字节私钥搬走，owner 身份就跟着走了。

---

## 阶段 0：先确认一件事（10 分钟，决定走哪条）

在安卓上装官方 Visor，配对成功后，跑：

```bash
python tools/adb_export_owner.py
```

- **找到 32 字节私钥候选** → 直接跳到阶段 3，不用自己编译 Visor。
- **什么都没找到 / 报 Keystore** → 私钥在 Android Keystore 里，硬件保护、导不出来。走阶段 1，自己编译一个用软件 key 的 Visor，重新配对一次。

> 先做这一步再拆机，能省掉一半工作量。

## 阶段 1：编一个「能导出」的 Visor（只在上一步失败时需要）

```bash
git clone https://github.com/macedonga/visor && cd visor
```

1. 从官方 Meta AI app 里提三个 token，写进 `local.properties`：
   ```
   VISOR_META_HW_TOKEN=HW|...
   VISOR_META_AR_TOKEN=AR|...
   VISOR_META_FRL_TOKEN=FRL|...
   ```
2. 把 [visor-patch/OwnerExport.kt](visor-patch/OwnerExport.kt) 放进 app 模块，接到 `core/identity` 的 owner key 生成处：把 `KeyGenParameterSpec` 那套换成 `OwnerExport.softwareOwnerKey()`（软件 P-256，可导出），配对成功后调用 `exportOwner(...)`。
3. 找 receipt 的位置：在 identity 模块里 grep `receipt` / `ownership`。
4. 编译安装：
   ```bash
   ./gradlew :app:assembleDebug
   adb install -r app/build/outputs/apk/debug/app-debug.apk
   ```
5. 重新配对眼镜（先在 Meta AI app 里把设备移除，再配），然后：
   ```bash
   adb pull /sdcard/Android/data/<visor-pkg>/files/owner-export.json
   ```

拿到 `owner-export.json` 就是拿到了 owner 身份。**这个文件等于你的眼镜所有权，备份两份，别丢。**

## 阶段 2：抓一次 svc36 trust（决定 iOS 端能不能一次通）

协议文档把 trust 步骤只写了散文，没给字段号。趁安卓还在，抓一次真包：

1. 用 debug 版 Visor 连上眼镜，进设置页、退出、再进（制造一次完整建链）。
2. `adb pull /sdcard/Android/data/<visor-pkg>/files/wire.log`
3. 在日志里找 `EnableEncryption` 之后、`EndLinkSetup` 之前、channel 为 `0x0024`（36）的那几帧 —— 那串字节就是模板。
4. 对着它填 [ios/OwnerKey.swift](ios/OwnerKey.swift) 里 `TrustStep.trustPayload()` 的字段号（现在按「1=公钥 2=签名 3=receipt」占位）。

同时确认 L2CAP 的 PSM：看 `https://visor.macedonga.com/protocol/radios-and-links/`，填进 [ios/App.swift](ios/App.swift) 的 `var psm`。

## 阶段 3：没有 Mac 也能出 ipa

`.github/workflows/ios.yml` 已经写好，用 GitHub 的 macOS runner 免费编译：

1. 把 `meta-gen2/` 推成一个 **public** 仓库（public 仓库的 macOS 分钟免费）。
2. Actions 自动跑，产物 `GlassesLink.ipa` 在 Artifacts 里下载。
3. Windows 上装 [Sideloadly](https://sideloadly.io/)，用你的 Apple ID 签名这个 ipa 装到 iPhone（免费账号 7 天有效，到期重签一次，Sideloadly 支持自动重签）。有 99 美元的开发者账号就是 1 年。

有 Mac 的话更简单：

```bash
cd ios && brew install xcodegen && xcodegen generate
open GlassesLink.xcodeproj      # 选你的 Team，真机跑
```

## 阶段 4：把 key 搬进 iPhone，验证，弃安卓

1. iPhone 上：文件 App → 我的 iPhone → **GlassesLink** → 把 `owner-export.json` 拷进去（Info.plist 已开 `UIFileSharingEnabled`）。
2. 打开 App，日志应出现 `owner key: loaded, pub=xxxx…`。
3. 眼镜进配对模式（折腿 + 长按 5 秒），App 里点设备连接 → 看到 `L2CAP up: psm=0x…`。
4. 跑握手：RequestEncryption → EnableEncryption → trust → EndLinkSetup。
5. **验收标准**：安卓关机、拔卡、放另一个房间，iPhone 依然能建链、能通过 trust、能拉一张照片。到这一步安卓就真的没用了。

## 阶段 5：长期维护

| 事项 | 说明 |
|---|---|
| 7 天重签 | 免费 Apple ID 的限制，Sideloadly 挂在电脑上自动重签；不想折腾就买开发者账号 |
| 固件别升 | 126 是"可装未签名组件"的最后窗口；升级前先抓一份 OTA 包留档 |
| key 备份 | `owner-export.json` 丢了 = 眼镜得重新配对一次（又要一台安卓），存两处离线 |
| 媒体能力 | iOS 没有 Wi-Fi Direct / RFCOMM：单张拍照、抓帧、问答没问题；连续录像和高码率实时图传受限于眼镜自建 AP 或低速 L2CAP |
| 回退 | 万一 trust 布局对不上，先用 [bridge/server.py](bridge/server.py) + 那台安卓当临时网关顶着，不影响日常使用 |

---

## 工作量与预期

| 阶段 | 时间 | 卡点 |
|---|---|---|
| 0 探测 | 10 分钟 | 无需 root（若 APK 可 debug）或有 root |
| 1 编 Visor | 1–2 小时 | token 提取、Keystore 改软件 key、重新配对 |
| 2 抓 trust | 20 分钟 | 会看 hex 就行 |
| 3 出 ipa | 30 分钟 | 一个 GitHub 账号 + Sideloadly |
| 4 验证 | 20 分钟 | 主要卡在 PSM 和 trust 字段号 |

总计半天到一天。唯一真正的未知是 svc36 的字段布局，而它只要你**在删安卓之前**抓一次包就能解决 —— 这是整个方案里最容易做错的一步。
