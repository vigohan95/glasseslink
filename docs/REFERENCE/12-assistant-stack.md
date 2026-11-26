# 12 · 助手栈（svc15 及周边）

出处：**R** `core/assistant/*`（31 个文件）· **P** · **O**。

## 1. 组成

| 文件 | 职责 |
| --- | --- |
| `Oxide.kt` | svc15 协议：注册、事件、envelope、回答体 |
| `Assistant.kt` | 编排：一轮问答的生命周期 |
| `LiveAi.kt` | Live AI 会话（边看边问） |
| `GlassesEars.kt` | 眼镜把麦克风流给手机做识别（整段 Live AI / 追问） |
| `HeadsetMic.kt` | 眼镜当蓝牙耳机的麦克风（16 kHz 16-bit 单声道 PCM） |
| `Voice.kt` | Opus 包与时长；把文字变成眼镜能播的声音 |
| `CloudTts.kt` | 云端语音合成与失败原因 |
| `SpeechModels.kt` | 手机端识别/播报能力检查 |
| `CustomWakeWord.kt` | 自定义唤醒词注册 |
| `GlassesPhotos.kt` | svc53：问答时让眼镜拍一张 |
| `Hearing.kt` | svc31337：对话聚焦、助听校正 |
| `Timers.kt` | svc53210 TAR：计时器/闹钟 |
| `Brain.kt` | 模型调用与工具循环 |
| `GlassesTools.kt` | 眼镜能力暴露给模型（名称、帮助、schema） |
| `Handset.kt` / `Phone.kt` | 手机侧能力（导航、音乐、通讯录） |
| `Providers.kt` / `Models.kt` / `Refusals.kt` | 供应商、模型列表、拒绝原因 |
| `ChatGptPlan.kt` | 用 ChatGPT 订阅额度（OpenAI 的开源应用流程） |
| `Messaging.kt` | 从通知里接住对话 |
| `Diary.kt` | 记录一问一答（下一轮的上下文） |
| `McpHub.kt` / `McpServer.kt` / `McpConnection.kt` / `Transports.kt` / `OAuth.kt` / `ServerIcons.kt` | MCP 客户端：工具发现、鉴权、调用 |
| `Apps.kt` | 手机上能自己回答问题的 App（VDK 语音入口） |
| `AssistantConfig.kt` | 配置（供应商、模型、密钥——密钥只在应用私有存储） |

## 2. svc15 消息号

**手机 → 眼镜**：`11` pairedDeviceAndroid、`1000` initMessageRequest、`1002` segmentedHeader、`1003` segmentedBuffer、
`1010` netEvent、`1016` deviceActive、`1023` startInteraction、`1026` runningLocale、`1027` incomingNotificationResponse、
`1028` timeStretchEnabled、`1029` numOfDevicesPaired、`1031/1032` airResources 不可用/可用、`1033` ttsBufferConfig、
`1036` mmaiEnabled、`1037` assistantReady、`1038/1039` liveMode 不可用/可用、`5000` initStreamRequest、
`5002` streamHeader、`5003` streamAudio、`5005` streamStatus、`6000` streamEnd、`6001` streamConsumed、
`9000` envelope、`9001` envelopeAck。

**眼镜 → 手机（事件，常走 envelope）**：`52` finalTranscription、`53` voiceActionResponse、`55` actionFulfillmentRequest、
`57` fulfillmentRequest、`59` mwaCloseRequest、`60` mwaComplete（即 interactionComplete）、`63` keepMwaAlive、
`65` mmaiInteractionRequest、`71` startOfUserSpeech、`73/74` remoteImageCapture 请求/响应、`261` liveAiAck、
`262` clientFirstFrame、`263` serverConnectionStatus、`265` interactionCreationSuccess、`307` deviceVoiceState、
`323` wwVerificationComplete、`333` sessionStateBroadcast、`337` startRemoteInteraction、`339` sessionStateUpdate、
`341` externalTranscriptionRequest、`360` remoteInteractionComplete、`388` ttsStartInfo、`389` ttsEndInfo、
`392` keepAirSessionAlive、`396` carbonCrossSurface。

## 3. 注册序列

```
开 assistant-m0 ─▶ 1000 initMessageRequest
                    ◀─ 1001 initMessageResponse（含协议版本）
开 assistant-s0 ─▶ 5000 initStreamRequest
                 ─▶ 11 pairedDeviceAndroid（"<now>-<uuid>"）
                 ─▶ 1031/1032/1038/1039 airResources 四条（各带 uuid）
                 ─▶ 1016 deviceActive（空）
                 ─▶ 1029 numOfDevicesPaired（"1"）
                 ─▶ 265 / 263 / 263 / 262 四条 NetEvent（announce）
```

`netEvent(id, body)` 的编码：**Thrift compact**，`{1: id, 2: body, 3: compressed, 4: 长度(I64), 11: false}`。
`4` 号字段必须是 **I64**，写 I32 会被静默丢弃（这一步错会表现为"眼镜完全不回应"）。

## 4. 一轮问答

```
ev337 startRemoteInteraction（或 ev71 startOfUserSpeech）
   ──▶ ev52 finalTranscription {1 text, 8 interaction, 13 endMs}
        ──▶ 本地/云端模型
             ──▶ ev53 voiceActionResponse（VARM：让眼镜自己念）
                  ──▶ ev60 interactionComplete {1 interaction, 2 1000, 4 {1 text, 2 1, 3 expectsAnswer, 7 false, 8 false, 11 followUp}}
```

**VARM 不是重新编码**：它是拿一段模板（561 字节）做字符串替换 —— interactionId、transcript、answer、voiceId，
并把 `streamingBackTts`(6) 与 `isUsingPartialResponseStreaming`(14) 置 false（表示"后面不推音频，你自己念"）。
替换时要注意 compact 编码里 **bool 的负载长度为 0**，用"长度>起点"判断会跳过 bool。

## 5. 其它通道

| 服务 | 用途 | 触发 |
| --- | --- | --- |
| svc53 | 让眼镜为问题拍一张照片 | 视觉类问题 |
| svc31337 hearing | 对话聚焦、助听校正 | 设置里开启 |
| svc53210 TAR | 计时器/闹钟（眼镜转给手机） | "设一个 5 分钟计时" |

## 6. 本地模型接入

`Brain.kt` 与 `Providers.kt` 的结构对所有 OpenAI 兼容服务都一样：

```
POST {base}/chat/completions
Authorization: Bearer {key}
{model, messages:[…], max_tokens}
```

图片用 `content: [{type:"text"},{type:"image_url",image_url:{url:"data:image/jpeg;base64,…"}}]`。
真机实测：4B 级视觉模型在 CPU 上 25–40 秒/轮，够用但不算快；显存/内存允许时可以换大模型。
