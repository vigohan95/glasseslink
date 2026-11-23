# 只用 iPhone：安装与首次使用

这份文档对应 `ios/` 里的原生客户端。它不经过任何电脑桥接、不需要安卓：
iPhone 自己用蓝牙 L2CAP(PSM 128) 和眼镜说 AirShield，自己当 owner，自己拍照、自己调模型。

构建产物由 GitHub Actions 产出（本机没有 Xcode）：

- 仓库：https://github.com/vigohan95/glasseslink
- 每次 push 会自动跑 `.github/workflows/ios.yml`，产物在 run 页面底部 **Artifacts → GlassesLink-ipa**，里面是 `GlassesLink.ipa`（未签名）。

## 一、把 ipa 弄到 iPhone 上（三条路，选一条）

| 方式 | 成本 | 有效期 | 说明 |
|---|---|---|---|
| Sideloadly + 免费 Apple ID（Windows 电脑，USB 线） | 0 元 | **7 天**，到期重签 | 最稳，先走这条验证功能 |
| SideStore + StosVPN | 0 元 | 7 天，但**手机自己续签**，不用电脑 | 首次仍需电脑装一次 SideStore |
| 付费开发者账号 | 688 元/年 | 1 年 | 一次到位 |

Sideloadly 步骤：
1. 电脑装 Sideloadly，iPhone 用 USB 连电脑。
2. 把 `GlassesLink.ipa` 拖进 Sideloadly，Apple ID 填你的，Start。
3. iPhone 上「设置 → 通用 → VPN与设备管理」信任你的开发者证书。
4. iOS 17+ 还要开「设置 → 隐私与安全性 → 开发者模式」，重启一次。

iOS 27.2 不存在永久免费签名（TrollStore 停在 17.0），这是苹果签名链本身决定的，不是我们的代码问题。

## 二、首次运行：让 iPhone 成为主人

眼镜只认「Meta 签过字的 ownership receipt + 对应私钥」。所以第一次要借 Meta 的接口签一张，
之后就再也不需要它了。app 里点一次就完成：

1. 眼镜展开、贴近手机。点 **扫描附近眼镜** → 点你的眼镜名。
2. 第一次连接走 setup 链路（不做 trust，因为还没有 owner key）。
3. 点 **用 Meta 账号登录并注册这台 iPhone** → 系统浏览器弹出 Meta 登录页
   （`accounts.meta.com/oidc`，app_id `934401142814369`）→ 登录 → 自动回跳。
4. app 自动跑完六步：`identity → skip_challenge → /pair_request → START_CHANGE_OWNER
   → /pair → FINISH_CHANGE_OWNER`，期间**可能要求按一下眼镜的拍摄键**（4 秒后提示）。
5. 成功后 `owner-export.json` 会存进 Keychain 与文件，`isOwner` 置位。断开重连一次，就走
   trust 链路了。

如果失败，看日志里的状态码：

| 码 | 含义 | 处理 |
|---|---|---|
| `0x1042` | 这副眼镜已经属于另一个 Meta 账号 | 必须用**原来那个**账号登录，或先把眼镜恢复出厂 |
| `0x1043` | app identity 不被接受 | 检查 Info.plist 里的 client token 是否还有效 |
| `0x1044` | 签名不对 | 私钥和 receipt 不配套，删掉重来 |
| `0x1010` | 眼镜上没有我们的公钥 | 重跑一次 START_CHANGE_OWNER |

## 三、日常使用

- **拍照**：眼镜上按一下拍摄键（快门永远在眼镜上，协议没有「远程按快门」）。
- app 里点 **拉取最新一张照片**：走 `svc18` 枚举清单 → `0x83` 请求资产 → `svc20` Airship
  分块接收 → 存进相册。2.7 MB 的照片在蓝牙链路约 20–30 秒。
- **问模型**：填 `base URL`（任何 OpenAI 兼容端点，例如家里的
  `http://192.168.3.90:11434/v1` + `gemma3:4b`，或云端 API），点「看图问答」。图片在 app 内
  缩到 1280 px 再上传。

## 四、已知边界

- iOS 没有 Wi-Fi Direct：视频（几百 MB）走蓝牙不现实，照片没问题。
- 眼镜同一时刻只允许一个 AirShield 会话：开着这个 app 时，安卓那台 Visor 会抢不到链路，
  反之亦然。
- 手机重启后要重新点一次连接（系统会断 BLE）。
- 想让模型跑在手机上（MLX / 本地小模型）是另一件事，可以后续加；现在默认走局域网或云端端点。
