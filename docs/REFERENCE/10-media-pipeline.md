# 10 · 相册、传输与取景流水线

出处：**R** `core/media/*`（32 个文件）· **R** `core/connection/Shutter.kt` · **O** 真机。

## 1. 素材从眼镜到手机

```
svc18 枚举 ──▶ 记录（handle / kind / assets / 时间戳）
        │
        └─ 0x83 请求某个 asset ──▶ svc20 airship 推文件 ──▶ 落盘 + adler32 校验
                                              │
                                              └─ 照片：HEIC/JPEG 直接入库；视频：先落原文件
```

| 文件 | 职责 |
| --- | --- |
| `Captures.kt` | svc18：枚举、记录解析（无 schema flatbuffer）、请求素材、删除 |
| `Airship.kt` | svc20：提供/游标/数据/校验/完成/drop，命名空间白名单 |
| `Assembly.kt` | 把同一素材的多份文件（主图、动态、IMU、帧日志）聚合 |
| `Albums.kt` | 落库位置：`Pictures/`、`Movies/`，或 `DCIM/` 合目录 |
| `MediaImport.kt` | 导入队列：并发、重试、进度 |
| `GalleryIndex.kt` | 编辑记录（选了哪一帧、校正角度、裁剪） |
| `Develop.kt` | HEIC → 可编码的 JPEG（处理 Exif orientation 6 与宽高） |
| `Darkroom.kt` | 按编辑记录重新生成照片（重新取帧、旋转、裁剪） |
| `FinishVideo.kt` | 视频收尾（稳定化、方向） |
| `Steady.kt` | 每帧一个 3×3 像素映射矩阵（列主序，y 向下） |
| `FrameGrab.kt` | 从视频关键帧解出一张静图（用于封面） |
| `Hevc.kt` | Annex-B 拆 NAL |
| `Sensors.kt` | IMU 采样（约 960 Hz，m/s²、rad/s、温度） |
| `PlaceLog.kt` | 拍摄位置（时间、经纬度、精度） |
| `Publish.kt` | 清掉 MediaStore 的 pending 标记并读回 |

要点：

- **drop 必回**：svc20 的 type 7 是对每条 offer 的应答，收下或不收都要回，不回会卡住整条队列；
- **adler32 必校验**：`type 6 complete` 里带 size 与 adler32，对不上就是传坏了；
- **视频封面**：用 `FrameGrab` 从关键帧取，比等解码器便宜；
- **HEIC 的坑**：传感器是横向、Exif 标 6，直接显示会躺倒。

## 2. 取景（Live）

```
StartApp(3) ─▶ sessionSettings(27) ─▶ configureVideo(5) ─▶ configureAudio(3) ─▶ control(7, START)
                                                                                    │
        codecConfig(1) ◀──── videoBuf(10)/videoEnd(12) ◀──── photoBuf(34)/photoEnd(35)（按需）
```

| 文件 | 职责 |
| --- | --- |
| `StreamProto.kt` | 全部消息类型、配置结构、错误码文本 |
| `LiveStream.kt` | 会话：起停、码率阶梯、重配 |
| `LiveQuality.kt` | 阶梯：360p 600k/24 → 1080p 4M/30（按链路质量降级） |
| `LiveDecoder.kt` | 硬件 HEVC/H.264 解码到 Surface（异步，一帧一帧出） |
| `Playout.kt` | 按时间戳排帧：眼镜是"突发 4–5 帧 + 110–160 ms 空档"，直接显示会抖 |
| `LiveAudio.kt` | AAC-LC 包（与视频同一时钟，微秒） |
| `LiveRecorder.kt` | 边看边录：视频原样（HEVC/H.264）+ 音频 AAC 写一个 MP4，pending 直到收尾 |
| `LiveSettings.kt` | 叠加层（读数、热成像、网格） |
| `LiveOutputs.kt` | 录制状态与"要录制但没准备好"的原因 |
| `Rtmp.kt` / `Broadcast.kt` | 推流：HEVC 走增强 RTMP，或手机转 H.264 |
| `Transcoder.kt` / `VideoCodec.kt` | H.264 转码与编解码器选择 |
| `Screencast.kt` | 屏幕内容投到眼镜（Display） |
| `Wifi.kt` | svc10 ATC：把眼镜拉进指定 Wi-Fi（切到 TCP 前置动作） |
| `GlassesConfig.kt` | MobileConfig 参数（bool/int64/string/double） |

要点：

- 视频分片前 8 字节是 **LE64 微秒时间戳**，其后才是 Annex-B；
- `codecConfig(1)` 的 field3 里是 VPS/SPS/PPS，必须留着给解码器；
- 录制时长由客户端计时停止（`control(7, STOP)`），眼镜不会自己停。

## 3. 拍摄（快门）

`Shutter.kt` 决定"拍什么"：

| 动作 | 值 |
| --- | --- |
| 拍照 | `action.robusta.capture` |
| 开始录像 | `com.meta.smartglass.app.intent.action.AGENTIC_START_RECORDING` |
| 停止录像 | `com.meta.smartglass.app.intent.action.CLOSE_APP_CAPTURE` |
| 类型 | `capture_type` = `video` / `hyperlapse` |

外层用 svc28 的应用生命周期包住（`StartApp` → 意图 → `StopApp`），返回码 `1` 成功、`12` 已在运行、`6` 电量不足、`7` 过热。

## 4. 装应用到眼镜（仅 Display / 有应用管理器的机型）

`AppInstall.kt`：先取 **svc56 租约**，再在 **svc66 app manager** 上 StartApp，APK 走 airship 的 `appmanager` 命名空间传过去。
普通 Gen 2 没有这条链路。
