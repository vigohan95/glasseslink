# 两条把「主人」身份拿到 iPhone 上的路线

眼镜只认一件事：**谁持有它记录的 owner 公钥所对应的私钥**。
所以不管是哪条路线，最后一步都是「iPhone 手里有一把眼镜认的私钥」，之后永远不需要再碰 Meta，也不需要安卓。

---

## 路线 A：iPhone 自己成为主人（推荐，不需要安卓）

```
iPhone app → Meta 登录一次 → 拿到 ownership receipt → 眼镜进入改主人状态（按一下拍摄键）
          → 眼镜把 owner 换成 app 生成的 P-256 私钥 → 以后只认这把
```

- **需要**：一次 Meta 账号登录（在 app 内的 WKWebView 里，不走 Safari，回调由 app 自己截）。
- **不需要**：安卓手机、导出文件、转换脚本。
- **代价**：换主人后，原来那台安卓上的 Visor 会失去权限（`0x1042`）；Meta AI app 若再配对会提示「已被其他应用程序使用」。
- **为什么可行**：`core/identity/.../Provision.kt` 里 Visor 的 owner key 就是 `KeyPairGenerator.getInstance("EC")` 生成的普通软件 P-256 私钥；`Trust.buildEnableTrust()` 只发「公钥摘要 + 对 channel binding 的签名 + capabilities」，**不含 receipt**。所以谁持有私钥，谁就是主人。

步骤：

1. 打开 GlassesLink →「3 · 成为主人」→「用 Meta 账号登录并注册这台 iPhone」。
2. 登录成功后 app 会自动走：`identity` → `skipChallenge` → `pair_request` → `startChangeOwner` → `pair` → `finishChangeOwner`。
3. 中途眼镜会要求确认（提示时按一下右侧拍摄键）。
4. 成功后 app 弹出 `owner-export.json`——**务必存好**（换签名主体会清 Keychain，文件版不受影响）。

---

## 路线 B：从安卓的 Visor 把钥匙搬过来（不碰 Meta 的服务器）

```
安卓装打过补丁的 Visor（包名 com.macedonga.visor.owner）→ 登录并配对一遍
→ app 把私钥写到 Downloads/visor-owner-<序列号>.json
→ 转成 owner-export.json → 导入 iPhone → 直接 trust
```

- **需要**：那台安卓 + 一次 Meta 登录（在安卓上）。
- **不需要**：在 iPhone 上碰 Meta。
- **好处**：眼镜的 owner 不变，安卓上的正版 Visor 仍然可用（两把钥匙？不——同一把，见下）。
- **注意**：这条路导出的是**眼镜当前认的那把私钥**，所以 iPhone 和安卓其实共用同一身份；但 Visor 的私钥被封在 AndroidKeyStore 里，只有打过补丁的构建才能把它以明文 PEM 写出来。

详细步骤见 `OWNER-MIGRATION.md`。

---

## 怎么选

| | 路线 A（iPhone 自己注册） | 路线 B（从安卓搬） |
| --- | --- | --- |
| 需要安卓 | 否 | 是（一次性） |
| iPhone 要连 Meta | 是（一次） | 否 |
| 安卓上的 Visor 之后还能用 | 不能（`0x1042`） | 能 |
| 步骤数 | 3 步 | 5 步（含装补丁包、导出、转换、导入） |
| 失败面 | 改主人这一步眼镜要按键确认 | 导出/转换/导入三处都可能出错 |

**建议**：先用路线 A。它一步到位、链路最短，而且正好满足「以后不带安卓」。
如果路线 A 在改主人那一步被眼镜拒绝（`0x1043` 或一直不回应），再退回路线 B——两条路的最终状态是一样的：iPhone 手里有一把眼镜认的私钥。

---

## 两条路共同的后续

1. `1 · 连接` → 点眼镜 → trust 握手（`0x1000` 即成功）。
2. 跑「2 · 自检」确认这把钥匙在真机上签名正常（Security 若不能导入，会自动走自研 P-256）。
3. 之后每次使用：只有 iPhone ↔ 眼镜的蓝牙链路，没有 Meta、没有安卓、没有云端。
