# 第三方代码与许可

本仓库包含的第三方材料，均来自 **Visor**（`https://github.com/macedonga/visor`，AGPL-3.0）：

| 文件 | 来源 | 用途 |
| --- | --- | --- |
| `ios/Resources/varm_template.bin` | `core/assistant/src/main/resources/varm_template.bin` | ev53（VARM）回答模板，眼镜据此用自己的 TTS 念答案 |
| `ios/Resources/settings.tsv` | `core/settings/src/main/resources/.../settings.tsv` | 371 项眼镜设置的表（字段号 / 类型 / 默认值 / 命名空间） |
| `ios/Resources/settings_ui.json` | `core/settings/.../settings_ui.json` | 设置的界面元数据（标题、分组、控件范围） |

`meta-gen2/visor-src/` 是 Visor 的一份检出，仅用于阅读协议实现与构建导出 owner key 的补丁版 APK（`com.macedonga.visor.owner`）。

## 因此

- 本仓库整体按 **AGPL-3.0** 分发；公开仓库即满足"提供对应源码"的要求。
- 如果将来把 app 上架 App Store 或闭源分发，需要先替换上面三份数据（用自己逆向/生成的等价物），或取得 Visor 作者的额外授权。
- 协议本身（AirShield / DataX / svc 编号）是事实性信息，不受版权保护；本仓库里它是由 `pi/` 的 Python 实现与 `ios/` 的 Swift 实现分别独立转写出来的。
