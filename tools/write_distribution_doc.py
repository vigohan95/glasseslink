import io

doc = u'''# 分发与签名（现状与选择）

目标：让别人（或未来的你）在 iPhone 上装到这个 app，同时不踩签名和许可的坑。

## 一、为什么 iPhone 上必须签名

iOS 只运行 Apple 签发过、且与本机 UDID 或开发者证书绑定的二进制。免费 Apple ID 给的是
「开发签名」，有效期 7 天；付费 Apple Developer（$99/年）给 1 年，并且能发 Ad Hoc（按 UDID）
与 TestFlight（90 天一轮）。

这跟「能不能逆向协议」是两件事：协议我们已经打通到真机 L2CAP，签名是 Apple 的信任链问题。

## 二、四条实际可走的路

| 方式 | 成本 | 有效期 | 需要电脑 | 适合 |
|---|---|---|---|---|
| 免费 Apple ID + Sideloadly | 0 | 7 天，重签 | 每次要 | 自己临时试 |
| SideStore / AltStore + StosVPN | 0 | 7 天，机内自动续签 | 首次要 | 自己长期用 |
| UDID 超级签名（闲鱼/淘宝代签） | ¥10–80 | 1 年 | 不要 | 自己长期用、给朋友装 |
| Apple Developer + Ad Hoc / TestFlight | $99/年 | 1 年 / 90 天 | 要 | 想正式发版 |

**换证书重签会清掉 Keychain。** owner 私钥默认存在 Keychain，所以第一次成功 trust 之后，
务必在「设备 → 成为这副眼镜的主人 → 导出 owner-export.json」把钥匙存到「文件」App。
文件版的钥匙不受重签影响，重装后导入即可继续当主人。

## 三、代签（UDID 超级签名）要准备什么

发给卖家：

1. 你的 ipa（`releases/GlassesLink-x.y.z.ipa`）
2. 你的 iPhone UDID（连接电脑后在 Apple 设备里看，或「设置 → 通用 → 关于本机」长按序列号）
3. 一句明确要求：**用 Ad Hoc 描述文件签，包含我提供的 UDID，不要用企业证书**

装完要确认四件事：能打开、能扫描到 `RB Meta`、`设备 → 高级 → 自检` 全绿、以及
`bundle id` 与之前一致（否则 Keychain 里的钥匙读不到，需要重新导入 owner-export.json）。

## 四、开源许可（这条不能省）

仓库里的 `ios/Resources/settings.tsv`、`settings_ui.json`、`varm_template.bin` 来自
**Visor（AGPL-3.0）**。AGPL 的要求是：分发二进制时必须提供对应源码，并保留许可与署名。

已经做的事：
- `docs/LICENSES.md` 写明三份文件的来源与许可
- app 内「设备 → 高级 → 关于 · 许可 · 隐私」列出 AGPL 与源码地址
- 仓库 `github.com/vigohan95/glasseslink` 本身就是这几份文件的源码位置

## 五、上架 App Store 的硬障碍

1. **AGPL 与 App Store 条款冲突**：Apple 的分发条款与 GPL 系许可的「额外限制」不相容。
   要上架必须替换那三份 Visor 数据文件（自己重建设置表与 VARM 模板），否则会有许可争议。
2. **Guideline 2.5.1 / 4.2**：使用非公开 BLE 服务与私有协议，审核时可能被要求说明；
   我们的做法是「用户自己的设备、自己的账号」，但这需要人工沟通。
3. **Meta 商标**：不能在产品名/图标里使用 Ray-Ban、Meta 的商标与外观。现在已经改成中性的
   「GlassesLink」与自绘眼镜图标。

结论：**自用与朋友分发走 UDID 超级签名；对外正式发版前，先把三份 Visor 数据文件替换掉，
再考虑 TestFlight。**

## 六、每次发新版本的最小流程

1. `tools/bump_version.py 0.50`（改的是 `info.properties` 里的两个键）
2. push → CI（`macos-15-intel`）出 ipa
3. `gh release create` + 复制到 `releases/`
4. 自用：Sideloadly 重签（同一 Apple ID，Keychain 保留）
5. 给别人：把 ipa 与 UDID 发代签
'''

p = r'D:\GlassesLink\docs\DISTRIBUTION.md'
io.open(p, 'w', encoding='utf-8', newline='\n').write(doc)
print('wrote', p, len(doc))
