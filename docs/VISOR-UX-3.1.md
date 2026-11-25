# Visor 3.1.0 界面和自定义功能核对

按 3.1.0 标签的 Android 界面源码核对布局、交互和设置。部分选项按眼镜型号、固件和实际支持能力显示。 [Visor 3.1.0](https://github.com/macedonga/visor/releases/tag/v3.1.0)

| 页面 | 排版与按钮 | GlassesLink 采用的交互 |
| --- | --- | --- |
| 设备首页 | 上方舞台展示镜架及状态，状态胶囊根据连接情况切换为配对、允许蓝牙、连接或重试。向下是电量等读数、最近媒体、导入与四个功能入口。支持多副眼镜横向切换。 [首页](https://github.com/macedonga/visor/blob/v3.1.0/app/src/main/kotlin/com/macedonga/visor/home/HomeScreen.kt#L472) · [按钮与入口](https://github.com/macedonga/visor/blob/v3.1.0/app/src/main/kotlin/com/macedonga/visor/home/HomeFeed.kt#L576) | 打开先看到眼镜和真实连接状态。状态、系统音频和常用设置分区域。相册、拍摄、助手用原生标签分页。 |
| 相册 | 上方是当前选中素材的大图，下面按日期铺网格。待导入集中显示，胶囊按钮按状态显示导入全部或重试。支持收藏筛选、选择与批量操作。 [相册](https://github.com/macedonga/visor/blob/v3.1.0/app/src/main/kotlin/com/macedonga/visor/gallery/GalleryScreen.kt#L126) | 先选眼镜或本机，再按日期浏览。眼镜传输中显示真实进度、本次蓝牙速度和估时。 |
| 媒体查看器 | 顶部圆形关闭钮和日期，底部先放视频播放、暂停和拖动进度，再放收藏、分享、编辑、详情与删除按钮。眼镜上有原件而本机没有的素材显示导入按钮。 [查看器](https://github.com/macedonga/visor/blob/v3.1.0/app/src/main/kotlin/com/macedonga/visor/gallery/Viewer.kt#L411) | 打开原始视频即进原生播放器，支持播放和拖动。0.95 留下的封面可在原件仍在眼镜上时补下载。 |
| 实时取景 | 默认尽量让画面占满屏幕，点画面可切换到带控制的模式。眼镜拍照和截取当前帧是独立动作，录像、回放、直播等入口按会话状态出现。 [取景](https://github.com/macedonga/visor/blob/v3.1.0/app/src/main/kotlin/com/macedonga/visor/media/LiveScreen.kt#L230) | 主快门固定在拍摄页底部。单独保留实验取景入口，等 iOS 路线验证后再扩展录制与回放。 |
| 助手 | 对话按日期呈现，顶部是搜索和记忆，底部可发新问题或续问。模型、语音方式、功能开关在独立设置页。 [助手页面](https://github.com/macedonga/visor/blob/v3.1.0/app/src/main/kotlin/com/macedonga/visor/metaai/MetaAiScreen.kt#L99) · [助手设置](https://github.com/macedonga/visor/blob/v3.1.0/app/src/main/kotlin/com/macedonga/visor/settings/AssistantSettings.kt#L199) | 显示当前模型、眼镜注册及唤醒状态，下面固定文字输入。选择照片后可附图。语音回复与文字回复有各自产出的结果。 |
| 设置 | 顶部搜索，下面有支持项目的可固定、可拖动快捷卡片。常用选项进各主题页，原始项目进高级页。 [快捷卡](https://github.com/macedonga/visor/blob/v3.1.0/app/src/main/kotlin/com/macedonga/visor/settings/SettingsScreen.kt#L352) | 常用区优先展示读得到的选项，高级诊断单独收起。 |

## Visor 提供的自定义项

| 设置组 | 已核对的选项 |
| --- | --- |
| 眼镜拍摄 | 录像时长、分辨率与帧率、视频防抖、画幅、动态模糊处理、照片自动水平等。还包含录制时播放音频、音乐并行和音频降噪。部分横向成片、防抖由手机处理。录像时长和分辨率组合随型号而变化。 [拍摄设置源码](https://github.com/macedonga/visor/blob/v3.1.0/app/src/main/kotlin/com/macedonga/visor/settings/Topics.kt#L61) · [选择项与型号条件](https://github.com/macedonga/visor/blob/v3.1.0/core/settings/src/main/resources/com/macedonga/visor/core/settings/settings_ui.json#L14963) |
| 取景画质 | 自动或手动。手动时分辨率、0.6–8 Mbit/s 的码率档、24 或 30 帧。另有 30–180 秒回放、眼镜麦克风监听、眼镜热点、网格与码率温度叠加。这里的码率和帧率针对实时流。 [取景设置](https://github.com/macedonga/visor/blob/v3.1.0/app/src/main/kotlin/com/macedonga/visor/media/LiveSettingsScreen.kt#L24) |
| 相册导入 | 自动导入模式、照片和视频共用或分别命名相册、保存拍摄位置。还有收藏、视频播放与素材详情。 [相册设置](https://github.com/macedonga/visor/blob/v3.1.0/app/src/main/kotlin/com/macedonga/visor/settings/TopicScreen.kt#L76) |
| 按键、触摸、音频 | 短按拍照或短按录像优先、触摸板和长按行为、滑动方向、快捷操作、提示音量、自动音量、单声道以及其它型号支持的功能。 [设置分类](https://github.com/macedonga/visor/blob/v3.1.0/app/src/main/kotlin/com/macedonga/visor/settings/Topics.kt#L34) |
| 模型、唤醒和语音 | 服务和模型、连通测试、语音来源与说话语言、语音模型及音色、图像问答、继续对话、等待时长。型号或固件支持时还有自定义唤醒词。 [模型与语音设置](https://github.com/macedonga/visor/blob/v3.1.0/app/src/main/kotlin/com/macedonga/visor/settings/AssistantSettings.kt#L200) |

固定时长、防抖、分辨率和编码这些项目要用眼镜读回值和实际成片验证。取景画质、手机导出设置及眼镜固件拍摄是三条不同路径。功能覆盖和真机验收见 [对照表](VISOR-PARITY.md)。
