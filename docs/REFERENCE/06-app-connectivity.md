# 06 · 手机 app ↔ 眼镜：连通性全景

这一份是**全量地图**：手机侧与眼镜之间的每一条链路、每一个服务、每一个应用级流程。
出处：**P** 公开协议说明 · **R** 参考实现源码结构（Visor，881 个 Kotlin 文件，模块划分见下）· **O** 真机观测。
表里的「我们」= GlassesLink iOS。

---

## 1. 分层

```
应用层   通知转发 · 相册 · 拍摄 · 取景 · 助手 · 设置 · 字幕/提词器 · 时钟 · OTA
   ↑
服务层   svc5   svc15  svc18  svc20  svc28  svc29  svc31  svc33  svc36  svc56  svc72  svc100  svc150  svc51350  svc52822
   ↑
会话层   通道注册表 / 中继子流（COMMAND 帧）/ 多路复用
   ↑
加解密   AirShield：ECDH → 双向密钥 → AES-256-CBC + HMAC-SHA-256 每帧
   ↑
分帧     DataX：4 字节头（长度 14 位 + 通道）+ tag 区
   ↑
传输     BLE L2CAP CoC（PSM 0x80/0x81） · Classic RFCOMM · TCP over Wi-Fi
```

参考实现的模块划分（`core/`）：`transport` 9 · `session` 8 · `connection` 16 · `media` 32 · `settings` 6 · `assistant` 31 · `identity` 36 · `protocol` 15。

## 2. 传输

| 通道 | 何时用 | 备注 |
| --- | --- | --- |
| BLE L2CAP CoC | 默认 | PSM `0x80`（眼镜）/`0x81`（Burbank Audio、Neural Band）；从 GATT 特征读，不写死 |
| Classic RFCOMM | 旧机型 / 备用 | SDP `8b0d2687-42a4-44cb-9436-fba3b9b96de2`，channel 7 |
| TCP over Wi-Fi | 导大文件、取景 | Wi-Fi Direct 组（手机当 GO）或眼镜自建网络；蓝牙链路约 120–165 KB/s，Wi-Fi 约 10 MB/s |

Wi-Fi 切换的规矩：先在 svc18 发 `MT_LINK_CHANGE(0x86) = <handle>:7`，等 `0x87`，再建立 TCP；否则眼镜会把同一份素材重传。

## 3. 会话建立（细节见 `01-link-setup.md`）

1. 打开 CoC；
2. 背靠背发 `RequestEncryption`（带 service tag）与 `EnableEncryption`（不带 service tag）；
3. 读至多 8 帧，收对端两条（顺序可变），派生双向密钥；
4. 发第一条加密帧 `EndLinkSetup(46B)`；
5. svc36 `ENABLE_TRUST`：公钥摘要 + 对通道绑定的签名；
6. 之后所有服务走加密通道。

## 4. 服务清单（含实现状态）

| svc | 名称 | 主要消息 | 我们 |
| --- | --- | --- | --- |
| 5 | link setup | 1 请求 / 2 启用 / 0x1000 结束 | ✅ |
| 15 | assistant | 1000/1001 注册、5000/5001 流、9000/9001 envelope、事件 52/53/60 等 40+ | 🟡 注册 + 转写 + 回答 + 朗读，事件子集 |
| 18 | captures | 1 枚举 / 6 记录 / 2 结束 / 0x83 请求素材 / 0x86 切链路 / 3 删除 / 0x82 消失 | ✅（删除未接） |
| 20 | airship | 1 提供 / 2 游标 / 4 数据 / 5 校验 / 6 完成 / 7 drop / 3 reset / 8 removed / 10 队列空 / 11 停止 / 12 多作用域 | ✅ |
| 28 | status + 快门 | 1000 订阅 / 2005 状态流（2005–2044）/ 2000–2003 应用生命周期 / 2300 SNIntent | ✅ |
| 29 | OTA | 固件与资源包 | ✅ 可拦截（回 `0xC001`） |
| 31 | settings | 2 写单字段 / 3 ack | ✅ |
| 33 | RLDrive | 键值存储（分块） | ✅ |
| 36 | identity / trust | 0x1000/0x1001、0x2000–0x2005、0x3000/0x3001 | ✅ |
| 56 | lease | 应用运行租约 | ❌ |
| 72 | translation | 翻译会话 | ❌ |
| 100 | peer_build_info | 构建指纹、序列号、经典蓝牙地址、发布版本（字段 9） | ❌ |
| 150 | conn_device_lease | Display 向手机索取配对带 | ❌ |
| 51350 | media_streaming_control | 取景串流（见 `03-services.md`） | ✅ |
| 52822 | wireless_input | Neural Band 的整套 RPC | ❌ |

## 5. 应用级流程

### 5.1 第一次配对与"成为主人"

1. 手机登录厂商账号（OAuth），拿 user token；
2. 向 `graph.facebook-hardware.com/pair_request` 提交：设备证书、序列号、设备 nonce、我方公钥，body gzip；
3. 收到 `pending_ownership_receipt`；
4. 眼镜进入配对模式（折叠 + 长按拍摄键 → 指示灯闪蓝）；
5. 链路建立后 svc36 `START_CHANGE_OWNER`（部分固件要求按一下拍摄键）；
6. 再向 `pair` 提交 `device_pending_ownership_receipt`，拿到 `final_ownership_receipt`；
7. `FINISH_CHANGE_OWNER` 收尾；此后只需私钥即可通过 trust。

### 5.2 通知转发

眼镜作为"第二屏"接收手机通知：Android 侧是 `NotificationListenerService`，把通知按 svc15 的通知事件（`MT_INCOMING_NOTIFICATION_RESPONSE`）投给眼镜；iOS 侧没有等价机制，**这是平台差异，不是实现难度**。

### 5.3 相册与素材

枚举（svc18）→ 记录 → 请求素材（`0x83`）→ 眼镜用 svc20 推文件 → 手机回游标 → 校验 adler32 → 回 drop。
视频的封面帧来自素材数组里的 still；视频本身是 `KIND_VIDEO` 资产。

### 5.4 拍摄

svc28 `SNIntent`（2300）与眼镜自己的快门键等价：
拍照 `action.robusta.capture`；录像 `AGENTIC_START_RECORDING` / `CLOSE_APP_CAPTURE`；`capture_type` 可给 `video`/`hyperlapse`。
应用生命周期用 `MT_START_APP`/`MT_STOP_APP`（2000/2002）包裹，返回码 `1` 成功、`12` 已在运行、`6` 电量不足、`7` 过热。

### 5.5 取景

`START_APP(live=3)` → `sessionSettings(27)` → `configureVideo(5)` → `configureAudio(3)` → `control(7, START)`；
服务器回 `codecConfig(1)` + `videoBuf(10)/videoEnd(12)`；中途拍照用 `userEvent(23)` 触发 `photoBuf(34)/photoEnd(35)`（HEIC）。
码率阶梯 360p 600k → 1080p 4M，见 `03-services.md`。

### 5.6 助手

svc15：注册（`assistant-m0`/`assistant-s0`）→ 资源声明 → envelope（9000/9001）→ 事件
`startRemoteInteraction(337)` / `startOfUserSpeech(71)` / `finalTranscription(52)` / `voiceActionResponse(53)` / `interactionComplete(60)`。
回答要让眼镜自己念：先发 ev53（VARM，模板替换 interactionId、transcript、answer、voiceId，并把 `streamingBackTts`/`isUsingPartialResponseStreaming` 置 false），再发 ev60。

### 5.7 设置

两套：
- 有字段号的（253 项）走 svc31，写单字段，ack 恒成功 → 必须读回；
- 无字段号的走 svc33（RLDrive）键值存储。
设置目录（371 项、18 组）来自参考实现的数据文件。

### 5.8 时钟与身份

svc100 `DeviceInfoRequest {1: Timestamp{sec,nanos}, 2: 时区 id, 3: 请求 uuid}` —— 手机把时间写给眼镜（`Clock.kt`）。
`DeviceInfo.kt` 还能读到构建指纹、序列号、经典蓝牙地址、发布版本（字段 9）。

### 5.9 其它（参考实现里有、我们没做）

| 能力 | 说明 |
| --- | --- |
| 字幕（Captions） | 把转写实时投到眼镜/手机屏幕 |
| 提词器（Teleprompter） | 分段推文本给 Display |
| 金丝雀（Canary） | `GET_INFO`/`APP_INFO` 探活，用于判断链路与固件是否应答 |
| 租约（svc56） | 应用在眼镜上运行需要租约 |
| 翻译（svc72） | 眼镜侧翻译会话 |
| 无线输入（svc52822） | Neural Band 手势 RPC |
| 中继子流（COMMAND 帧） | `[0x80|stream][code]`，`OPEN/LOST/REJECTED/NO_ROUTE/OPEN_TO_ADVERTISE/CONNECT/ADVERTISEMENT`，多用于 Display 与手机间转发 |
| MCP 服务器 | 把眼镜能力暴露给外部模型（app 层） |
| RTMP 推流 | 把取景推到直播服务（app 层） |

## 6. 云侧接口（仅首次配对用到）

| 用途 | 端点 |
| --- | --- |
| OAuth 授权 | `accounts.meta.com/oidc/` |
| code 换 token | `api.accounts.meta.com/native/oidc/token-exchange/` |
| FRLA | `ar.graph.meta.com/login` |
| 配对与所有权 | `graph.facebook-hardware.com/pair_request`、`/pair` |
| 镜框款式、语言包 | `ar-genai.graph.meta.com/graphql` |

日常使用不触碰以上任何一条；我们的实现只在"成为主人"时走一次。

## 7. 覆盖矩阵（我们 vs 全量）

| 层 | 覆盖 |
| --- | --- |
| 传输 | BLE L2CAP ✅ / RFCOMM ❌ / TCP over Wi-Fi ❌ |
| 会话 | 握手、加解密、通道注册 ✅ / 中继子流 ❌ |
| 服务 | 18、20、28、29、31、33、36、51350 ✅ / 15 🟡 / 56、72、100、150、52822 ❌ |
| 应用 | 相册、拍摄、取景、助手、设置、状态、Owner 迁移 ✅ / 通知转发（iOS 无此机制）、字幕、提词器、租约、翻译、无线输入 ❌ |

**结论**：与"日常使用"直接相关的链路已经全覆盖；未覆盖的四类都是 Display / Neural Band / 直播 / 系统级通知这些场景，接第二个品牌时会用到，但不影响当前机型。
