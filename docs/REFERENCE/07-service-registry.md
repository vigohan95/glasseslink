# 07 · 服务注册表（全量）

出处：**R** 参考实现源码 · **P** 公开协议说明 · **O** 真机。
服务号即 DataX 第一条消息里 `tag 1` 的值。下表是我们在参考实现里能确认的**全部**服务，按号排序。

| svc | 名称 | 定义位置 | 作用 | 我们 |
| ---: | --- | --- | --- | --- |
| 5 | link setup | `protocol/Constants.kt` `ServiceId.LINK_SETUP` | 握手两条消息 + EndLinkSetup | ✅ |
| 10 | ATC LinkManager2 | `media/Wifi.kt` `SVC_ATC` | 把眼镜拉进某个 Wi-Fi：`0x1010 MT_JOIN_ACCESS_POINT` 等 | ❌ |
| 15 | Oxide（助手） | `assistant/Oxide.kt` `SVC_ASSISTANT` | 唤醒、转写、回答、朗读、Live AI、工具调用 | 🟡 |
| 18 | media management | `media/Captures.kt` `SVC_MEDIA` | 相册清单、素材重排队、删除 | ✅ |
| 20 | airship | `media/Airship.kt` `SVC_AIRSHIP` | 文件传输引擎（照片、视频、bugreport、appmanager 包） | ✅ |
| 22 | device info | `connection/Clock.kt` `SVC_DEVICE_INFO` | 写时间与时区 | ❌ |
| 28 | smartglasses_appmanager | `connection/Status.kt` | 状态推送、StartApp/StopApp、SNIntent（快门） | ✅ |
| 29 | OTA | `protocol/Constants.kt` `SVC_OTA` | 固件与资源包 | ✅ 可拒收 |
| 31 | smartglasses_settings | `settings/GlassesSettings.kt` | 单字段写（ack 恒成功，需读回） | ✅ |
| 33 | RLDrive | `settings/RlDrive.kt` | 复制式键值存储（设置、联系人、权限清单） | ✅ |
| 36 | identity / trust | `session/TrustExchange.kt` | 设备主人校验与迁移 | ✅ |
| 47 | cloud configuration | `connection/GlassesWifi.kt` `SVC_CLOUD_CONFIG` | 眼镜保留的 Wi-Fi 网络列表 | ❌ |
| 53 | glasses photos | `assistant/GlassesPhotos.kt` | 回答"你看到了什么"时取一张照片 | ❌ |
| 56 | lease | `protocol/Constants.kt` `SVC_LEASE` | 应用在眼镜上运行的租约（装 APK 前要先拿） | ❌ |
| 66 | app manager | `media/AppInstall.kt` | 通过它启停眼镜上的应用、装包 | ❌ |
| 72 | translation | `protocol/Constants.kt` `SVC_TRANSLATION` | 眼镜侧翻译会话 | ❌ |
| 78 | nexus | `connection/Nexus.kt` | Display 的连通性服务（一条请求一个通道） | ❌ |
| 79 | constellation trust | `identity/ConstellationTrust.kt` | 应用自带链路时替代 svc36 的信任交换（清单由手机安装） | ❌ |
| 89 | linked accounts | `identity/LinkedAccounts.kt` | 账户绑定类型（供 accounts 应用） | ❌ |
| 100 | peer_build_info | `connection/Canary.kt` `SVC_PEER_BUILD_INFO` | 构建指纹、序列号、经典蓝牙地址、发布版本 | ❌ |
| 150 | conn_device_lease | `protocol/Constants.kt` `CONN_DEVICE_LEASE` | Display 向手机索取配对带 | ❌ |
| 31337 | hearing | `assistant/Hearing.kt` `SVC_HEARING` | 对话聚焦与助听校正 | ❌ |
| 51350 | media_streaming_control | `media/StreamProto.kt` | 取景串流 | ✅ |
| 52822 | wireless_input_service | `protocol/Constants.kt` `WIRELESS_INPUT` | Neural Band 的整套 RPC | ❌ |
| 53210 | TAR | `assistant/Timers.kt` `SVC_TAR` | 计时器与闹钟（眼镜把请求转给手机） | ❌ |

## 通道与服务的对应关系

- 每个服务在会话里占**一条或多条**本地通道（`0x8002` 起，带 originator 位）；
- `ChannelRegistry` 维护 `本地通道 → 服务` 与 `对端通道 → 服务` 两张表；
- service tag **只在通道的第一条消息**上出现（`0x8001` 例外，见 `01-link-setup.md`）；
- 同一服务可以被多条通道承载（例如 airship 每次传输一条，见 `SubstreamRelay`）。

## 怎么用这张表

1. 接新机型：先看它**提供哪些服务**（`canary` 的 `GET_INFO` 能问出来），再把能力位映射到 UI；
2. 实现新功能：想清"它属于哪个服务"再动手，不要在同一通道里塞两种语义；
3. 排障：日志里 `svc=` 的值直接对到这张表，缺哪个就是哪条链路没建立。
