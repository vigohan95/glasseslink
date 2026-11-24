import io

root = r'D:\GlassesLink'

change = u'''

## 0.26 – 0.43 （2026-11-23 ~ 11-24）修正与形态重做

这一段的主题是「让它在真机上真的能用」，以及把调试面板改成产品。

### 协议与密码学
- `doTrust` 判定反了：把 `0x0000` 当成功、把眼镜真实返回的 **`0x1000`** 当失败，等于签名全对也报 trust 失败。已按参考实现改为只接受 `0x1000`。
- `AirShield.deriveKeys` / `sessionKeys` 改为 `throws`，把 `precondition` 换成带长度的 `LinkError.unexpected`——release 包里 `precondition` 会直接 abort，表现为「点连接就闪退」。
- `OwnerMaterial.publicKeyXy` 有时只有 63 字节（CryptoKit 的 `rawRepresentation` 不保证补零），改为从 DER 取定宽 65 字节。
- 自研 P-256（`ios/P256.swift`）：Jacobian 坐标 + Montgomery 域，逐字节对齐 `tools/p256_ref.py`；修掉 `words` limb 反序、混合加法漏因子 2、`pkcs8` 的 AlgorithmIdentifier 长度少 1 字节。
- `SDUStream.nextFrame` 不再阻塞调用方队列（改为泵 RunLoop），这是回环测试连续六轮挂住的真因。

### 真机
- **iPhone → 眼镜的 LE CoC 在真机上打通了**（`L2CAP up psm=0x80`）。这是整个方案最关键的一次验证。
- 没有 owner key 时不再空转，改用临时密钥把 setup 链路跑起来（`phone -> plain` → `ecdh ok` → `EnableEncryption`）。
- 日志跨线程写 `@Published` 数组会让进程被杀（表现得像闪退），已统一回主线程。
- 连点会占住 PSM（`L2CAP PSM already connected`），加了 `connecting` 守卫、`断开` 按钮与 `didClose` 复位。

### 形态
- 按 fable-5-2 的交互评审重做：四个任务页（相册/拍摄/助手/设备），每页常驻状态胶囊；相册区分「眼镜里的队列」与「已导入、离线可看」；导入是串行队列 + 逐行状态；拍摄与取景合成一页；模型配置移到二级页；诊断降级到「设备 → 高级」。
- 相册缩略图真实化：导入时生成 168×168 JPEG 落盘 `Documents/thumbs/`，重启与离线都能显示。
'''

bug = u'''

## J. trust 判定把成功码当失败（0.26 修）

`guard code != stOK else { return }`：`stOK` 是 `0x0000`，而眼镜在 ENABLE_TRUST 上回的是 **`0x1000`**。结果每次 trust 都被当成失败抛出，日志里看到的是一个「莫名其妙」的拒绝。修法：只接受 `0x1000`（`AirShield.stSuccess`）。

## K. release 包里的 precondition 会 abort（0.38 修）

`AirShield` 用 `precondition` 校验长度。debug 下是断言失败，release 下直接 `SIGABRT`——用户看到的是「点连接立刻闪退，重进 app 日志停在 EnableEncryption sent」。全部换成 `throws` + 把实际长度写进错误消息，这样坏帧会变成一行可读日志。

## L. 日志跨线程写 @Published（0.39 修）

蓝牙读线程直接 `log.append(...)`，与 SwiftUI 的渲染线程抢同一块存储，进程被杀。表现和上面一样（启动→点连接→闪退）。`note()` 现在统一派发到主线程。

## M. 连点把 PSM 占住（0.36 修）

CoreBluetooth 的 PSM 在关闭后要几秒才释放，连点七次会得到七条 `L2CAP PSM already connected`。加了 `connecting` 守卫、`断开` 按钮、`didClose` 复位，以及「already connected 时 1.5 秒后重试一次」。

## N. shell 展开吃掉 Swift 绑定（0.42 修）

用 PowerShell here-string 写 Swift 时，`@"..."@` 会展开 `$picking`/`$signingIn`，把 `.sheet(isPresented: $signingIn)` 写成 `.sheet(isPresented: )`，CI 报 `value of type 'some View' has no member 'sheet(isPresented:)'`。**含 `$` 与中文的源码一律用编辑工具写，不走 shell 重定向。**

## O. nextFrame 堵住调用方队列（0.34 修）

`cond.wait` 在 main run loop 的 stream 上等数据，等于让主线程睡死，`stream(_:handle:)` 永远不触发。改为每 10 ms 泵一次 RunLoop 再复查缓冲。
'''

def append(path, text, marker):
    s = io.open(path, encoding='utf-8').read()
    if marker in s:
        return False
    io.open(path, 'w', encoding='utf-8', newline='\n').write(s.rstrip() + '\n' + text)
    return True

print(append(root + r'\CHANGELOG.md', change, '0.26 – 0.43'))
print(append(root + r'\BUGLOG.md', bug, '## J.'))
