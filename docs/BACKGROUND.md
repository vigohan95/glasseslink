# 背景资料：已有的公开客户端实现

这一份记录"我们站在谁的肩膀上"，以及哪些能力是社区已经公开验证过的。它是参考资料，不是操作手册。

## 参考实现

| 项目 | 平台 | 许可 | 我们用了什么 |
| --- | --- | --- | --- |
| [Visor](https://github.com/macedonga/visor) | Android 12+ | AGPL-3.0 | 设置目录（`settings.tsv`）、设置界面文案（`settings_ui.json`）、助手模板（`varm_template.bin`）；以及"设备会话层如何分通道"的公开说明 |
| [Visor 协议文档](https://visor.macedonga.com/protocol/) | 文档 | — | 链路建立、加密封帧、通道与消息号的公开说明，我们据此写了两份独立实现（Python / Swift） |
| [OpenGlasses](https://github.com/straff2002/OpenGlasses) | iOS 26+ | BSL 1.1 | 只做产品功能对照（视觉问答、字幕、RTMP 等），代码不引用 |
| [OpenVision](https://github.com/rayl15/OpenVision) | iOS 18+ | MIT | 只做 UI/交互参考 |

## 这些实现共同确认的事实

- 眼镜在蓝牙链路上暴露一个 LE CoC 通道，通道内是"通道号 + 消息号 + 载荷"的分层结构。
- 会话建立分三步：交换公钥与随机数 → 双向派生密钥 → 用设备主人私钥对通道绑定签名。
- 设备主人身份是一次性登记的，换手机会话就会失败，除非迁移那把私钥。
- 同一时刻只允许一个会话；厂商官方 app 连上会接管链路。

## 我们不做的事

- 不修改、不重新打包、不再分发任何厂商 app。
- 不触碰固件：不做刷写、不做签名校验的规避。
- 不做任何跳过账号体系的处理；设备主人的登记仍然走厂商账号一次。

## 为什么不直接 fork Visor

Visor 是 Android（Kotlin + Gradle + AndroidKeyStore）。我们的目标平台是 iOS，需要 CoreBluetooth 的
LE CoC、CryptoKit / 自研 P-256、SwiftUI 的交互，以及"任何品牌都能接"的分层结构。共享的是**协议知识**，
不是代码。
