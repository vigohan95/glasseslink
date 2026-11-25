# GlassesLink 对照 Visor 的验收清单

对照 Visor 3.1.0、OpenGlasses 和 Meta DAT iOS 1.1.0。GlassesLink 的真机记录来自 Ray-Ban Meta Gen 2 和 iPhone，最新日志对应 0.97（97）。表中分别写明 0.98 的代码进度和真机验收要求。 [Visor 3.1.0](https://github.com/macedonga/visor/releases/tag/v3.1.0) · [OpenGlasses](https://github.com/straff2002/OpenGlasses/tree/5b45501f6b8c69b6dfa0a090c44d6d474899e8c5) · [Meta DAT 1.1.0](https://github.com/meta/meta-wearables-dat-ios/releases/tag/1.1.0)

| 功能 | 0.98 的实现进度 | 功能对齐时的验收结果 |
| --- | --- | --- |
| 首次配对、主人验证、日常连接 | Gen 2 已在真机通过主人验证。新版区分 iPhone 名称、广播名称和历史记录。对端公钥经验证后才用于关联不同的系统识别码。 | 首次配对后可直接打开 App 连接。眼镜重启、开合镜腿、离开后返回及 iPhone 蓝牙恢复后都能重新取得加密会话。手动断开可取消重连。 |
| 设备首页 | 有设备列表、认证状态、眼镜与充电盒读数、可用空间和眼镜音量。0.97 日志已有充电盒上报。 | 数据与真机一致。未上报值可识别，区分充电、睡眠、休眠后失联和正在录像。 |
| 系统音频 | 已有独立的眼镜音频连接请求、测试音、实际媒体输出，以及 HFP 和 LE 音频麦克风诊断。 | 以实际听到测试音和录音样本证明双向音频。覆盖 iPhone 锁屏、来电、路由切换与重新连接后的恢复。 |
| App 拍照与录像 | 0.97 记录了开始、停止录像的确认和新目录条目。0.98 拍摄前后比对有原件的目录条目，允许眼镜延迟写入。手机计时控制自动停止。 | 手机快门和眼镜按键都能生成可导入的照片、可播放的视频。用实际时长、编码、画质和音轨验证设置。 |
| 相册与媒体 | 有眼镜目录、本机网格和视频播放、选择或批量删除待导入原件。蓝牙导入校验文件。0.97 已收到眼镜热点配置，iOS 自动加入被拒后回退，3.28 MB 耗时 110.6 秒。0.98 会保留当前热点并提供手动加入。 | 先实测 iOS 加入同一热点并收到完整原件，再测大文件和整批只入网一次。覆盖取消、断线重试、重启后的重复导入、系统相册保存失败，以及导入过程中已有素材仍可播放。 |
| 实时取景 | 0.97 真机已收到 HEVC 参数和帧，画面仍黑。0.98 改用即时显示、等待关键帧恢复，并区分收到帧和可显示。 | 验证实际出画、首帧及最长停顿，覆盖连续启动、暂停恢复和停止后的控制连接。再测 Wi-Fi 预览、抓拍、录制和回放。 |
| 模型与助手 | Claude 直连及 OpenAI 兼容地址、手填模型 ID 已有配置入口。0.98 新增点按录音、本机转写、确认文字后发给当前模型。Hey Meta 使用独立的注册与转写链路。 | 分别验证接口、文字问答、眼镜麦克风录音、唤醒、转写、模型完成和回播。继续验证追问、会话历史、当前画面和故障恢复。 |
| 常用及高级设置 | 有读写入口和本地显示规则，写入以真实读回判定。 | 每款设备呈现适用选项。变更有写入、读回和实际效果，补齐语言包和固件能力管理。 |
| 通知及系统入口 | 待实现。 | 基于受支持的配件与地区能力实现经用户授权的通知播报。小组件、快捷指令、控制中心和取景实时活动按 iOS 能力落实。 [Accessory Notifications](https://developer.apple.com/documentation/accessorynotifications) · [App Intents](https://developer.apple.com/documentation/appintents/widgets-live-activities-and-controls) |
| 多副设备与跨品牌 | 目前保存一副眼镜的连接和主人资料。 | 分设备保管身份、设置和素材状态，按具体型号验收 Ray-Ban Meta、Oakley Meta 及后续品牌，明确当前固件可用功能。 |
| Display 与 Neural Band | 待实现，需要对应实物和兼容固件。 | Display 提词、字幕、翻译、Briefing、应用、联网和辅助输入各有实际运行结果。Neural Band 的配对、手势、振动和数据共享独立验证。 |
| 开发接口及自动化 | 待实现。 | 应用、快捷指令及外部客户端可经授权访问配件能力。用户可查看并撤销每个客户端的权限。 |

## 从公开反馈提取的回归场景

| 用户反馈 | GlassesLink 需要反复验证的场景 |
| --- | --- |
| Visor 3.0.4 在一台 Xiaomi 手机上遇到眼镜重启后蓝牙音频可用、控制链路始终失联。 [连接 #114](https://github.com/macedonga/visor/issues/114) | 以握手、主人验证及一次控制请求成功判定恢复。分别测眼镜断电、超出范围、蓝牙开关、从系统挂起回到 App，以及用户手动停止后是否安静。 |
| Visor 早期用户报告取景数秒后卡住，再打开收到服务错误。 [取景 #22](https://github.com/macedonga/visor/issues/22) | 记录首帧、持续帧间隔、耗电和温升。分别验证停止、异常断开、连续重新进入。取景失败后相册和其它控制仍能用。 |
| Visor 1.4.2 有文件已入手机而相册仍显示传输中的报告，维护者在 1.4.4 修复。Reddit 用户报告只能走蓝牙，视频导入很慢。 [相册 #41](https://github.com/macedonga/visor/issues/41) · [Reddit 讨论](https://www.reddit.com/r/MetaGlasses/comments/1x56b2d/comment/ph3wo8d/) | 以同一批小图、短片、大视频分别测首字节和完成时间。拔断链路后重试，核对系统照片、校验、进度退出与重启后的导入记录。 |
| Visor 1.4.8 有时长选 10 分钟而固件仍为 3 分钟的报告。另有视频设置收到回复但输出参数未变的反馈。 [时长 #72](https://github.com/macedonga/visor/issues/72) · [视频 #35](https://github.com/macedonga/visor/issues/35) | 查看眼镜真实读回值，测导入成片的时长、编码、分辨率、画面与音轨，记录固件提前终止时 App 的提示。 |
| 有用户报告普通连接仍可用时语音唤醒已经失效，界面仍显示就绪。另一份报告记录了 Live AI 半启动后麦克风持续开启，视觉问答缺失实际照片。 [语音 #47](https://github.com/macedonga/visor/issues/47) · [Live AI #115](https://github.com/macedonga/visor/issues/115) | 语音就绪单独验证实际收到的唤醒事件和回复。覆盖音频超时与停止状态。图像问答需要收到当前回合的有效照片才能以画面为依据。 |

同一副眼镜、同一固件、同批素材分别测 GlassesLink 与 Visor。连接和快门各重复至少 20 次，记录成功率、中位和最慢的 5% 耗时。导入记首字节与完成时间，取景记首帧与最长停顿，按各自所用的链路标注结果。

## 三个项目的实现差异

| 链路 | 参考源码与 GlassesLink 的处理 |
| --- | --- |
| 设备身份与恢复 | Visor 先完成 Android BLE 配对，再获取系统身份标识，并按眼镜序列号保存设备记录。OpenGlasses 在 iOS 分开维护 DAT 注册、设备列表及各设备的连接状态。GlassesLink 需要继续分开验证主人认证、设备控制和系统音频。 [Visor 配对](https://github.com/macedonga/visor/blob/303b68035e013b0804f06914f6416c88cb8cc875/app/src/main/kotlin/com/macedonga/visor/setup/NearbyGlasses.kt#L119-L158) · [OpenGlasses 连接状态](https://github.com/straff2002/OpenGlasses/blob/19e7fffcfae5a2063f5b5fdbcf14e51eca5bdd4e/OpenGlasses/Sources/Services/GlassesConnectionService.swift#L5-L23) |
| 音频与自定义唤醒 | OpenGlasses 可用 iPhone 侧监听自己的唤醒词，再切到眼镜通话麦克风，把转写交给选择的模型。Visor 还有眼镜端唤醒词录制能力。当前公共 DAT 版本把语音转写和语音启动列为实验能力。系统蓝牙音频桥接依赖配件支持相应配对能力，验收以实际 `AVAudioSession` 路由为准。 [OpenGlasses 待机策略](https://github.com/straff2002/OpenGlasses/blob/19e7fffcfae5a2063f5b5fdbcf14e51eca5bdd4e/OpenGlasses/Sources/Services/Audio/WakeListenPolicy.swift#L3-L36) · [Visor 自定义唤醒](https://github.com/macedonga/visor/blob/303b68035e013b0804f06914f6416c88cb8cc875/core/assistant/src/main/kotlin/com/macedonga/visor/core/assistant/CustomWakeWord.kt#L22-L31) · [Apple 音频桥接](https://developer.apple.com/videos/play/wwdc2019/901/) |
| 相机与原始相册 | OpenGlasses 的标准相机后端用官方 DAT。CameraAccess 展示取景、当前照片和把收到的流录制到手机。眼镜既有相册及其删除操作需要各自的设备能力。Visor 的 Android 原件导入会先排队再切换 Wi-Fi，眼镜自建热点的代码在另一条取景路径。 [OpenGlasses 相机后端](https://github.com/straff2002/OpenGlasses/blob/5b45501f6b8c69b6dfa0a090c44d6d474899e8c5/OpenGlasses/Sources/Services/Camera/MetaCameraBackend.swift) · [Meta CameraAccess](https://github.com/meta/meta-wearables-dat-ios/blob/41d79001da0dde6ab3eaccc5e2e60ff850241b60/samples/CameraAccess/README.md) · [Visor 导入](https://github.com/macedonga/visor/blob/303b68035e013b0804f06914f6416c88cb8cc875/core/media/src/main/kotlin/com/macedonga/visor/core/media/MediaImport.kt#L454-L520) |

## 上架前依赖

官方 DAT 当前处于 Developer Preview。Meta 推荐 BLE 与 Wi-Fi，正式硬件分发资格需要通过开发者项目核实。OpenGlasses 的上架文档把手机版和眼镜 TestFlight 版做成独立构建。当前 GlassesLink 的 unsigned IPA 用于测试。正式上传需要符合 Apple 的 SDK 要求，并验证签名、热点权限和隐私文案。 [Meta 接入文档](https://github.com/meta/meta-wearables-dat-ios/blob/41d79001da0dde6ab3eaccc5e2e60ff850241b60/plugins/mwdat-ios/skills/getting-started/SKILL.md#L72-L93) · [OpenGlasses 构建说明](https://github.com/straff2002/OpenGlasses/blob/5b45501f6b8c69b6dfa0a090c44d6d474899e8c5/docs/app-store-phone-only-build.md) · [Apple 上传要求](https://developer.apple.com/news/upcoming-requirements/)

正式签名及分发前，需要核对仓库里的三项 Visor 来源资源。OpenGlasses 当前许可证将商业用途列入单独授权，本项目参考其设计并维护自己的实现。 [仓库第三方资源清单](../LICENSES.md) · [OpenGlasses 许可证](https://github.com/straff2002/OpenGlasses/blob/5b45501f6b8c69b6dfa0a090c44d6d474899e8c5/LICENSE) · [Apple 审核指南](https://developer.apple.com/app-store/review/guidelines/)
