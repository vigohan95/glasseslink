# Glasses Bridge —— 你的 Ray-Ban Meta Gen 2，不经 Meta 云

现在这套东西是**已经跑通并实测过**的，不是方案：

```
iPhone Safari  →  这台电脑 (bridge, :8787)  →  Visor (手机 :7333)  →  眼镜 (蓝牙 L2CAP)
                        ↓
                 本地大模型 (Ollama gemma3:4b)
```

Meta 云只在**一次性配对**时出现过一次，之后拍照、取图、视觉问答全部走本地。

## 每天怎么用（3 步）

1. 手机蓝牙开着，打开 **Visor**（后台常驻即可），镜腿展开戴上 —— 电量 20% 以上
2. 电脑双击 **`START-BRIDGE.bat`**（会用固定 token 连上手机）
3. iPhone Safari 打开 **http://192.168.3.90:8787/** → 分享 → 添加到主屏幕

之后点主屏图标就是这个界面：拍一张 / 看图问答 / 纯文字 / 刷新状态。

## 关键参数（已写进 config.json）

| 项 | 值 |
|---|---|
| 眼镜 | Ray-Ban Meta (Gen 2)，序列号 `4V0ZW04H7J046N`，固件 `72387580112400100` |
| Visor 门 | `ws://192.168.3.82:7333/rpc`（手机开「允许局域网访问」） |
| kit token | `hYZVoFGkkq_1wlKshsEJg1utKW2nazkG`（程序名 `iphone-bridge`，权限：状态/你的眼镜/触摸和按键/动作/麦克风/相机） |
| Bridge | `http://192.168.3.90:8787/`，access_key 为空 |
| 模型 | Ollama `gemma3:4b`，`http://127.0.0.1:11434/v1`，图像先缩到 1280px 再喂 |

## 换模型 / 换云端

编辑 `config.json` 的 `model`：

```json
"provider": "openai",
"base_url": "https://api.deepseek.com/v1",   // 任何 OpenAI 兼容端点
"api_key": "sk-...",
"model": "deepseek-chat"
```

本地更快的视觉模型：`ollama pull qwen2.5vl:3b` 然后把 `model` 改成它。
不支持图像的模型把 `"vision": false` 关掉即可（问答仍可用，图片不再上传）。

## 为什么照片要 adb

Visor 的 `captures.import` 只回一个 `content://` 引用，不回字节。所以 bridge 用
`adb pull /sdcard/Pictures/Visor/<最新>.jpg` 把原图取回。想要完全无线：

- 拍照 → 手机相册里已经有 `Pictures/Visor/`
- 或者打开 Visor 的「实时画面」，bridge 会走 `camera.live.photo` 直接拿 base64（无需 adb，但画质是预览帧）

## 权限与边界（实测结论）

- 眼镜的 **owner 记录**靠一次 Meta 登录 + ownership receipt 拿到，**换账号会重新校验**；拿到之后 Visor 就是主设备，日常不再联系 Meta。
- 固件 `72387580112400100` 属较新版本，未做签名绕过，也没有刷机 —— 全部是**官方 protocol 的合法客户端**行为。
- 「完全零 Meta」的极限：配对那一次必须有网络。之后如果你把手机断网、只留蓝牙 + 局域网，眼镜照常工作（已验证：拍照、取图、温度、电量、音量都正常）。

## 故障对照

| 现象 | 原因 | 处理 |
|---|---|---|
| `/api/status` 里 `visor_ok: false` | 手机没开 Visor / 门没开 / token 变 | 打开 Visor → 设置 → 应用，确认「允许程序连接」「允许局域网访问」都开着 |
| 拍照 502 `capture produced no bytes` | 眼镜折叠休眠 | 展开镜腿、按一下拍摄键再重试 |
| 拍照成功但没图 | USB 断了，adb 取不到 | 插回 USB，或改用实时画面 |
| 蓝牙连不上（日志 `status=8`） | 眼镜睡了 | 展开镜腿保持在手机旁 20 秒 |

## 文件位置

- `bridge/server.py` —— HTTP + PWA + 模型调用（含 adb 取图、图像缩放）
- `bridge/visor_client.py` —— stdlib 手写 WebSocket + JSON-RPC
- `bridge/web/index.html` —— iPhone PWA 界面
- `config.json` —— 上面那张表的来源
- `START-BRIDGE.bat` —— 双击启动
- `pi/` —— 原生协议栈（Python，L2CAP/AirShield/DataX 已自测通过），用于将来做**不带手机**的盒子
