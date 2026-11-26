# 11 · 设置与本地存储

出处：**R** `core/settings/*`（6 个文件）· `core/media/GlassesConfig.kt` · **P** · **O**。

## 1. 两套写入通道

| 通道 | 适用 | 语义 | 注意事项 |
| --- | --- | --- | --- |
| svc31 `smartglasses_settings` | 有字段号的设置（253 项） | 写单字段 | ack **恒为成功**，必须读回校验 |
| svc33 `RLDrive` | 无字段号 / 结构化数据 | 复制式键值存储 | 分块（`CHUNKED=5`），写入后读回 |

判定规则：设置目录里 `field` 为空或 `parsed != 1` → 走 svc33；否则走 svc31。

## 2. svc31 载荷

| 类型 | 编码 |
| --- | --- |
| bool | varint `0/1` |
| int | varint（负数走 10 字节二补码） |
| string | 长度前缀 + UTF-8 |
| float | wire type 1 的 fixed64 |

消息号：`MT_SYNC_DATA = 2` 写入、`MT_ACK = 3` 应答。

## 3. svc33 帧

- `MT_SYNC_MESSAGE = 1`；
- 对象带命名空间与类型，例如 `individual_device_settings` 下的 kv；
- 大对象分块：首片带总长度，后续按序拼接（`CHUNKED=5` 标志）；
- 冲突解决是"后写覆盖"，没有版本号。

## 4. 设置目录（`settings.tsv` / `settings_ui.json`）

| 列 | 含义 |
| --- | --- |
| `key` | 设置键名 |
| `field` | svc31 字段号（空 = 走 svc33） |
| `kind` | `bool` / `int` / `str` / `float` |
| `default` | 默认值 |
| `namespace` | svc33 命名空间 |
| `parsed` | `1` = 可直接编解码 |

规模：**371 项、18 组**；其中 253 项带字段号。UI 侧另有一份文案表（分组名、说明、取值范围、选项）。

常见项示例：

| 键 | 字段 | 类型 | 说明 |
| --- | ---: | --- | --- |
| `notification_volume` | 5 | int | 通知音量（0–100） |
| `notification_led_brightness` | 14 | int | 指示灯亮度（0–5） |
| `cloud_ota_enabled` | 19 | bool | 云端 OTA 开关 |
| `assistant_enabled` | 2 | bool | 助手总开关 |
| `assistant_llm_enabled` | 30 | bool | LLM 回答开关 |
| `wakeword_sound_enabled` | 37 | bool | 唤醒提示音 |
| `audio_playback_during_capture_enabled` | 122 | bool | 拍摄时是否播音频 |
| `quick_clips_photo_capture_enabled` | 100 | bool | 快剪拍照 |
| `advanced_video_quality_profile` | 218 | int | 视频质量档 |

## 5. RLDrive 里的其它数据

| 命名空间 | 内容 | 来源 |
| --- | --- | --- |
| `individual_device_settings` | 设置项 | `GlassesSettings.kt` |
| `contacts_native`、`contacts_whats_app`、`contacts_messenger`、`contacts_instagram` | 联系人（`type=contact`） | `settings/Contacts.kt` |
| `PERMISSIONS_NAMESPACE` | 眼镜授予手机应用的权限清单（`type=permission_manifest`，uri = 包名） | `settings/Permissions.kt` |

## 6. MobileConfig

`media/GlassesConfig.kt`：眼镜侧参数表，`McParam(name, type, value)`，type `1` bool、`2` int64、`3` string、`4` double。
手机把这些参数原样下发，不校验完整性——所以"改一个字节"会直接生效。我们不使用这条路径；仅记录它的存在，避免误判"设置没生效"是别的原因。

## 7. 实现建议

1. 读一次全量（svc33 同步 + svc31 无读取接口 → 只能从 svc33 镜像读）；
2. 写入后**必须读回**，不读回就等于没校验；
3. 未读到的值显示「未读取」，不要显示成"关"（否则用户以为被锁）；
4. 批量写要串行，且每写一项读回一项——并发写会被覆盖。
