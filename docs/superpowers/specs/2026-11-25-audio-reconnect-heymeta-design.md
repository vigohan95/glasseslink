# 1.00 设计：眼镜音频、自动重连、Hey Meta 解析

日期：2026-11-25 · 基线：0.99（`codex/release-readiness` @ `07b6fda`）· 证据：`glasses(29).log` 0.99 会话 + 当天真机实验

## 背景与证据

| 问题 | 证据 | 根因 |
| --- | --- | --- |
| 眼镜不是 iPhone 的音频设备 | 0.99 日志输出一直是 `Speaker/Receiver`；控制中心只有 iPhone；系统「我的设备」里有 `RB Meta 046N`（带 Device Type）。用户「忽略此设备 → 配对模式 → 系统蓝牙里重新配对」后，音乐从眼镜播放，0.99 的麦克风测试录到眼镜声音 | iPhone 侧配对记录失效（眼镜换主人后已不认这台 iPhone）。App 代码无法修复配对，只能检测与引导 |
| 「尝试接通眼镜音频」导致掉线 | 08:46:53 请求后 08:46:55 `CBError 7`，2.6 s 后重新握手 | `requestGlassesAudioConnection` 调 `reconnect()` 断开数据链路，再带 `CBConnectPeripheralOptionEnableTransportBridgingKey` 重连；标志 `requestedGlassesAudioBridging` 永不清除，之后每次连接都带该选项 |
| 冷启动连不上上次的眼镜 | 08:46:12–08:46:27 四次「未找到上次连接的眼镜」，普通扫描后以新标识连上 | 只按保存的单个 `CBPeripheral.identifier` 找；无配对时 iOS 给眼镜的标识会变。`retrieveConnectedPeripherals` 只在手动扫描时调用 |
| Hey Meta 收到语音流但无文字 | 08:49:59 收到 282 帧；ev57 连续两次 `could not decode event 57 body (compressed=true)` | 眼镜自己识别后把文字放在 ev57（`m[2][1][1]`）。`ThriftCompact.readValue` 不支持 map(11)/float(13)，ev57 的 slots 是 map → 整条抛错，被 `try?` 吞掉。Visor `Thrift.kt` 支持二者；double 按小端读 |

## A. 眼镜音频

1. 删除 `requestGlassesAudioConnection`、`canRequestGlassesAudioConnection`、设备页「尝试接通眼镜音频」按钮，以及 `beginConnection` 里的 transport bridging 选项。启动时 `removeObject(forKey: "requestedGlassesAudioBridging")`。
2. `readAudioOutput()` 同时读取 `availableInputs` 中的蓝牙麦克风（HFP / LE），得出 `glassesAudio: GlassesAudioState`：
   - `.glasses(profile)`：输出或麦克风里有名字属于眼镜的蓝牙端口；
   - `.otherBluetooth(name)`：声音在别的蓝牙设备（如 AirPods）上；
   - `.unavailable`：都没有。
   纯函数 `GlassesAudioState.from(outputs:inputs:glassesNames:)` 便于单测。
3. 设备页音频卡片：已接通时显示「眼镜音频已接通 · 档位」；未接通时显示四步修复指引（忽略此设备 → 配对模式 → 系统蓝牙「其他设备」里配对 → 回到 App 自动检测）。测试音、输出选择器、麦克风测试保留。路由变化通知已存在，状态随之刷新。
4. 麦克风测试：等待蓝牙输入从 1.2 s 放宽到 3 s；名字不匹配时，若只有一个蓝牙麦克风就用它。

## B. 自动重连

`autoReconnect()` / 恢复路径按顺序找眼镜：

1. `retrieveConnectedPeripherals(withServices: [FD5F])`：系统已把眼镜当耳机连着时立即命中；
2. 保存的标识仍可取回时照旧连接（配对后 iOS 能解析眼镜地址，标识会稳定）；
3. 恢复扫描：不再要求标识等于旧值。第一个带厂商号 `0x01AB`（或 FD5F 服务）、可连接、信号强于 -90 dBm 的广播即作为候选连接；按广播里的产品号排除 Neural Band（1537/1538）。

广播解析写成纯函数 `MetaAdvertisement` 并单测。连上后走正常握手：主人信任失败（`0x1010` 等）即说明不是这副眼镜，断开并在本次运行中跳过该标识，且**不**把自己的主人状态记成被拒（否则之后不再自动重连）；成功则 `rememberVerifiedPeripheral` 已会合并新旧标识（同一公钥指纹）。快速握手仍只在标识与保存值相同时使用。

## C. Hey Meta 解析

1. `ThriftCompact.readValue` 新增：
   - `map`(11)：varint 个数；非零时一字节 `keyType<<4 | valueType`；逐对读取，键转字符串（二进制键转 hex）；集合内 bool 为单字节（1 真 2 假）。返回 `[String: Any]`。
   - `float`(13)：4 字节大端，返回 `Double`。
   - `double`(7)：改为小端（对齐 Visor `Thrift.kt`）。
   - 集合元素中的 bool 统一按单字节读（list 现已如此，map 复用）。
   - binary 长度仍按严格校验（截断即报错），配合下面的日志定位，不做静默截取。
2. `handleEvent` 对 ev57 / ev289 的失败分别记录：解压是否成功、解压后长度、Thrift 错误（含类型号与偏移）、解压后前 64 字节十六进制。

## 不在本版

Hey Meta 手机侧识别兜底（Opus → 语音识别）、Wi‑Fi 同网导入、取景改进、AccessorySetupKit。

## 测试与验收

- 单测：map/float/double；含 map 字段的 ev57 样例能取出文字；失败日志区分解压与解析；`GlassesAudioState`；`MetaAdvertisement`。
- `python3 tools/audit.py ios` clean；CI 全绿；版本 1.00 (100)。
- 真机验收：①冷启动不需要手动点即自动连上；②设备页显示「眼镜音频已接通」，「忽略此设备」后显示修复指引；③麦克风测试录到眼镜声音；④说「Hey Meta + 问题」，日志出现转写文字与模型回答，眼镜念出答案；若仍失败，日志给出具体解析错误。
