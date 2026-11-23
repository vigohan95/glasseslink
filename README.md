# Meta Ray-Ban Gen 2 · 去 Meta 化 + 自选模型（iPhone 版）

目标拆开看是四件事，能不能做完全不一样：

| 你的需求 | 能否达成 | 现实代价 |
|---|---|---|
| 眼镜日常不再连 Meta 服务器 | **能** | 一次性配对必须过一次 Meta（拿 ownership receipt / owner key），之后手机↔眼镜走本地协议，照片、语音、模型请求都不出局域网 |
| 正常拍照、录像、看相册 | **能** | 用 Visor 做眼镜端客户端；Wi-Fi Direct 只在 Android 上可用 |
| 自选 AI 模型（DeepSeek / 本地 Ollama / 自建） | **能** | Visor 自带 Assistant 替换 Meta AI，“Hey Meta” 的语音走你给的 OpenAI 兼容 endpoint |
| 全程只用 iPhone，不碰 Android | **部分能** | iPhone 不能直接跑 Visor；要么加一台 Android 当桥（推荐），要么把 AirShield 协议移植到 iOS（有骨架，但要 Mac + Xcode） |
| 连一次性配对都不碰 Meta | **只有固件级** | 需要 ≤126 固件 + 自制 app 替换 DAT + MobileConfig 单字节绕过；127 已加签名校验，升级就封 |

关键事实先说清楚：**Ray-Ban Meta 眼镜自己不上网**（除了 Display 版），所有流量都是“手机 → 眼镜”的本地链路。所以“断云”这件事的真正战场在手机 App，而不在眼镜。Visor 就是把这个 App 换掉了。

---

## 路线 A（推荐，今天就能跑）：Android 当桥，iPhone 当遥控器

```
iPhone Safari/PWA  ──HTTP──▶  桥（笔记本/NAS/树莓派）  ──WebSocket──▶  Visor(Android)  ──BLE L2CAP──▶  眼镜
```

桥的意义：把 Visor 的网络门（JSON-RPC over WebSocket）翻译成 HTTP，iPhone 用 Safari 打开就行，不用装任何 App。

### A1. 眼镜侧

1. 折叠双镜腿，长按拍摄键约 5 秒，内侧 LED 蓝闪 → 进入配对。
2. 找一台 Android 12+ 手机，装 Visor：<https://github.com/macedonga/visor/releases>。
3. Visor 首次 setup 会登录 Meta 账号，拿 login + ownership receipt（成为 owner app）。**这一步是唯一一次必须连 Meta**，之后 Visor 不再回传。
4. 如果想自己编译 Visor：从官方 Meta AI app 里提取三个以 `HW|`、`AR|`、`FRL|` 开头的 client token，写进 `local.properties`：
   ```
   VISOR_META_HW_TOKEN=HW|...
   VISOR_META_AR_TOKEN=AR|...
   VISOR_META_FRL_TOKEN=FRL|...
   ```
   缺了它们，login 和 ownership 步骤会失败。
5. Visor 里打开 **Network door**，记下它显示的 IP、端口（7333）和 token。

### A2. 桥（本仓库）

```bash
cd bridge
python server.py --url ws://192.168.1.50:7333/rpc --token <VISOR_TOKEN>
# 或者先把 config.example.json 复制成 ../config.json 再直接 python server.py
```

自测（不需要眼镜、不需要手机）：

```bash
python server.py --mock --port 8788
curl http://127.0.0.1:8788/api/status
```

启动后终端会打印 `iPhone: http://<你的局域网IP>:8787/`，用 iPhone Safari 打开即可。加到主屏幕就是 PWA。

### A3. 接自选模型

编辑 `config.json` → `model`：

```jsonc
// 本地 Ollama（视觉模型，完全离线）
{ "provider": "openai", "base_url": "http://127.0.0.1:11434/v1", "model": "qwen2.5vl:7b" }

// DeepSeek / OpenRouter / 任何 OpenAI 兼容网关
{ "provider": "openai", "base_url": "https://api.deepseek.com/v1", "api_key": "sk-...", "model": "deepseek-chat" }

// 只想先看链路通不通
{ "provider": "demo" }
```

`provider: demo` 不会调用任何外部服务，只回显，用来验证拍照链路。

### A4. HTTP 接口

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/api/status` | 门是否连上、眼镜电量/佩戴/链路、当前模型 |
| GET | `/api/captures` | 眼镜相册列表 |
| POST | `/api/capture` | 拍一张，`{"mode":"auto"\|"live"\|"photo"}`，返回 base64 |
| POST | `/api/ask` | `{"question":"...","capture":true}` 拍照 + 问模型 |
| POST | `/api/video` | `{"action":"start"\|"stop"}` |

拍照实现上走两条路：优先 `camera.live.photo`（需要 Visor 里开着 Live view，最快，随时抓帧），否则 `camera.photo` 拍一张再 `captures.import` 取回字节。所以**建议在 Visor 里常开 Live view**，桥就能像取景器一样随时取图。

加了一层可选保护：`config.json` 里填 `server.access_key`，之后所有请求要带 `?k=<key>`。

---

## 路线 B：iPhone 原生直连（要 Mac + Xcode，工作量大）

协议栈是分层的，iOS 能覆盖一部分：

| 层 | 内容 | iOS |
|---|---|---|
| Radio | LE L2CAP CoC / Classic RFCOMM / TCP over Wi-Fi | ✅ L2CAP（`CBPeripheral.openL2CAPChannel`）/ ❌ RFCOMM 第三方不可用 / ⚠️ Wi-Fi Direct 不可用，要眼镜自建 AP + 手动入网 |
| Framing | 4 字节 DataX 头 + 4 字节 tag | ✅ 见 `ios/AirShield.swift` |
| AirShield | ECDH P-256 → AES-256-CBC + HMAC-SHA-256 每帧 | ✅ CryptoKit + CommonCrypto |
| Trust | svc36，用 owner key 签 channel binding | ⚠️ 需要一个已配对的 ownership receipt |
| Services | protobuf / Thrift compact / FlatBuffers / zstd | ✅ 都有 Swift 实现 |

`ios/AirShield.swift` 里已经按官方字节级文档写好了：DataX 头/tag 编码、protobuf 写出器、`RequestEncryption`(0x8001/type1)、`EnableEncryption`(0x0001/type2)、KDF（`salt_aes=SHA256(nonce‖seed)`、`PRK=HMAC(salt,S)`、`key=HMAC(PRK,"AirShield"‖0x01)`，含 QCS7 quirks 那条 136 字节 HKDF info 分支）、channel binding、`EndLinkSetup` 的 46 字节明文与 v4 UUID 校验、AES-CBC + 每帧 HMAC。TODO 都标了出来（MAC 拼接顺序、非 QCS7 的 MAC word、L2CAP PSM 数值），必须先抓一份 Android 端的 `wire.log` 对照再动手。

现成的 iOS 参照项目：<https://github.com/rayl15/OpenVision>（Swift，用 Meta 官方 DAT SDK，7 个后端含本地 MLX 视觉模型）。它省事，但**仍然要 Meta 开发者账号注册 app**，不满足“不连 Meta”。

---

## 路线 C：固件级，真正的“零 Meta”

Bynar.io 的 Paula（pamoutaf）在 nullcon Berlin 2026 的演讲 “Beeps and Patches: arbitrary code execution on Meta Ray-Ban” 给了一条完整链路：

1. **拿固件**：不用开壳。用 Meta AI app 触发 OTA，抓更新包就是完整固件镜像（反编译 Meta AI app，`OtaArtifactFetcher` 发请求、响应转成 `OTAArtifactInfo`）。
2. **装自己的代码（固件 <126）**：这一版不校验 DAT 安装组件签名。把官方 DAT 换成自己未签名的 app（借 Meta 的 Camera Access 示例 app），就能在眼镜里跑自己的代码。
3. **固件 127 的绕过**：127 加了签名校验，但手机从 Meta 服务器取 MobileConfig 后**原样下发给眼镜、不校验完整性**，翻转其中一个字节即可绕过（对应 `0x1043 INVALID_APP_IDENTITY`）。
4. **拿 shell**：Frida hook + Meta 示例 app 维持连接，在 **Wi-Fi Direct 链路**上拿到交互式 shell。目前权限是 unprivileged。

这条路意味着：眼镜里跑自定义组件 → 完全绕开手机侧 App → 真正不碰 Meta。代价是固件版本窗口极窄、一步走错变砖、而且每次官方 OTA 都可能把它关掉。

---

## 为什么“完全不连 Meta”卡在 ownership 上

眼镜每次建链都要做一次 svc36 trust：手机必须证明自己持有 owner key，而 owner key 是在**首次配对时由 Meta 签发的 ownership receipt** 换来的。这是设备信任根，绕不过去（除非走路线 C 改固件）。所以：

- 现实定义 = **一次性配对 + 之后零回传**。
- 配对那一次用的账号，建议单独一个，不要用主账号（它会留下设备归属记录）。
- 配对完成后，Visor 的日常链路里没有任何 Meta 服务器参与：照片走 Wi-Fi Direct 导入，语音走你配的 endpoint，全部落在局域网内。

## 固件与版本注意事项（技术层面）

- **不要随手升级固件**。126 是“可以装未签名 DAT”的最后窗口，127 起要打 MobileConfig 补丁，更高版本可能直接封死。
- 抓一次 OTA 更新包并留档，等于给自己留了回滚弹药。
- Visor 是 AGPL-3.0：自己用、改、自建都没问题；分发二进制要开源。
- 桥这一层不接触设备密钥，它只是 WebSocket 的转发器；token 泄露等于别人能操作你的眼镜，`access_key` 别省。

---

## 文件清单

```
meta-gen2/
├── config.example.json       # 复制成 config.json，填门地址/token/模型
├── README.md
├── BUILD-IOS.md              # 「让安卓彻底消失」runbook（无 Mac 也能出 ipa）
├── PROTOCOL-NOTES.md         # 字节级协议笔记（握手、KDF、DataX 帧）
├── bridge/
│   ├── server.py             # HTTP API + PWA 托管（stdlib only）
│   ├── visor_client.py       # 手写 WebSocket + JSON-RPC 客户端
│   ├── mock_visor.py         # 假网络门，用于无设备自测
│   └── web/index.html        # iPhone PWA
├── tools/adb_export_owner.py # 从一次性安卓里把 owner key 抠出来
├── visor-patch/OwnerExport.kt# 自己编 Visor 时加的软件 key + 导出补丁
├── ios/
│   ├── AirShield.swift       # 协议栈（DataX 帧、握手、KDF、AES-CBC+HMAC）
│   ├── OwnerKey.swift        # owner key 导入 + NONEwithECDSA 签名
│   ├── App.swift             # 客户端骨架（BLE 扫描 / 连接 / L2CAP）
│   └── project.yml           # XcodeGen 工程描述
└── .github/workflows/ios.yml # 云端 macOS 编译出未签名 ipa
```
