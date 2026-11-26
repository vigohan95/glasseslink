# 09 · 会话层：通道、中继、信任

出处：**R** `core/session/*`（8 个文件）· **P** 公开协议说明 · **O** 真机。

## 1. 文件职责

| 文件 | 职责 |
| --- | --- |
| `SecureLink.kt` | 握手、KDF、EndLinkSetup、收发加密帧 |
| `LinkFrames.kt` | 把"字节流"变成"帧序列"的读取端 |
| `DataXConnection.kt` | 一条解码后的 DataX 消息：头 + 载荷；关闭时带 `closedService` |
| `ChannelRegistry.kt` | 本地通道 ↔ 服务、对端通道 ↔ 服务 两张表 |
| `GlassesSession.kt` | 会话主体：把上层命令跑在会话自己的协程上 |
| `SubstreamRelay.kt` | 中继子流（一条链路上开多条逻辑流） |
| `TrustExchange.kt` | svc36 双向信任的结果与状态码 |
| `Events.kt` | 会话对外的状态事件（`LinkState` 等） |

## 2. 通道分配

```
本地通道：0x8002, 0x8003, …（bit15 = originator，表示"这端发起"）
对端通道：0x0002, 0x0003, …（无 bit15）
控制通道：0x8001 请求 / 0x0001 启用（固定，不参与分配）
```

规则：

1. 打开服务时先在 `ChannelRegistry` 登记，再发第一条带 `service` tag 的消息；
2. 对方用**它自己的**通道号回消息；收到的帧用 `对端通道 → 服务` 查用途；
3. 通道关闭用 tag 4（type + 关通道），关闭后该号可以回收；
4. 同一条消息大于 16383 字节（`DATAX_MAX_MESSAGE`）必须拆，接收端按长度拼回。

## 3. 中继子流

`SubstreamRelay.kt` 处理明文 `COMMAND` 帧（首字节 `0x80 | stream`）：

| 码 | 名称 | 语义 |
| ---: | --- | --- |
| 0 | OPEN | 打开一条子流 |
| 1 | LOST | 对端丢失 |
| 2 | REJECTED | 被拒 |
| 3 | NO_ROUTE | 无路由 |
| 4 | OPEN_TO_ADVERTISE | 打开并广播 |
| 5 | CONNECT | 连接到已广播的子流 |
| `0x80` | ADVERTISEMENT | 长格式：`code|0x80` + 2 字节长度 + 最多 1024 字节载荷 |

用途：Display 与手机之间转发（例如把手机的通知、媒体投到眼镜的屏幕上）。
普通机型基本用不到；接 Display 时才会碰。

## 4. 信任交换（svc36）

`TrustExchange.kt` 记录四个量：`txOk`、`rxOk`、对端状态码、诊断结论。

流程：

```
手机 → 眼镜：ENABLE_TRUST {1: SHA256(公钥 64B), 2: 签名 r‖s，3: capabilities=2}
眼镜 → 手机：ENABLE_TRUST_RESPONSE（同构）
双方各自回一条状态帧：0x1000 成功
```

- 签名对象是**通道绑定**：`SHA256( SHA256(对端挑战‖对端公钥) ‖ SHA256(我方 seed‖我方公钥) )`；
- 签名方式等价于 NONEwithECDSA（对 32 字节原文签），`s` 折叠到低半区；
- 失败码见 `01-link-setup.md` 的状态表（`0x1010/0x1042/0x1043/0x1044` 最常见）。

## 5. 状态机

```
DISCONNECTED ──connect──▶ CONNECTING ──CoC up──▶ HANDSHAKING ──keys up──▶ TRUSTING ──0x1000──▶ READY
      ▲                        │                   │                      │
      └────────fail────────────┴───────────────────┴──────────────────────┘
```

`Events.kt` 把每次迁移广播给 UI；UI 只依赖这五个状态，不依赖内部细节。

## 6. 顺序上的两个硬约束（都踩过）

1. **EnableEncryption 必须紧跟 RequestEncryption**，不能等对端先发（`SecureLink.open()` 的注释原文："Send our EnableEncryption IMMEDIATELY."）；
2. **EndLinkSetup 是第一条加密帧**，在 trust 之前（源码注释："EndLinkSetup is NOT sent here." + `finishLinkSetup()` "as the first encrypted DATA frame"）。

违反其中任何一条，真机表现都是"发出去没有回音"，只能从 12 秒超时里猜。
