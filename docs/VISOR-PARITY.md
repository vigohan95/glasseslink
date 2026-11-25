# GlassesLink 对照 Visor 的验收清单

基准为 Visor 3.1.0 及其公开功能说明。GlassesLink 0.95 的真机范围是用户现有的 Ray-Ban Meta Gen 2 和 iPhone。表中的实现进度按当前代码记录。连接时间、断开恢复和拍摄导入仍需真机测量。 [Visor 3.1.0](https://github.com/macedonga/visor/releases/tag/v3.1.0) · [Visor 功能说明](https://github.com/macedonga/visor#what-it-does)

| 功能 | 0.95 的实现进度 | 功能对齐时的验收结果 |
| --- | --- | --- |
| 首次配对、主人验证、日常连接 | 已有 Gen 2 登记与认证。意外断开后对已验证设备退避重试，记录握手耗时。 | 首次配对后可直接打开 App 连接。眼镜重启、开合镜腿、离开后返回及 iPhone 蓝牙恢复后都能重新取得加密会话。手动断开可取消重连。 |
| 设备首页 | 有设备列表、认证状态、电量、可用空间和眼镜音量。双电量、实时状态更新和镜架 3D 展示待补。 | 数据与真机一致。未上报值可识别，区分充电、睡眠、休眠后失联和正在录像。 |
| App 拍照与录像 | 等待相机事件。录像停止后查目录。时长选项由手机计时发送停止指令。 | 手机快门和眼镜按键都能生成可导入的照片、可播放的视频。用实际时长、编码、画质和音轨验证设置。 |
| 相册与媒体 | 手动蓝牙导入，校验大小及校验和。系统照片确认保存后持久化记录。 | 分开显示下载、验证、保存和可重试状态。重启后仍可识别已保存文件。补齐 Wi-Fi、高速大文件、充电时自动导入、Live Photo 与素材清理入口。 |
| 实时取景 | 蓝牙实验入口可区分启动被拒、超时及收到首帧。 | 在 iPhone 上取得稳定 Wi-Fi 预览、抓帧、录制、即时回放、RTMP 和 Live AI，切换前后台后可再次进入。 |
| 模型与助手 | Claude 直连、OpenRouter、OpenAI 兼容地址和手填模型 ID 可配置。已有拍摄结果的图像问答和眼镜端语音入口。 | 首次语音唤醒、连贯追问、眼镜新拍画面、会话历史及失败恢复均有实际结果。 |
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

## 上架前依赖

取景优先验证两条 iOS 路线。Meta 的 iOS Camera Access 样例已有预览、抓拍和录制，正式发布渠道需要开发者项目凭证。另一条路线是由眼镜提供热点，iOS 使用 Apple 的 Wi-Fi 配置接口经用户许可加入，随后用真机验证连接介质和媒体服务。 [Meta Camera Access 样例](https://github.com/meta/meta-wearables-dat-ios/blob/main/samples/CameraAccess/README.md) · [Apple Wi-Fi 配置](https://developer.apple.com/documentation/networkextension/wi-fi-configuration)

正式签名及分发前，需要核对仓库列出的三项 Visor 来源资源以及对应的分发条件。 [仓库第三方资源清单](../LICENSES.md) · [Apple 审核指南](https://developer.apple.com/app-store/review/guidelines/)
