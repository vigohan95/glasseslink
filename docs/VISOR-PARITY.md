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

## 按模块参考的其他实现

| 模块 | 可采用的做法 | 范围和源码 |
| --- | --- | --- |
| 扫描、身份与重连 | 把广播匹配、设备身份、控制通道、音频和 Wi-Fi 分成可独立更新的状态。回归测试覆盖设备更名、重复广播、超出范围、重新进入范围和系统恢复回调。 | Mentra 的 Swift SDK 提供设备匹配和状态管理（Apache-2.0）。Nordic 的 CoreBluetooth Mock 可模拟连接、断开、地址和广播变化（BSD-3-Clause）；L2CAP 数据与断链继续用本项目现有回环与实机测试。 [Mentra 匹配](https://github.com/Mentra-Community/mentra-bluetooth-sdk-ios/blob/833874d0415c1034277b78932b5f4f1d5d846824/ios/Source/Internal/ConnectedDeviceMatcher.swift#L3-L52) · [Mentra 状态](https://github.com/Mentra-Community/mentra-bluetooth-sdk-ios/blob/833874d0415c1034277b78932b5f4f1d5d846824/ios/Source/DeviceManager.swift#L270-L297) · [Nordic 断连与地址模拟](https://github.com/nordicsemi/IOS-CoreBluetooth-Mock/blob/96a8c75a29148f9bb506da0d29ff80eb0fbe7a17/CoreBluetoothMock/Central/PeripheralPeer/CBMPeripheralSpec.swift#L244-L365) |
| 多品牌与设置界面 | 记录每种型号及固件支持的功能，由实际报告决定控件的显示、默认值和写入后的读回。允许一个设备在系统里有多个物理端点。 | Mentra 有按新报告移除过时能力的实现。Even G1 的示例把左右镜腿的 BLE 外设归为同一副眼镜（BSD-2-Clause）。两者的设备协议用于各自支持的硬件。 [Mentra 能力](https://github.com/Mentra-Community/mentra-bluetooth-sdk-ios/blob/833874d0415c1034277b78932b5f4f1d5d846824/ios/Source/Status/GlassesAppCapabilities.swift#L3-L25) · [Even 配对](https://github.com/even-realities/EvenDemoApp/blob/3899aac2b39ce969582cf6eb96ecb36be3e0e9e6/ios/Runner/BluetoothManager.swift#L60-L109) |
| HEVC 取景与手机端录像 | 区分收到压缩帧、解出像素和预览首帧。格式变化时重建解码器，写入器繁忙时限制队列。录像以媒体时间戳计时，写入完成并可播放后再交给相册。 | HaishinKit.swift 2.3.2（BSD-3-Clause）演示 VideoToolbox 和 AVAssetWriter。VisionCamera 5.2.5（MIT）演示固定录制时长和停录收尾。眼镜机内的时长、编码和画质另按设备支持项验证。 [HaishinKit 解码](https://github.com/HaishinKit/HaishinKit.swift/blob/2.3.2/HaishinKit/Sources/Extension/VTDecompressionSession%2BExtension.swift#L5-L60) · [HaishinKit 写入](https://github.com/HaishinKit/HaishinKit.swift/blob/2.3.2/HaishinKit/Sources/Stream/StreamRecorder.swift#L213-L296) · [VisionCamera 时长](https://github.com/margelo/react-native-vision-camera/blob/v5.2.5/packages/react-native-vision-camera/ios/Hybrid%20Objects/Recording/HybridFrameRecorder.swift#L309-L330) |
| iPhone 加入眼镜热点 | 分别验证热点已创建、iPhone 已入网、局域网获准、设备实际应答和文件开始传输。任一步失败都保留诊断和回退。 | Espressif 的 iOS 配网示例（Apache-2.0）会在加入热点后另查设备版本，适合参考阶段拆分。GlassesLink 沿用临时加入和凭据脱敏。 [Espressif 入网及设备应答](https://github.com/espressif/esp-idf-provisioning-ios/blob/78e58f010f8539f800bce063a26d3e4c4ac596b9/ESPProvision/ESPDevice.swift#L244-L289) · [Apple 局域网许可](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy) |
| 高速导入、进度与相册 | 逐块写入临时文件，核对资产 UUID、大小和校验和后再加入本机相册。单独记录系统相册是否保存成功，合并进度刷新，批量素材尽量在一次热点会话内传完。 | Nextcloud iOS 35.2.2（GPL-3.0）用于参考下载、文件落盘和 PhotoKit 导出的流程。眼镜仍用 Airship，跨断线恢复必须核实设备支持的偏移和重试行为。 [Nextcloud 下载进度](https://github.com/nextcloud/ios/blob/35.2.2/iOSClient/Networking/NCNetworking%2BDownload.swift#L15-L74) · [Nextcloud PhotoKit 导出](https://github.com/nextcloud/ios/blob/35.2.2/iOSClient/Networking/NCNetworking%2BTransferDelegate.swift#L115-L172) |
| 通话麦克风、媒体音频与打断 | 由同一处管理 iOS 音频会话。开始录音前核对实际输入，来电、设备切换和录音结束时有明确的清理及恢复流程。分别测眼镜播媒体、眼镜收音、同时取景时的稳定性。 | OpenVision（MIT）提供 iOS 路由代码，并在发布记录中描述了取景期间 HFP 无声和语音超时后回调反复重启的故障。LiveKit Swift（Apache-2.0）的音频会话管理可作为多个功能共用会话的参考。具体限制用本型号实测。 [OpenVision 音频会话](https://github.com/rayl15/OpenVision/blob/b1e2350d0b37b7ca273f6e3c505dec254bd78370/OpenVision/Services/Audio/AudioSessionManager.swift#L43-L167) · [OpenVision v2.9.0 故障修复](https://github.com/rayl15/OpenVision/releases/tag/v2.9.0) · [LiveKit 音频会话管理](https://github.com/livekit/client-sdk-swift/blob/1f69f1d77c683a7f46dce653b891edf00660bfc3/Docs/audio.md#L3-L55) |
| 本机唤醒、转写与回播 | 唤醒检测尽量轻量，确认人声后再启动完整转写。衡量误唤醒、漏识别、结束说话到转写完成的时间和待机耗电。可用 iOS 系统能力作为基线。 | sherpa-onnx 的引擎是 Apache-2.0，提供 Swift 关键词检测样例和 iOS 麦克风流式转写样例。关键词样例以文件输入，需要自行验证持续收音和回放叠加。拟随应用分发的模型权重逐个核对许可。 [关键词检测](https://github.com/k2-fsa/sherpa-onnx/blob/17d5f144035fb35e13b787445fd3a0100998aa5a/swift-api-examples/keyword-spotting-from-file.swift#L42-L76) · [iOS 流式转写](https://github.com/k2-fsa/sherpa-onnx/blob/17d5f144035fb35e13b787445fd3a0100998aa5a/ios-swiftui/SherpaOnnxAsr/SherpaOnnxAsr/SherpaOnnxViewModel.swift#L108-L175) · [引擎许可证](https://github.com/k2-fsa/sherpa-onnx/blob/17d5f144035fb35e13b787445fd3a0100998aa5a/LICENSE) |
| 多模型直连、流式回复与取消 | 为 Claude 和 OpenAI 兼容服务维护各自的鉴权、流式解析、取消与错误处理。录音、转写、模型调用和回播各有可追踪状态。同一个问题的迟到回复不能覆盖新问题。 | AIProxySwift（MIT）提供 Swift 直连与代理两种方式，参考其直连适配器，保持用户选择的服务路径。OpenVision 的 `AIBackend` 接口可参考如何隔离模型实现。 [Anthropic 直连](https://github.com/AIProxyTeam/AIProxySwift/blob/57ad0946f022fa2467b3fda6ff4d8c30e19abf10/Sources/AIProxy/AIProxy.swift#L241-L256) · [OpenAI 直连](https://github.com/AIProxyTeam/AIProxySwift/blob/57ad0946f022fa2467b3fda6ff4d8c30e19abf10/Sources/AIProxy/AIProxy.swift#L335-L350) · [OpenVision 模型接口](https://github.com/rayl15/OpenVision/blob/b1e2350d0b37b7ca273f6e3c505dec254bd78370/OpenVision/Services/AIBackend/AIBackendProtocol.swift#L11-L68) |

## 速度、稳定性与双端耗电

0.97 日志提供了三笔起点数据。两次成功建立控制会话约为 **7.6 秒**和 **2.3 秒**，一次约 **3.28 MB** 的导入在 Wi-Fi 回退蓝牙后耗时 **110.6 秒**。这些是单次记录。0.98 需要在真机上建立可重复的基线。

| 场景 | 要记录的数据 | 优先验证的改进 |
| --- | --- | --- |
| 启动、连接、掉线恢复 | 冷启动与已配对重开分别记录。记录点击到可操作、断开到恢复、连接成功率和重试次数。保留中位数、P95 和失败日志。 | 优先尝试已验证设备，串行建链，失败后有限退避。分别测退到后台、开合镜腿、眼镜重启、控制中心蓝牙开关和用户主动断开。 [Apple 后台恢复条件](https://developer.apple.com/documentation/technotes/tn3115-bluetooth-state-restoration-app-relaunch-rules) |
| 相册导入时的操作响应 | 记录入网、首字节、校验、存本机、写入系统相册的耗时及传输速率。记录峰值内存、打开本机视频的响应、中断后重试和重复保存。 | 当前是每项素材分别建链，接收时把整份文件存在内存里。先验证单文件 Wi-Fi，再做一次建链传一批、边接收边落盘、取消和可重复的入库流程。 |
| 拍摄与取景 | 记录按下快门到出现可导入原件、打开取景到真正出画、最长卡帧及重开成功率。连续取景单独记录手机温升、眼镜电量和降画质次数。 | 以实际出画和有效原件确认成功。验证画质档位、解码队列上限、关键帧恢复及退出取景后及时释放链路。 |
| 音频和语音问答 | 记录链路恢复后多久出声、录音实际来自哪个麦克风、说完到转写、到模型首段回复、到听见回播。把无回应、路由切换和来电中断计入。 | 测音频会话集中管理和按需收音，避免待机长期占用通话麦克风。网络模型与本机转写分别计时，验证取消后能立即开始下一问。 |
| 双端待机与连续使用 | 手机和眼镜分别记录电量。在相同机型、固件、亮度、网络和画质下，分别测息屏待机、持续取景、批量导入与语音。消除充电影响，保留时长和温度。 | 验证空闲停止扫描、退出即停取景和录音、用事件更新配合低频补读。当前日志的主线程定时器每 250 毫秒运行一次，日志每行写入文件。应先采样开销，再评估按需批量刷新及高频帧日志采样。 [Apple Power Profiler](https://developer.apple.com/documentation/xcode/measuring-your-app-s-power-use-with-power-profiler?changes=_8) |

发布前用相同场景前后对照。解析、重复连接回调和导入状态可放进自动回归测试。iPhone 功耗用 Instruments 的 Power Profiler 分析，眼镜耗电用相同条件下实测的电量变化。将稳定性、速度、峰值内存和双端耗电一同写进验收结果。 [XCTest 性能指标](https://developer.apple.com/documentation/xctest/xctmetric)
