# GlassesLink 进度（持续更新）

目标：iPhone 单独连接 Ray-Ban Meta Gen 2，不依赖 Meta 云、不依赖安卓，功能对齐 Visor。

## 已打通（真机验证）

| 能力 | 实现 | 状态 |
| --- | --- | --- |
| LE L2CAP 控制链路（PSM 128） | `ios/Session.swift` + `ios/AirShield.swift` | 安卓端同协议栈已验证；iOS 待真机 |
| AirShield 握手 / 加密 | ECDH P-256 + HKDF + AES-256-CBC + HMAC | 与 `pi/` 参考实现逐字节一致 |
| owner 信任（svc36，不用再找 Meta） | 私钥在 `owner-export.json`，`Trust.buildEnableTrust` | 需要先做一次 owner 迁移 |
| 拍照清单 / 取原图（svc18 + svc20） | `captureList` / `requestAsset` / `receiveFile` | 安卓路径实测 2.7 MB 原图 |
| 眼镜设置读写（svc33 RLDrive） | `ios/Drive.swift` + `SettingsCatalog/SettingsView` | v0.3.0 内置 370 项设置 |
| 固件设置写入（svc31） | `ios/SettingsSchema.swift` + `Session.writeSettingsField` | v0.6.0：370 项里 174 项走 svc31 |
| 设备状态（电量/温度/空间/音量） | `ios/Status.swift`（svc28 订阅） | v0.4.0 |
| 相册 + 视频导出 | `Glasses.loadCaptures/fetch` | v0.4.0，照片存相册、视频分享 |
| 自选模型（OpenAI 兼容） | `ModelClient` + 图片内联 | 本机 Ollama 已测通 |
| Live 取景（svc51350） | `ios/Live.swift` + `LiveView`（HEVC → AVSampleBufferDisplayLayer） | v0.7.0，BLE 档 360×640/15fps |
| 常用开关 | `ios/QuickPanel.swift`（6 个高频 svc31 项） | v0.8.0 |

## 版本

- v0.1.0 骨架 + 协议栈
- v0.2.0 app 内 Meta 登录（WKWebView 拦 `code=`）+ owner 导出分享 + 日志落盘
- v0.3.0 眼镜设置可读写（370 项，18 组，写后读回校验）
- v0.4.0 设备状态页（svc28）+ 相册/视频导出
- v0.5.0 文件导入 owner（`.fileImporter`），换签名后不用重做迁移
- v0.6.0 固件设置走 svc31（`settings.tsv` 253 个字段，174 个 parsed），读回校验
- v0.7.0 Live 取景：START_APP(3) → SESSION_SETTINGS → CONFIGURE_VIDEO/AUDIO → CONTROL_START，Annex-B 拆帧、HEVC 参数集建设备格式、中途抓拍 HEIC
- v0.8.0 快捷面板：助手开关 / 唤醒提示音 / 拍摄伴音 / 高画质档 / 快剪拍照

## 待做

1. owner 迁移：安装打过补丁的 Visor → 导出 `visor-owner-*.json` → `tools/owner_to_ios.py` → 放进 app Documents。
2. 真机跑握手，按 `Documents/glasses.log` 修偏差（svc36 字段、svc18 flatbuffer 槽位）。
3. Live 取景真机验证（BLE 档；iOS 无 Wi-Fi Direct，上不了 1080p）。
4. 亮度/音量直控（状态服务里的音量字段只读，写入路径待逆）。
5. 助手接入：眼镜端"Hey Meta"替代（Visor 的做法是自建 assistant server，走 svc? + TTS）。
6. 签名分发：超级签名 OTA，或 TestFlight。

## 目录

- `ios/` iOS app（SwiftUI，XcodeGen 生成工程，GitHub Actions 出未签名 ipa）
- `pi/` 原生协议栈参考实现（Python，含 4 组自测，可直接跑在 Linux 盒子上）
- `bridge/` 安卓中转桥（已实测：手机 ↔ 眼镜 ↔ PC ↔ iPhone PWA）
- `tools/` adb / token / owner 转换脚本
- `visor-src/` 打过补丁的 Visor 源码（用于一次性导出 owner key）
