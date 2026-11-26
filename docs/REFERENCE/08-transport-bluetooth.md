# 08 · 蓝牙与传输层

出处：**R** `core/transport/*`（9 个文件）· **P** 公开协议说明 · **O** 真机。
这一份只讲"字节怎么从手机走到眼镜"：发现、连接、分帧、保活、日志。

## 1. 设备发现

| 项 | 值 / 做法 |
| --- | --- |
| GATT 服务 | `0000fd5f-0000-1000-8000-00805f9b34fb` |
| PSM 特征 | `05acbe9f-6f61-4ca9-80bf-c8bbb52991c0`（读出的值即 L2CAP PSM） |
| 厂商号 | 广播里的 manufacturer data 前两字节小端 = `0x01AB`（眼镜常常不带名字，这是唯一可靠标记） |
| 配对态 | 手机与眼镜在 BR/EDR 与 LE 两侧都已绑定；绑定后 LE 侧直接可连，不必每次进配对模式 |

## 2. 三种传输

| 实现 | 文件 | 说明 |
| --- | --- | --- |
| BLE L2CAP CoC | `BluetoothLeTransport.kt` | 默认路径。`BluetoothDevice.createL2capChannel(psm)`，连接后拿到 `BluetoothSocket` 的输入/输出流 |
| Classic RFCOMM | `BluetoothRfcommTransport.kt` | 备用。SDP 服务 UUID `8b0d2687-42a4-44cb-9436-fba3b9b96de2`，映射到 RFCOMM channel 7 |
| TCP over Wi-Fi | `TcpTransport.kt` | 导大文件/取景。承载**原始 SDU**，分帧方式与 RFCOMM 完全一致 |

三者实现同一个接口：

```kotlin
interface Transport {                 // core/transport/Transport.kt
    suspend fun open()
    suspend fun send(sdu: ByteArray)
    suspend fun receive(): ByteArray  // 一条完整 SDU
    fun close()
}
```

**关键点**：`send` 的粒度是"一条 SDU"，不是字节。谁在上层切帧，谁就要保证一次 `send` 恰好一条消息。

## 3. SDU 分帧

`Sdu.kt` + `SduStream.kt`：

- 一条 SDU 的长度由头部前两字节决定：`bit7` 为 hasExtension，`bit6..0` 与 `bit14..8` 组成 14 位长度；
- 流式传输时按 `4 + payloadLen` 累积；**一条 SDU 恰好对应一条 DataX 消息**（含 tag 区）；
- 跨 SDU 的消息不存在——消息大了就拆成多条，由上层重组（见 `SubstreamRelay`）。

实现时三个坑（都踩过）：

1. `Data.removeFirst(n)` 只挪 `startIndex`，之后按绝对下标读会越界；
2. 头部声称的长度可能大于实际缓冲（半包），要等；
3. 解析失败不要拆链路——短帧可能只是尾巴。

## 4. 保活

`LeKeeper.kt`：持有一条 LE 连接，让眼镜知道"手机还在"。

- 眼镜在断开后会进入可连接广播状态，此时可直接重连；
- 若上次连接处于"握手中途"，重连前先清掉残留（否则 PSM 报 already connected，需退避 5–30 秒）；
- 一条链路同时只允许一个会话；手机侧要主动 `cancelPeripheralConnection` 清理旧对象。

## 5. 速率与链路质量

`LinkMeter.kt` 记录"最近一次收到数据的时间"，用于：

- 判断链路是不是假死（收到过就重置计时）；
- 取景时估算可用码率（蓝牙约 120–165 KB/s，Wi-Fi 约 10 MB/s）；
- 决定是否把大文件切到 Wi-Fi（`media/Wifi.kt` 的 svc10 与 svc18 的 `0x86`）。

## 6. 线路日志

`WireLog.kt`：把**每个方向的每条 SDU** 原样写入文件，用于"这次失败和上次成功逐字节对比"。
格式建议：`时间戳 方向 长度 十六进制`，一行一条；对照时先比长度、再比头、最后比载荷。

我们的实现对应 `ios/Session.swift` 的 `emit(..., inbound:)` 与「详细日志」开关。
