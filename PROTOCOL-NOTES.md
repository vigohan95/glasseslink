# 协议笔记 · Ray-Ban Meta Gen 2

来源：<https://visor.macedonga.com/protocol/>（字节级公开文档）+ Visor 源码 `core/protocol`。
凡是标 `?` 的都是文档没写死、要用 Android 端 `files/wire.log` 对照确认的地方。

## 0. 分层

```
Radio      LE L2CAP CoC  |  Classic RFCOMM  |  TCP over Wi-Fi
Framing    4B DataX 头 + 4B/tag
AirShield  ECDH(P-256) → AES-256-CBC + HMAC-SHA-256（逐帧）
DataX      channels → services → message types
Trust      每次连接证明持有 owner key（svc36）
Services   protobuf / Thrift compact / FlatBuffers / zstd
```

机型：Ray-Ban Meta / Oakley Meta = 产品号 258、262–266，device type 3 / 7；Display = 259 / type 5；Neural Band = 1537 / type 4。
硬件：Snapdragon **AR1 Gen 1** + **WCN7851**（Wi-Fi 7 + BT 5.3），佰维 eMCP。

## 1. 建链顺序

```
glasses → phone : RequestEncryption   (ch 0x8001, svc 5,  type 1)
phone  → glasses: EnableEncryption    (ch 0x0001,        type 2)
                  两个方向都发一遍
phone  → glasses: svc36 trust（签 channel binding）
双方             : EndLinkSetup (ch 0x8001, type 0x1000)
phone  → glasses : 回 status，mirror 到 ch 0x0001
之后              : 加密的 DataX 流量
```

两副眼镜 / 双链路时，一个 stream UUID 对应一条流，一个 link UUID 对应一次连接。

## 2. DataX 帧

```
80 62 80 01  81 00 00 05  02 00 00 01
└──┬──┘└─┬─┘ └────┬────┘ └────┬────┘
 长度   通道       tag 1       tag 2 (末)
```

- 长度 2 字节，最高位 = hasExtension，剩余 15 位是 payload 长度。
- tag 4 字节：id 字节（0x80 置位表示后面还有 tag），然后 16 位大端值；第 3 字节在样本里恒为 0 `?`。

## 3. RequestEncryption

| 字段 | 内容 |
|---|---|
| 1 | 64B 公钥（x‖y，**无 0x04 前缀**，大端定长） |
| 2 | 16B challenge |
| 3 | varint 0（secp256r1） |
| 4 | varint 31（params） |
| 5 | repeated key hints |
| 6 | quirks（1 = QCS7） |
| 7 | varint 16（AirShield 版本） |

实际报头样例（12B）：`80 62 80 01 81 00 00 05 02 00 00 01`。

## 4. EnableEncryption

| 字段 | 内容 |
|---|---|
| 1 | 64B 公钥 |
| 2 | 32B seed |
| 3 | 16B IV |
| 4 | varint u32 base seq |
| 5 | varint 31 |
| 6 | quirks |

报头样例（5B base）：`80 82 00 01 02 00 00 02`。

## 5. 密钥派生

```
salt_aes  = SHA256(nonce ‖ seed)
salt_hmac = SHA256(seed ‖ nonce ‖ "hmac_derive")
PRK       = HMAC-SHA256(salt_aes, S)          S = ECDH 的 32B x 坐标
key       = HMAC-SHA256(PRK, "AirShield" ‖ 0x01)     → 32B
```

- Multikey（0x04）关闭时，同一个 32B key 兼作 AES key 和 HMAC key（默认）。
- `params = 31`；Burbank Audio / Neural Band = 27。
- **quirks = 1 (QCS7)**：HKDF info 变成 136 字节 —— `"AirShield"` 补零到 128，再拼 LE u32 32、LE u32 256；MAC word 末字节变 1（`02 02 00 01`）。

## 6. Channel binding（svc36）

```
binding = SHA256( SHA256(glasses_challenge ‖ glasses_RequestEncryption_key)
                ‖ SHA256(phone_seed      ‖ phone_EnableEncryption_key) )
```

用 owner key 对 binding 做 `NONEwithECDSA`（裸 r‖s）签名，眼镜验签。owner key 来自首次配对时 Meta 签发的 ownership receipt —— 这是全链路唯一绕不开 Meta 的地方。

## 7. EndLinkSetup

明文 46 字节：

```
80 2A 80 01 02 00 10 00        # 头
08 01                          # field 1 = 1
12 10 <16B stream UUID>        # field 2
1A 10 <16B link UUID>          # field 3
```

两个 UUID 必须是 RFC4122 v4：`b[6] & 0xF0 == 0x40`、`b[8] & 0xC0 == 0x80`。不满足 → 眼镜静默回 `service_not_found`（很难查，先查这个）。

回给眼镜的 status 明文 8 字节：`80 04 00 01 03 00 10 00`（封包后 26B）。

## 8. Visor 网络门（VDK）

- adb 抽象 socket：`visor-kit`，`adb forward tcp:7333 localabstract:visor-kit`
- 网络门：`ws://<ip>:7333/rpc`，`Authorization: Bearer <token>` 或 `?token=`
- MCP：`http://<ip>:7333/mcp`；webhook 签名 `X-Visor-Signature: sha256=<hmac(sha256(token), body)>`
- OpenRPC：<https://github.com/macedonga/visor-kit/blob/main/protocol/api/openrpc.json>

| 方法 | 参数 | 备注 |
|---|---|---|
| `kit.hello` | `{protocol, kit}` | 返回 granted scopes / methods / topics |
| `glasses.status` | — | 电量、佩戴、链路 |
| `camera.photo` | `{import}` | 拍照并落盘 `Pictures/Visor` |
| `camera.video.start/stop` | `{kind}` | |
| `camera.live.photo` | — | 返回 `{mime, data}`；Live view 没跑时 `busy` |
| `captures.list` | — | |
| `captures.import` | `{id}` | 取字节，返回 base64 |
| feed `camera.live` | `{quality, frameRate, audio}` | quality: low 360×640 / medium 504×896 / high 720×1280 / full_hd 1080×1920；fps 2/7/15/24/30 |

失败码：`not_connected` / `busy` / `timeout` / `failed`。
`raw.send` / `raw.messages` 需要 Developer mode，且拒绝 svc 36/54/79/29。

## 9. iOS 约束清单

| 能力 | 状态 |
|---|---|
| LE L2CAP CoC | ✅ `CBPeripheral.openL2CAPChannel(PSM)`（iOS 11+），**PSM 数值见 radios-and-links 页 `?`** |
| RFCOMM | ❌ 第三方 app 不可用 |
| Wi-Fi Direct | ❌ 无 P2P API；只能眼镜自建 AP + 手动入网（或 NEHotspotConfiguration + hotspot entitlement）后走 TCP |
| AES-256-CBC | ⚠️ CryptoKit 只有 GCM，需 `import CommonCrypto` + `CCCrypt` |
| P-256 / SHA256 / HMAC | ✅ CryptoKit |
| owner key 存法 | 建议 Secure Enclave / Keychain（`kSecAttrTokenIDSecureEnclave`，签名为 ECDSA raw） |

`ios/AirShield.swift` 已实现：DataX 头/tag、protobuf 写出器、两个握手消息、KDF（含 QCS7 分支）、channel binding、EndLinkSetup + UUID 校验、AES-CBC + 逐帧 HMAC，以及状态机骨架。待补：MAC 拼接顺序 `?`、非 QCS7 MAC word `?`、L2CAP PSM `?`。
