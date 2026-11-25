# 03 · 服务表

出处：**P** 公开协议说明 · **R** 参考实现源码 · **O** 真机观测。载荷多为 protobuf；相册清单是**无 schema 的 flatbuffer**（按 vtable 读）。

| 服务 | 编号 | 用途 | 载荷 |
| --- | --- | --- | --- |
| link setup | 5 | 握手两条消息 | protobuf（见 `01-link-setup.md`） |
| assistant | 15 | 眼镜侧助手（唤醒、转写、回答） | Thrift compact |
| captures | 18 | 相册清单与素材请求 | 混合：枚举用空载荷，清单是 flatbuffer |
| airship | 20 | 文件传输（照片/视频字节流） | protobuf |
| status | 28 | 状态订阅 + 快门/录像意图 | protobuf |
| OTA | 29 | 固件升级请求 | protobuf（客户端可直接拒收） |
| live | 30 / 51350 | 取景与串流 | protobuf |
| settings | 31 | 单字段写入 | protobuf（单个字段编码） |
| RLDrive | 33 | 键值型设置存储 | 自研帧（含分块） |
| identity / trust | 36 | 设备主人校验与迁移 | protobuf |

## 18 · captures

| 类型 | 方向 | 载荷 |
| --- | --- | --- |
| `1` | 手机 → 眼镜 | 空，请求枚举 |
| `6` | 眼镜 → 手机 | 一条记录（handle、kind、assets、metadata） |
| `2` | 眼镜 → 手机 | 枚举结束 |
| `0x83` | 手机 → 眼镜 | `<handle>:<assetId>` 重排队某个素材 |
| `0x84` | 眼镜 → 手机 | 应答 |
| `0x86` | 手机 → 眼镜 | `<handle>:<linkType>`（`1` 蓝牙 / `7` 高速链路），**必须在切换链路前发** |

记录结构（flatbuffer，按 vtable 偏移读）：

| 槽位 | 内容 |
| --- | --- |
| 4 | handle（字符串） |
| 8 | kind：`3073` 照片 / `3074` 视频 |
| 10 | assets 表数组 |
| 12 | metadata 表，槽 4 = 纳秒时间戳 |

asset 表：槽 4 = uuid 字符串，槽 6 = 类型码（低字节 `1` 视频 / `2` 静态图 / `3` IMU / `4` 帧日志），槽 12 = 字节数，bit `0x100000` = 已交付。

## 20 · airship

| 类型 | 说明 |
| --- | --- |
| `1` FileOffer | `{1 uuid16, 2 int64 大小, 3 namespace, 4 文件名}` |
| `2` Cursor | `{1 offset u64, 2 adler32 u32}`；空文件游标是 `10 01` |
| `4` Data | 原始块（蓝牙 1024 B / 高速 4096 B） |
| `5` Check | 请求下一个游标 |
| `6` Complete | `{size, adler32}`，校验后必须回 `7` |
| `7` Drop | 收下或拒收都要回，不回会卡住整条队列 |
| `3` Reset / `8` Removed / `10` 队列空 / `11` FileStop | 控制 |

## 28 · status

| 类型 | 说明 |
| --- | --- |
| `1000` init | 订阅入口 |
| `2005` deviceStateStart | 状态流开始 |
| `2000` startApp / `2001` / `2002` stopApp | 应用生命周期 |
| `2300` SNIntent | 快门/录像意图 = `{1 action, 2 extras[]}` |

状态字段：`1` 电池 `{2 充电, 3 百分比, 4 温度/1000, 5 mV/1000}`、`3` 相机、`6` 铰链、`9` 佩戴、`13` 热 `{2 温度, 3 限速}`、`21` 存储 `{1 剩余, 2 总量 MB}`、`25` 音量 `{1 level, 2 stream, 3 百分比}`。

快门 action：`action.robusta.capture`（拍照）、`com.meta.smartglass.app.intent.action.AGENTIC_START_RECORDING`、`...CLOSE_APP_CAPTURE`。
extras 的键：`LAUNCH_TYPE`＝`CAPTURE_EXTRA_LAUNCH_TYPE_PHOTO`、`REFERRER`＝`SHORT_BUTTON`、`IS_MODAL`＝true、`capture_type`＝`video`/`hyperlapse`。

## 30 / 51350 · live

| 类型 | 说明 |
| --- | --- |
| `1` codecConfig | 参数集（HEVC SPS/PPS/VPS） |
| `5` cfgVideo / `3` cfgAudio | 配置（mime、宽高、码率、帧率、关键帧间隔） |
| `7` control | `{1 nonce, 2 action}`，`1` 开始 / `2` 停止 |
| `10` videoBuf / `12` videoEnd | 视频分片与结束（整块前 8 字节是 LE64 微秒时间戳） |
| `23` userEvent | `PB.uint(2, 4)` = 让眼镜拍一张 |
| `34` photoBuf / `35` photoEnd | 抓拍帧（HEIC） |
| `27` sessionSettings | 会话参数（doff、空闲、是否允许抓帧） |

码率阶梯：1080p 4M/30、1080p 3.5M/24、720p 2.5M/30、504p 1.5M/30、432p 1M/24、360p 600k/24。

## 31 · settings

载荷就是**单个字段**的编码：bool → varint `0/1`；int → varint（负数走十字节二补码）；string → 长度前缀；float → wire type 1 的 fixed64。
应答是 `MT_ACK = 3`，且**恒为成功**，所以写完必须读回校验。

## 33 · RLDrive

- 键值存储，命名空间如 `individual_device_settings`；
- 帧带分块标志（`CHUNKED = 5`），写入后读回才算成功；
- 没有字段号的设置项都走这里。

## 36 · identity / trust

| 类型 | 说明 |
| --- | --- |
| `0x1000` ENABLE_TRUST | `{1 SHA256(公钥 64B), 2 对通道绑定的签名 r‖s 64B, 3 varint 2}` |
| `0x1001` ENABLE_TRUST_EC | 同上，EC 变体 |
| `0x2000/0x2001` SKIP_CHALLENGE | 跳过挑战 |
| `0x2002/0x2003` START_CHANGE_OWNER | 迁移开始的请求/应答（中途可能要求按一下拍摄键） |
| `0x2004/0x2005` FINISH_CHANGE_OWNER | 迁移完成 |
| `0x3000/0x3001` IDENTITY | 读取设备证书与序列号 |

**通道绑定**：

```
binding = SHA256( SHA256(对端挑战 ‖ 对端公钥) ‖ SHA256(我方 seed ‖ 我方公钥) )
```

签名是对这 32 字节原文签名（等价于 NONEwithECDSA），`s` 需折叠到低半区。
