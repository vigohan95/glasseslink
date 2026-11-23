# Pi 网关：让眼镜脱离安卓

目标：眼镜 ↔ 小盒子（BLE）↔ 浏览器（iPhone）。日常不再需要任何安卓机、也不需要 Meta app。

## 这套代码到哪一步了（别被"未验证"骗到）

| 模块 | 内容 | 状态 |
|---|---|---|
| `airshield.py` | DataX 封帧、protobuf、RequestEncryption / EnableEncryption、KDF、channel binding、AES-256-CBC + HMAC 分帧、padding、IV 链、seq | **逐字节对齐官方协议文档**，`selftest.py` 12 组全过 |
| `session.py` | 握手 → svc36 信任 → EndLinkSetup → 通道复用 → svc18 拍照清单 → svc20 Airship 收文件 | 逻辑完备，被 `selftest_session.py` 用**真实加密的对端**跑通（见下） |
| `selftest_session.py` | 用同一套原语实现一台"假眼镜"，双向校验 KDF 互为镜像、验签、UUID 门、清单解析、文件传输 + type 7 回执 | **ALL OK**（`[1]`–`[5]` 全绿） |
| `transport_bluez.py` | Linux LE L2CAP CoC（`SOCK_SEQPACKET` + `BTPROTO_L2CAP`，PSM 128） | 按内核 API 写，未在真硬件上跑过 |
| `gateway.py` | HTTP + PWA，接口与安卓桥完全一致 | 已在本机起服务验证 `/`、`/api/status` |
| `ownerkey.py` | P-256 私钥、NONEwithECDSA 预哈希签名、低 s 折叠、r‖s | 被假眼镜验签通过 |
| `meta_identity.py` | Meta 侧：OIDC 登录 → FRLA → AR token → `pair_request` / `pair` 两张 ownership receipt | 端点、字段、gzip 表单都对齐 Visor 源码；`login/whoami` 可用 |
| `provision.py` | 把两边缝起来：握手（不信任）→ svc36 identity/skip_challenge/start/finish → 落盘 `owner-export.json` | `selftest_provision.py` 用假眼镜 + 假 Meta 跑通（`[1]`–`[4]` 全绿） |
| `selftest_provision.py` | 无硬件、无网络的 owner 变更全流程验证 | **ALL OK** |

```
$ python3 selftest.py              # 12/12 编解码向量
$ python3 selftest_session.py      # ALL OK: 握手/信任/清单/传文件
$ python3 selftest_provision.py    # ALL OK: 改 owner 全流程（假眼镜 + 假 Meta）
```

**唯一没被真实硬件证明过的**是"眼镜愿不愿意跟一个非安卓的中心设备建 L2CAP 链路"。协议文档写的是"手机上跑"，眼镜侧对第二台中心设备是否放行，只有上板子才知道。

## 硬件

| 件 | 说明 | 价格 |
|---|---|---|
| Raspberry Pi Zero 2W（或任意 Pi 4/5） | 需要 BlueZ，内核 ≥ 5.10 | ¥100–350 |
| microSD 32 GB + 电源 | 官方 Raspberry Pi OS Lite (64-bit) | ¥40 |
| USB 蓝牙 5.x 适配器（可选） | Pi Zero 2W 板载 BT 4.2 够用；要稳就插 CSR8510/Realtek 8761 | ¥30 |

不建议 ESP32：跑不动 AES-256-CBC + P-256 + protobuf 这一套，而且 L2CAP CoC 的 MTU 协商太受限。

## 一次性动作：让盒子成为 owner（不用再碰安卓）

眼镜认的是"配对时那把 owner 私钥 + Meta 签的 ownership receipt"。既然私钥本来就存在
AndroidKeyStore 里拿不出来，就让盒子**自己生成一把新钥匙**、**自己向 Meta 换一张 receipt**，
把 owner 换成盒子。这正是 Visor 首次配对时做的事，只是现在由 Pi 直接干。

```
# 1) 登录（iPhone 或电脑浏览器都行，登录"现在拥有这副眼镜"的那个 Meta 账号）
python3 meta_identity.py login --store identity
#    打印一个 accounts.meta.com 的 URL → 登录 → 把落地的整条 redirect 地址粘回来

# 2) 换取 AR token 并存下（12 小时内复用，避免把旧 session 顶掉）
python3 meta_identity.py whoami --store identity

# 3) 改 owner：盒子生成新 P-256 钥匙，跟眼镜做 svc36 四步，向 Meta 换两张 receipt
python3 provision.py --address 80:AA:1C:98:18:0B --store identity
#    中途若打印 "PRESS THE CAPTURE BUTTON"，按一下眼镜的拍摄键（部分批次需要）

# 4) 从此眼镜认的是盒子这把钥匙
python3 gateway.py --address 80:AA:1C:98:18:0B --store identity --port 8787
```

产物是 `identity/owner-export.json`（私钥 + serial + Meta 最终 receipt），格式与
`tools/adb_export_owner.py` 完全相同，两边可以互换。之后每天只要第 4 步。

协议层的顺序（`provision.py` 里就是这几行，日志逐条对应）：

```
L2CAP PSM 128 → RequestEncryption / EnableEncryption → EndLinkSetup      （不做 trust）
svc36 0x3000 IDENTITY_REQUEST      ← 0x3001 {1: cert DER, 2: serial, 5: secondary}
svc36 0x2000 SKIP_CHALLENGE        ← 0x2001 {1: 16B device nonce}
POST graph.facebook-hardware.com/pair_request   (gzip 表单, HW token + user AR token)
      + device_cert / serial_number / additional_data{device_nonce, app_pubkey, secondary_cert}
      → pending_ownership_receipt + receipt_signature
svc36 0x2002 START_CHANGE_OWNER_REQ {1: sig, 2: json}
                                   ← 0x2003 device pending {1: sig, 2: json}
POST graph.facebook-hardware.com/pair          → final_ownership_receipt
svc36 0x2004 FINISH_CHANGE_OWNER_REQ           ← 0x2005 ack
```

失败码就看 `session.ID_STATUS_NAMES`：`0x1042` = 这副眼镜已经属于另一个 Meta 账号
（换账号登录或恢复出厂）、`0x1040` receipt 坏、`0x1043` app identity 不对、`0x1045` 时间偏差太大。

## 备用路线：从安卓里抠 owner 私钥（10 分钟）

眼镜认的是"当初配对时那个 owner 私钥"。Visor 把它放在 Android 里，Pi 必须有同一把钥匙才能过 svc36 信任。

```
# 在电脑上（手机插 USB，USB 调试已开）
python tools/adb_export_owner.py --serial SM02E4072814739
# 产出 owner-export/owner-export.json
```

**实测结论**：这条路在这台 Solana Seeker（Android 16、未 root、Visor 非 debuggable）上走不通 ——
`root` / `run-as` / `adb backup` 全被拒（`.ab` 只有 47 字节）。Visor 用 `KeystoreSealer`（AndroidKeyStore
alias `visor.identity.store`，AES-256-GCM）封装 `identities.sealed`，容器在设备外打不开。
所以正式路线是上面的「让盒子成为 owner」。

把 `owner-export.json` 丢到 Pi 的 `/etc/glasses/` 或 `pi/` 目录下即可（`ownerkey.find_owner()` 会自己找）。

## 上板子

```bash
# 1. 系统
sudo apt update && sudo apt install -y python3-cryptography bluez
sudo systemctl enable --now bluetooth

# 2. 代码
scp -r meta-gen2/pi pi@<box-ip>:~/glasses/
ssh pi@<box-ip>

# 3. 找眼镜（展开镜腿，别折叠）
bluetoothctl
  power on
  scan on            # 找 "RB Meta 046N" → 记下地址 80:AA:1C:98:18:0B
  pair 80:AA:1C:98:18:0B
  trust 80:AA:1C:98:18:0B
  quit

# 4. 先跑协议自测（不碰眼镜）
cd ~/glasses/pi && python3 selftest.py && python3 selftest_session.py

# 5. 真机握手
python3 - <<'PY'
from transport_bluez import LecocoTransport
from ownerkey import find_owner
import session as S
t = LecocoTransport(address="80:AA:1C:98:18:0B", psm=128)
s = S.GlassesSession(t, find_owner(), log=print)
s.handshake()
print("link up; captures:", [c.handle for c in s.capture_list()])
PY

# 6. 常驻
python3 gateway.py --address 80:AA:1C:98:18:0B --port 8787
# iPhone Safari: http://<box-ip>:8787/
```

第 5 步是最关键的 30 秒：`handshake()` 打印的每一帧都带 hex，出错会明确告诉你是
`KEY_NOT_FOUND`（钥匙不对）、`INVALID_APP_IDENTITY`（receipt 过期）、
`INVALID_SIGNATURE`（binding 算错）还是 `LinkTimeout`（眼镜折叠/没唤醒）。

## 故障对照

| 现象 | 原因 | 处理 |
|---|---|---|
| `LinkTimeout` 握手第一阶段 | 眼镜折叠休眠 / 不在范围内 | 展开镜腿、戴上、靠近 |
| `OSError: Protocol not supported` | 内核没编译 `BT_PROTO_L2CAP` | 用官方 Raspberry Pi OS，别用精简容器 |
| `Permission denied` 建 socket | 需要 `CAP_NET_ADMIN` | `sudo` 运行，或 `setcap` |
| `TrustRejected 0x1043` | owner receipt 缺失/过期 | 走 `PROVISION.md` 重新拿 receipt |
| `TrustRejected 0x1010` | 钥匙不是这副眼镜认识的 | 换正确的 `owner-export.json` |
| 拍完照清单里没新条目 | 拍照在眼镜侧完成，盒子只能"读清单" | 按一下眼镜的拍摄键（这是眼镜的设计，不是 bug） |

## 拍照这件事要说清楚

盒子**不能远程按快门**：svc18 公开的是"枚举清单 + 请求资产"，没有"现在拍一张"的指令。
眼镜端由物理按钮触发拍照（或语音 "Hey Meta, take a photo"）。所以日常流程是：

1. 按一下眼镜 → 眼镜拍好、存本地
2. iPhone 上点"拍一张" → 盒子枚举清单、挑最新那张、走 Airship 拉回来
3. 同一份图直接喂给模型

如果你要"远程触发拍摄"，那需要在固件层面动（visibility 那段研究），不在协议层能解决的范围。
