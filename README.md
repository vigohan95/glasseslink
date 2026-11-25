# GlassesLink — 面向 AI 智能眼镜的 iOS 客户端

GlassesLink 的目标是成为一个**跨品牌的 AI 智能眼镜客户端**：一副眼镜，一个 app，拍摄时长、编码与处理算法、AI 模型都由你自己选，而不是由厂商替你决定。

当前版本优先支持 **Ray-Ban Meta Gen 2**，已实现：

- 拍照、录像（可选 30 秒 / 1 分钟 / 3 分钟 / 5 分钟自动停止）
- 相册浏览、按需把原始照片与视频取回并存进系统相册（保留视频封面帧）
- 设备状态：电量、温度、存储、音量、折叠状态
- 371 项设备设置（分 18 组）可读可写，含通知音量、指示灯亮度、语言、拍摄参数
- Live 取景（蓝牙链路，360×640 / 720p 两档）与取景中抓拍
- 助手：把眼镜上的「Hey Meta」接到任意 OpenAI 兼容服务（本地 Ollama、OpenAI、DeepSeek、OpenRouter 或自建），回答由眼镜自己念出来
- 隐私开关：拦截厂商固件升级请求、关闭云端 OTA

**架构上的三个承诺**

1. 眼镜 ↔ iPhone 直连，蓝牙 LE L2CAP，会话层加密（AirShield / DataX）在 app 内实现，不套 WebView、不转发到第三方服务器。
2. 日常使用不依赖厂商云端；只有第一次把手机登记为设备主人时需要厂商账号走一次 OAuth。
3. 协议实现有**两份独立转写**（`pi/` 的 Python 与 `ios/` 的 Swift），互为对照，任何一处偏差都能在 CI 里被发现。

> 关于"支持所有眼镜"：设备差异集中在三张表——产品号/设备类型、链路参数（PSM、通道号）、能力位（有无相机、有无显示）。
> 代码里已把这三件事抽成 `DeviceProfile` + 能力位驱动 UI，新增一个品牌只需要加一行 profile，不必改界面。

---

## 目录

```
ios/            iOS app 源码（Swift 5.9，iOS 17+）
  Tests/        XCTest：协议、P-256、线格式对照、回环
  Resources/    设置目录与文案（来自 Visor，AGPL，见 LICENSES.md）
  Assets.xcassets/  app 图标
pi/             Python 实现的同一套协议（可在树莓派 / Linux 上跑，含 12+5 组自测）
bridge/         早期过渡方案：把 Android 参考实现的本地网络接口转成 HTTP/PWA
tools/          一次性脚本：金标向量、配对凭据转换、参考实现对照、图标生成
docs/           所有文档（架构、协议、签名、迁移、进度）
releases/       已构建的 ipa
logs/           证据：截图、CI 记录
.github/workflows/ios.yml   macOS runner：编译 + 单测 + 打包未签名 ipa
```

## 五分钟上手

```powershell
# 1) 装签名（见 docs/BUY-SIGNING.md 或 docs/SIGNING.md），装上 releases/ 里最新的 ipa

# 2) 让 iPhone 成为设备主人（二选一）
#    A. app 里「设备 → 成为主人」→ 用厂商账号登录一次 → 提示时按一下眼镜拍摄键
#    B. 从已有的 Visor 导出配对凭据 → 转换 → 在 app 里粘贴导入（见 docs/OWNER-MIGRATION.md）

# 3) 连接
#    「相册」页顶部点眼镜名 → 日志出现 trust ok (0x1000)
```

之后每次使用：**只有 iPhone ↔ 眼镜的蓝牙链路**。

## 自己构建

```bash
# 本地（需要 macOS + Xcode 15+）
cd ios && xcodegen generate && xcodebuild -scheme GlassesLink -destination 'generic/platform=iOS' build

# 不签名出 ipa（用 GitHub Actions，本仓库已配好）
gh workflow run ios.yml     # 产物在 Actions 的 GlassesLink-ipa artifact
```

## 文档索引

| 想做什么 | 看哪份 |
| --- | --- |
| 产品定位与边界 | `docs/POSITIONING.md` |
| 搞清楚架构与模块职责 | `ARCHITECTURE.md` |
| 版本演进 | `CHANGELOG.md` |
| 踩过的坑与守卫 | `BUGLOG.md`、`docs/BUG-LEDGER.md` |
| 开发规则（本项目的流程） | `docs/PROCESS.md` |
| 与参考实现的逐步对照 | `docs/CONFORMANCE.md` |
| 日常使用与故障排查 | `docs/RUNBOOK.md`、`docs/TRY-IT-NOW.md` |
| 签名与分发 | `docs/SIGNING.md`、`docs/BUY-SIGNING.md`、`docs/DISTRIBUTION.md` |
| 换手机 / 迁移钥匙 | `docs/OWNER-MIGRATION.md` |
| 协议细节 | `docs/PROTOCOL-NOTES.md` |

## 许可

app 代码为 MIT。`ios/Resources/settings.tsv`、`settings_ui.json`、`varm_template.bin` 三份数据文件来自 Visor（AGPL-3.0），
分发或上架前需要替换为自己生成的等价数据，或取得原作者授权，详见 `docs/LICENSES.md`。
