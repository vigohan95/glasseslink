# 用眼镜自己的声音念自定义模型的回答

一句话：**那不是云端的一个"语音服务"，是眼镜里的 TTS。** 想让回答听起来和原版助手一样，只有一条路——把文字交给眼镜，让它自己念。

## 1. 声音从哪来

| 层 | 谁发声 | 说明 |
| --- | --- | --- |
| 眼镜内 TTS | 眼镜 | 声音、"嗯/好的"这类语气、停顿都在固件里；语言与音色由设置项决定 |
| 手机合成后推音频 | 手机 | 走 `ttsBufferConfig` + `streamAudio`，是**你的**声音，不是它的 |
| 云端语音合成 | 云端 | 同样不是它的声音 |

所以要"用回 Meta 的女声"，必须走第一行。

## 2. 音色由哪个设置决定

设置目录里（`settings.tsv`，svc31 字段号）：

| 键 | 字段 | 类型 | 默认值 | 用途 |
| --- | ---: | --- | --- | --- |
| `assistant_voice_id` | 4 | str | `en_US.58` | 助手回答的音色 |
| `live_caption_voice_id` | 78 | str | （空） | 字幕的音色 |
| `live_translation_voice_id` | 77 | str | （空） | 翻译的音色 |
| `live_ai_voice_only` | 107 | bool | false | 只出声不显示 |

值的格式是 `语言_地区.编号`，例如 `en_US.58`。`58` 就是具体那个音色。
**换个编号就是换个声音**——想找女声，就逐个试（写入后让眼镜念一句短句即可听出来）。

约定：以 `3p_` 开头的是"合作方音色"，这种音色下**手机负责发声**（`foreign = true`），眼镜不念。
所以要"眼镜自己念"，别选 `3p_` 开头的值。

## 3. 完整链路（让眼镜念出任意文字）

```
① 确保 assistant_voice_id = en_US.<n>（非 3p_）
② 建立会话并完成注册（svc15，见 12-assistant-stack.md）
③ 收到一轮提问（ev337 或 ev71）
④ 本地/云端模型生成回答文本
⑤ 发 ev53 voiceActionResponse（VARM，把文本塞进模板；streamed 标志置 false）
⑥ 发 ev60 interactionComplete（同一段文本，streamed=false）
   → 眼镜用 assistant_voice_id 指定的音色念出来
```

关键点：

- **VARM 与 ev60 必须成对**：只发 ev60 不响；只发 VARM 会停在一半。
- VARM 里 `streamingBackTts`(6) 与 `isUsingPartialResponseStreaming`(14) 要置 **false**，表示"后面不推音频，你自己念"。
- VARM 的 `voiceId` 字段（模板里的 `old[13]`）填当前音色 id；`onGlasses=true`。
- 文本长度：单轮建议 ≤ 200 字；更长的拆成多轮，每轮都走 ⑤⑥。

## 4. 代码落点（我们仓库里的对应实现）

| 环节 | 文件 |
| --- | --- |
| 音色写入 | `ios/SettingsView.swift`（写 `assistant_voice_id`） |
| VARM 模板替换 | `ios/Varm.swift`（`VarmSplice.replace` 改 interactionId / transcript / answer / voiceId） |
| 一轮回答 | `ios/Assistant.swift` 的 `complete(interaction:text:transcript:followUp:)`（先 53 后 60） |
| 模型调用 | `ios/App.swift` 的 `ModelClient`（OpenAI 兼容 `/chat/completions`） |

顺序上唯一容易错的地方：**VARM 必须在 ev60 之前发出**，且两者用同一个 `interactionId`。

## 5. 想听不同的声音，怎么试

1. 连上眼镜，进「设备 → 全部设置」，找 `assistant_voice_id`（或直接读设置表里的字段 4）；
2. 依次写 `en_US.10`、`en_US.20`、`en_US.30`…`en_US.60`，每写一次让助手回一句"你好"；
3. 记下听起来是女声且自然的那个编号，固定下来。

注意：写设置后要**读回确认**（svc31 的 ack 恒为成功，不可信）。

## 6. 三种"用回原声"的边界

| 想要 | 能不能 |
| --- | --- |
| 让回答用眼镜原声念 | ✅ 上面这套 |
| 让眼镜念**别人**的声音（克隆音色） | ❌ 声音在固件里，不能替换 |
| 把眼镜的声音接到手机扬声器播放 | ⚠️ 只能"眼镜念、手机听"（近场拾音），音质差，不建议 |
| 用云端合成模仿那个音色 | ⚠️ 可以很像，但不是同一个；且要额外费用 |

## 7. 提示

- 眼镜念之前通常有一声提示音，这是固件行为，无法去掉；
- 如果回答里含代码、URL，读起来会很怪，建议清洗成口语（"链接"、"代码块"）；
- 多语言：`assistant_voice_id` 换 `zh_CN.<n>` 就是中文音色，念中文更自然。
