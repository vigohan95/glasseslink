# Ray-Ban Meta（第二代）眼镜设置清单

GlassesLink「眼镜设置」页里每一项的作用、依据和取值来源。只收录同时满足三个条件的设置：

1. 固件确实读取它：设置表里标明固件解析该字段，或固件代码分析里有明确说明。
2. 效果发生在眼镜本身。
3. 不依赖 Meta App 或 Meta 云端。

依据来自 Visor 项目随附的两份固件分析数据：`settings.tsv`（每个设置的 svc31 字段号、类型、出厂默认值、固件是否解析）和 `settings_ui.json`（官方 App 里的名称、说明、可选值，以及分析者给出的可信度）。

写入方式有两种：

- **svc31**：固件自己的设置写入通道。写入后 App 会读回设置存储核对，读回一致才显示「已保存」。
- **设置存储（RLDrive）**：没有 svc31 字段的设置直接写进眼镜的设置存储，同样读回核对。

## Hey Meta 与语音

| 设置 | 作用 | 取值（出厂默认） | 写入方式 | 依据可信度 | 官方原文 |
| --- | --- | --- | --- | --- | --- |
| 语音助手<br>`assistant_enabled` | 关闭后眼镜不再响应「Hey Meta」，GlassesLink 也就收不到提问。 | 开 / 关（默认：关） | svc31 字段 2 | 高 | Meta AI：Turns Meta AI on or off on the glasses. |
| 「Hey Meta」唤醒<br>`wakeword_enabled` | 说「Hey Meta」开始一条语音指令。 | 开 / 关（默认：开） | svc31 字段 36 | 高 | "Hey Meta"：Say "Hey Meta" or "OK Meta" to start a voice command. |
| 唤醒提示音<br>`wakeword_sound_enabled` | 说完「Hey Meta」后眼镜会响一声，表示在听。 | 开 / 关（默认：开） | svc31 字段 37 | 中 | Wake sound：Your glasses will make a sound after you say "Hey Meta" or "OK Meta." |
| 免唤醒追问<br>`assistant_follow_up_enabled` | 回答结束后麦克风再听一小会儿，接着问不用再说「Hey Meta」。 | 开 / 关（默认：开） | svc31 字段 52 | 高 | Respond without "Hey Meta"：Your glasses' microphone will stay on and listen for another prompt for a brief period after your prompt is completed. You can skip saying "Hey Meta." |

## 拍摄

| 设置 | 作用 | 取值（出厂默认） | 写入方式 | 依据可信度 | 官方原文 |
| --- | --- | --- | --- | --- | --- |
| 拍摄键<br>`capture_button_short_long_press` | 拍摄键单按和长按分别做什么。 | 单按拍照，长按录像、单按录像，长按拍照（默认：单按拍照，长按录像） | svc31 字段 7 | 高 | Capture button：Swaps what a short and a long press of the capture button do: photo or video. |
| 视频画质<br>`resolution_and_framerate` | 日常用「标准」。高帧率（60 帧）这一档眼镜不做画面校正：画面更广、边缘弯曲（像鱼眼），每帧曝光更短，室内明显更暗、噪点更多。画质越高越耗电、越占空间。 | 标准 · 1080p 30 帧、高帧率 · 1080p 60 帧（画面不校正）、高分辨率 · 3K 30 帧（默认：标准 · 1080p 30 帧） | svc31 字段 109 | 高 | Resolution and frame rate：Changing resolution or frame rate affects battery life, storage, recording duration, and orientation. |
| 单段视频最长<br>`video_duration_ms` | 录到这个时长自动停止。这是官方给的几档；过热和电量由眼镜另外的保护机制管。 | 30 秒、1 分钟、3 分钟、5 分钟（仅标准画质）、10 分钟（默认：3 分钟） | svc31 字段 17 | 高 | Video length：Choose a maximum video length. These limits help optimize for sharing and space. |
| 视频防抖<br>`eis_mode` | 中（默认）：防抖并校正水平；强：画面最平稳；弱：保留动作感；自动：按画面运动自己选。 | 自动、强、中、弱（默认：中） | svc31 字段 108 | 高 | Video stabilization：How the camera stabilizes video. |
| 灯光防闪烁<br>`flicker_reduction_mode` | 室内灯光下视频出现明暗条纹或闪烁时，按当地电网频率选：中国大陆、香港是 50 Hz，台湾、美国是 60 Hz。 | 自动、50 Hz、60 Hz（默认：自动） | svc31 字段 223 | 中 | Flicker reduction：Sets the flicker reduction mode the camera uses for capture. |
| 减少运动模糊<br>`motion_blur_reduction_enabled` | 录像时减少快速移动造成的拖影。 | 开 / 关（默认：开） | svc31 字段 220 | 中 | Motion blur reduction：Turns motion blur reduction on or off for video. |
| 镜头遮挡提醒<br>`occlusion_detection_enabled` | 头发或帽檐挡住镜头时提醒你。 | 开 / 关（默认：开） | svc31 字段 12 | 中 | Occlusion detection：Detects when something blocks the camera view. |

## 声音

| 设置 | 作用 | 取值（出厂默认） | 写入方式 | 依据可信度 | 官方原文 |
| --- | --- | --- | --- | --- | --- |
| 提示音音量<br>`notification_volume` | 眼镜提示音的音量，不影响音乐和通话。 | 0–100%（原始值 55–127）（默认：90） | svc31 字段 5 | 高 | Notification volume：Level of notification sounds on the audio system's absolute scale. |
| 自适应音量<br>`avc_enabled` | 根据周围噪音自动调整眼镜音量。 | 开 / 关（默认：关） | svc31 字段 80 | 中 | Adaptive volume：Automatically adjust glasses volume based on your environment. |

## 佩戴与触控

| 设置 | 作用 | 取值（出厂默认） | 写入方式 | 依据可信度 | 官方原文 |
| --- | --- | --- | --- | --- | --- |
| 佩戴检测<br>`wear_detection_enabled` | 摘下眼镜时暂停功能，戴上后恢复。 | 开 / 关（默认：开） | svc31 字段 38 | 中 | Wear detection：Features will pause when you take off your glasses and resume when you put them back on. |
| 摘下时暂停音乐<br>`auto_play_pause_on_don_doff` | 摘下眼镜时音乐自动暂停，戴上后继续。 | 开 / 关（默认：开） | svc31 字段 6 | 高 | Pause music when glasses come off：Pauses music when the glasses come off. |
| 触控板长按<br>`tap_and_hold_mapping` | 手指按住镜腿触控板时做什么。其他选项要靠 Meta App 绑定音乐服务，这里不列。 | 不做任何事、唤醒语音助手（默认：唤醒语音助手） | svc31 字段 29 | 高 | Tap and hold action：Chooses what a touchpad tap and hold does, such as opening Meta AI or playing music. |

## 来电

| 设置 | 作用 | 取值（出厂默认） | 写入方式 | 依据可信度 | 官方原文 |
| --- | --- | --- | --- | --- | --- |
| 来电播报<br>`user_setup_ica_toggle_enabled` | 来电时眼镜读出是谁打来的。 | 开 / 关（默认：关） | svc31 字段 176 | 高 | Announce calls：Hear who's calling you. |

## 固件更新

| 设置 | 作用 | 取值（出厂默认） | 写入方式 | 依据可信度 | 官方原文 |
| --- | --- | --- | --- | --- | --- |

## 没有收录的设置及原因

| 设置 | 原因 |
| --- | --- |
| 位置服务、Meta AI 使用位置 | 眼镜自己没有定位，位置由 Meta App 从手机提供；用 GlassesLink 时没有来源。 |
| 云端处理照片视频、保存语音录音和文字记录、共享额外数据 | 只影响 Meta 云端和 Meta App 的行为；GlassesLink 不经过 Meta 云端。 |
| 说话时推迟通知、暂停播报的默认时长、日历提醒 | 通知由 Meta App 推给眼镜；没有 Meta App 就没有可推迟的通知。 |
| 指示灯亮度 | 固件分析注明：LED 代码使用固定亮度，这个值不起作用。 |
| 省电模式 | 固件分析注明：眼镜上没有任何代码读取它，只是被存储和同步。 |
| 自动水平校正、遮挡自动裁剪、照片方向、音频降噪 | 都是 Meta App 在手机上做的后期处理，固件不解析这些字段。GlassesLink 自己实现了照片和视频的摆正。 |
| 动作按钮相关 | 第二代 Ray-Ban 没有动作按钮（那是 Oakley Meta Vanguard 的按键）。 |
| 显示屏、腕带手势两组 | 只对带显示屏的型号和神经腕带有效。 |
| 触控板长按的音乐选项（Spotify、Apple Music 等） | 需要 Meta App 绑定对应的音乐服务才有效。 |

## 录像时长为什么有上限

- 普通录像的时长由 `video_duration_ms` 决定，官方只提供 30 秒、1、3、5、10 分钟，其中 5 分钟注明仅限标准画质。Meta 的说明是「这些限制有助于分享和节省空间」。
- 上限不是硬件能力：固件里另有一种拍摄模式（行车记录）的上限配置为 30 分钟。
- 发热和电量由独立的机制保护：固件有皮肤温度监控和电量监控，过热会停止甚至关机。`sg_disable_thermal_shutdown`（禁用过热关机）是测试用开关，GlassesLink 不会写它。
- 普通录像是否接受大于 10 分钟的值，固件分析里没有结论，需要真机验证。设置页底部的「实验：更长的录像」就是为此准备的，验证有效后才会并入正式列表。
