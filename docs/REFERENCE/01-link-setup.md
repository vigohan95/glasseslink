# 01 · 链路建立

出处标注：**P** 公开协议说明 · **R** 参考实现源码 · **O** 真机观测。

## 1. 传输

| 项 | 值 | 出处 |
| --- | --- | --- |
| Ray-Ban Meta / Oakley Meta 的 PSM | `0x80`（128） | P + O（`L2CAP up psm=0x80`） |
| Burbank Audio / Neural Band 的 PSM | `0x81` | P |
| PSM 从哪读 | GATT 特征 `05acbe9f-6f61-4ca9-80bf-c8bbb52991c0`，服务 `0000fd5f-0000-1000-8000-00805f9b34fb` | P |
| 链路层是否额外加密 | 否；加密全部在本层之上 | P |
| 备用传输 | Classic RFCOMM，SDP UUID `8b0d2687-42a4-44cb-9436-fba3b9b96de2`，channel 7 | P |

## 2. 四条握手消息

全部明文，走 DataX 帧（见 `02-datax.md`）。

| 顺序 | 通道 | 类型 | service tag | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `0x8001` | `1` RequestEncryption | **带** `service=5` | 我方公钥 + 挑战 + 参数 |
| 2 | `0x0001` | `2` EnableEncryption | **不带** | 我方公钥 + seed + IV + 起始序号 |
| 3 | 同上两条 | 对端发来 | — | 顺序可颠倒，必须都收到 |
| 4 | `0x8001` | `0x1000` EndLinkSetup | — | 第一条**加密**帧 |
| 5 | 镜像通道 | 状态帧 | — | 应答 `0x1000` |

**关键细节（R）**：只有第一条消息带 service tag。
`SecureLink.sendLinkSetup` 的原文注释是 *"The serviceId tag goes on the first message of the exchange only"*，
代码是 `val serviceId = if (messageType == REQUEST_ENCRYPTION) ServiceId.LINK_SETUP.value else null`。
多带一个 service tag，设备会忽略这条消息、并且**不会回自己的 EnableEncryption** —— 真机表现是 12 秒静默（O）。

## 3. RequestEncryption 载荷

| 字段 | 类型 | 值 |
| --- | --- | --- |
| 1 | bytes | 64 字节公钥（x‖y，无 `0x04` 前缀，大端定长） |
| 2 | bytes | 16 字节随机挑战 |
| 3 | varint | 曲线编号，`0` = secp256r1 |
| 4 | varint | 参数位，`31` |
| 5 | bytes | key hints（12 字节，可省） |
| 6 | varint | quirks（缺失 = 0；`1` = QCS7 变体） |
| 7 | varint | 协议版本，真机发 `16`/`17`（O） |

## 4. EnableEncryption 载荷

| 字段 | 类型 | 值 |
| --- | --- | --- |
| 1 | bytes | 64 字节公钥 |
| 2 | bytes | 32 字节 seed |
| 3 | bytes | 16 字节 IV（只作为**起始** IV，随后每帧链式取上一段密文末块） |
| 4 | varint(u32) | 起始序号 |
| 5 | varint | 参数位，`31` |
| 6 | varint | quirks（省略 = 0） |

## 5. 密钥派生（P + R）

```
salt_aes  = SHA256(nonce ‖ seed)
salt_hmac = SHA256(seed ‖ nonce ‖ "hmac_derive")
PRK       = HMAC-SHA256(salt, shared)            # shared = ECDH 的 32 字节 x 坐标
key       = HMAC-SHA256(PRK, info)               # 32 字节
```

- 两个方向各算一次：
  - **收**：`nonce = 我方挑战`，`seed/IV = 对端 EnableEncryption` 里的值；
  - **发**：`nonce = 对端挑战`，`seed/IV = 我方 EnableEncryption` 里的值。
  （参数顺序搞反 → 每一帧都 `bad MAC`，这是最容易错的一处。）
- `info`：普通变体 = `"AirShield"`（HKDF 展开时补 `0x01`）；QCS7 变体 = `"AirShield"` 补零到 128 字节，再拼 `32 00 00 00 00 01 00 00`（136 字节）。
- `multikey`：四个参数位都带 `4` 时成立（`31 & 31 & 31 & 4 = 4`）。成立时 AES 与 HMAC 用两把不同密钥；不成立时共用。
- MAC 前缀：`02 02 00 q`，`q` 在 QCS7 变体下为 `1`。

## 6. EndLinkSetup

46 字节明文，未加密时是这样，加密后作为第一条 DATA 帧：

```
80 2A 80 01 02 00 10 00            头（通道 0x8001，类型 0x1000，长度 0x2A）
08 01                              字段1 varint = 1
12 10 <16B stream UUID>            字段2 = 流 UUID（必须 RFC4122 v4）
1A 10 <16B link UUID>              字段3 = 链路 UUID（必须 RFC4122 v4）
```

两个 UUID 必须是 v4（`b[6]&0xF0==0x40`、`b[8]&0xC0==0x80`），否则设备静默丢弃、表现为 "service not found"（P）。
握手前两条消息无法拿到 UUID 时，先发占位 v4，拿到会话后再发真实值。

应答是**裸状态帧**（只有 error tag、没有 type），成功 `0x1000`。
有的固件干脆不回（O），所以 2 秒等不到就继续，不要阻塞后续 trust。

## 7. 状态码

| 码 | 含义 |
| --- | --- |
| `0x0000` | 成功（部分镜像通道用这个） |
| `0x1000` | 成功（svc36 与 EndLinkSetup 用这个） |
| `0x1010` | KEY_NOT_FOUND：设备不认识这把公钥 |
| `0x1040` | INVALID_RECEIPT |
| `0x1041` | INVALID_NONCE |
| `0x1042` | INVALID_USER_ID：设备属于另一个账号 |
| `0x1043` | INVALID_APP_IDENTITY |
| `0x1044` | INVALID_SIGNATURE |
| `0x1045` | INVALID_TIME：手机时间偏差过大 |
| `0xC001` | service_not_found |
