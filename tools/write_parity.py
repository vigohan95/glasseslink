import io

doc = u'''# 与 Visor 的功能对齐表

Visor 是安卓实现，有些能力在 iOS 上根本没有对应系统接口。这张表把「已做 / 可做 / iOS 做不到」分开，
免得我一件一件往外挤，也免得你等一个永远做不到的东西。

## 已经写进代码的（不是计划，是已在仓库里的实现）

| Visor 能力 | 我们这边的实现 | 文件 |
|---|---|---|
| 配对/成为主人（svc36） | 完整四步：identity → skipChallenge → START_CHANGE_OWNER → FINISH_CHANGE_OWNER，含 Meta OIDC 登录与 receipt | `Provision.swift`、`Login.swift`、`MetaClient` |
| 相册列表（svc18 flatbuffer） | 解析 handle / 类型 / 资产 / 时间戳，按时间倒序 | `Session.swift` |
| 照片与视频导入（svc20 Airship） | FileOffer → Cursor → Data → Complete → Drop，adler32 校验，真实字节进度 | `Session.swift`、`receiveFile(onBytes:)` |
| 存到系统相册 | 照片 `PHPhotoLibrary`；视频 `PHAssetCreationRequest` + 封面帧 | `App.swift` |
| 拍照（按眼镜快门） | svc28 SNIntent `action.robusta.capture`，等价于手指按下去 | `Shutter.swift` |
| 录像（开始/停止） | `AGENTIC_START_RECORDING` / `CLOSE_APP_CAPTURE`，可设最长时长自动停 | `Shutter.swift`、`App.swift` |
| 实时取景（Live） | svc30 五步启动、HEVC 解码到 `AVSampleBufferDisplayLayer`、中途抓 HEIC | `Live.swift`、`LiveView.swift` |
| 全部眼镜设置（370 项） | svc31 直写 + svc33 RLDrive 回退，写后读回校验 | `SettingsSchema.swift`、`Drive.swift`、`SettingsView.swift` |
| 设备状态 | svc28 订阅：电量/充电/温度/存储/音量/铰链/佩戴 | `Status.swift` |
| 语音助手（Hey Meta 接管） | svc15 Thrift 注册、ev52 转写、ev53 VARM + ev60 让眼镜自己念 | `Assistant.swift`、`Varm.swift` |
| 自定义 AI 模型 | OpenAI 兼容 base_url / 模型名 / key，可指向本机 Ollama | `ModelSheet` |
| 诊断 | 自检 9 项、抓帧详细日志、一键诊断包、崩溃回溯 | `SelfTest.swift`、`CrashLog.swift` |

## 还能补、但还没做的（可做，按你的使用频率排序）

1. **相册网格 + 多选批量导入**（现在是列表逐条；Visor 是网格多选）
2. **视频缩略图预览与站内播放**（已有封面帧，播放器没接）
3. **取景码率/分辨率可选**（阶梯已实现，UI 没暴露）
4. **多副眼镜切换**（数据结构支持，UI 只记最后一只）
5. **RTMP 推流**（Live 的帧已经在手上，缺推流客户端）
6. **拍照倒计时、连拍**

## iOS 上做不到的（Visor 能做，因为它是安卓）

| Visor 的做法 | iOS 的现实 |
|---|---|
| Wi-Fi Direct 直连眼镜拿原图（约 10 MB/s） | iOS 没有 P2P API。替代：蓝牙（120–165 KB/s，2.7 MB 约 20–30 秒），或眼镜自己开热点、手机手动入网（需要它开，且要用户手动连） |
| 转发**别人 App** 的通知到眼镜 | iOS 不允许第三方 App 读取其他 App 的通知内容。只能转发本 App 自己的通知 |
| 后台常驻保活 | iOS 只给 `bluetooth-central` 有限后台时间，长时间后台会挂起 |
| 任意文件系统访问 | 沙箱内，只有 `Documents` 与相册 |

## 一句话结论

「拍照、录像、取回原图、改所有设置、看状态、实时取景、Hey Meta 换自己的模型」这些**全部已经在代码里**，
差的不是功能，是**真机上那一次 trust 还没通过**——现在卡在 `EnableEncryption` 之后我们自己崩掉。
崩溃现场由 0.59 记录，一次日志就能定位。
'''

p = r'D:\GlassesLink\docs\VISION-PARITY.md'
io.open(p, 'w', encoding='utf-8', newline='\n').write(doc)
print('wrote', p, len(doc))
