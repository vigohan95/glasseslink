# 13 · 身份、配对与云侧接口

出处：**R** `core/identity/*`（36 个文件）· **P** · **O**。

这一层负责三件事：**这台手机是谁**（账号令牌）、**这副眼镜归谁**（所有权凭据）、**两者怎么在眼镜上绑定**（svc36 交换）。
我们自己的客户端只在前两件事上需要联网，第三件纯本地。

## 1. 文件分组

| 组 | 文件 | 作用 |
| --- | --- | --- |
| 账号令牌 | `token/WebLogin.kt`、`token/AccountToken.kt`、`token/Frla.kt`、`token/Token.kt`、`token/LinkedAccounts.kt` | OIDC 登录、令牌交换、AR/FRLA 令牌 |
| 所有权 | `provision/Provision.kt`、`provision/ProvisionSession.kt`、`provision/PyJson.kt` | 取 pair 凭据、走 svc36 变更 |
| 密钥存储 | `KeystoreSealer.kt`、`IdentityStore.kt`、`KeyPairFactory.kt` | 密封存储、当前身份、EC 密钥对 |
| 信任 | `Trust.kt`、`TrustState.kt` | 组装 ENABLE_TRUST、记录结果 |
| 目录/样式 | `Catalogue.kt`、`Styles.kt`、`Assets.kt` | 镜框款式、渲染预览 |
| 数据面 | `Bloks.kt`、`BloksGraph.kt`、`Constellation.kt`、`Graph.kt`、`GraphVariables.kt` | 图形化查询接口 |
| 会话 | `MetaSession.kt`、`MetaSessionStore.kt`、`DeviceRegistration.kt` | 会话缓存与设备注册 |

## 2. OIDC 登录（`WebLogin.kt`）

```
授权：https://accounts.meta.com/oidc/
      ?app_id=934401142814369
      &scope=openid
      &response_type=code
      &redirect_uri=https://accounts.meta.com/native/oidc/redirect/metaai
      &state=<随机>
兑换：POST https://api.accounts.meta.com/native/oidc/token-exchange/
      form: mt_app_id / oidc_auth_code / redirect_uri
返回：access_token（AR 用途）、id_token、过期时间
```

要点：

- 授权页要能在应用内的 WebView 打开；回调是 `https://` 形式，`ASWebAuthenticationSession` 拦不到，要在导航回调里截 `code=`；
- 令牌有有效期，过期要用 refresh；
- 账号令牌只用来"证明这台手机代表某个账号"，不参与链路加密。

## 3. 所有权凭据

`Provision.kt` 的两个调用：

```
POST https://graph.facebook-hardware.com/…（pair_request）
  access_token=HW 令牌
  user_access_token=AR 令牌
  user_token_universe=ar
  pair_protocol_version=4
  device_cert=<b64 DER>
  serial_number=<眼镜序列号>
  additional_data={"device_nonce":…,"app_pubkey":…,"secondary_cert":…}
  （整包 gzip，Content-Encoding: gzip）
→ pending_ownership_receipt + receipt_signature

POST …（pair）
  同上，外加 device_pending_ownership_receipt + device_pending_ownership_receipt_signature
→ final_ownership_receipt
```

凭据的线格式：`{1: 签名, 2: JSON 体}`。
它证明"这台设备被授权成为这副眼镜的主人"，眼镜在 svc36 里用它校验——**但校验的核心是"私钥 + 签名"，凭据只是入场券**。因此：

- 只登录一次、把私钥安全保存，后续连接不需要联网；
- 换手机时带走私钥即可继续做主人（这正是我们提供"导出/导入身份文件"的原因）。

## 4. 与眼镜的绑定（svc36）

```
手机 → 眼镜  0x3000 IDENTITY_REQUEST
眼镜 → 手机  0x3001 IDENTITY_RESPONSE {1: 证书 DER, 2: 序列号, 3: 注册信息, 5: 次级证书}
手机 → 眼镜  0x2000 SKIP_CHALLENGE
手机 → 眼镜  0x2002 START_CHANGE_OWNER {凭据}
眼镜 → 手机  0x2003（部分批次会要求按一次拍摄键）
手机 → 眼镜  0x2004 FINISH_CHANGE_OWNER {最终凭据}
眼镜 → 手机  0x2005 + 状态帧
```

状态码：`0x1000` 成功、`0x1010` 找不到这把钥匙、`0x1040` 凭据无效、`0x1041` nonce 不符、`0x1042` 属于另一个账号、`0x1043` 应用身份不符、`0x1044` 签名不对、`0x1045` 时间偏差过大。

## 5. 密钥是怎么存的

- 私钥用 `KeyPairGenerator("EC")` 生成 **P-256 软件密钥**；
- 再用 AndroidKeyStore 里的一把 AES-256-GCM 密钥把私钥 PEM 加密，文件形如 `VKS1 | 12B IV | 密文`；
- 因此私钥本身是可导出的（我们提供的导出入口就是把它读出来），但**容器只有本机能开**——这是"换手机必须提前导出"的根本原因。

## 6. 云侧还有哪些接口（只记录，不必需）

| 接口 | 用途 |
| --- | --- |
| `ar.graph.meta.com/login` | 用 AR 令牌换 FRLA 会话 |
| `ar.graph.meta.com/app_token_exchange` | 应用令牌交换 |
| `ar-genai.graph.meta.com/graphql` | 镜框款式、语言包、天气等 |
| `meta.graph.meta.com/graphql`、`graph.facebook.com/graphql` | 通用图形查询 |

请求形态：form-urlencoded，字段 `fb_api_req_friendly_name` / `client_doc_id` / `variables` / `method=post` / `locale=en_US` / `format=json`，头 `Authorization: OAuth <令牌>`。

**我们的立场**：客户端在日常使用中不调用这些接口；只有"首次绑定"这一步需要账号令牌。绑定完成后，即使断网、即使厂商服务不可用，拍照、取景、导入、设置、助手全部照常工作。

## 7. 应用身份（为什么有的机型要求"应用已被认可"）

部分固件会检查"发起方是不是被认可的配套应用"（`0x1043`）。
两种通过方式：

1. 用厂商的配套应用完成一次绑定（我们的路径不需要它，只要凭据与私钥一致）；
2. 用该机型对应的应用标识注册（不同机型标识不同，见 `04-device-profiles.md`）。

如果遇到 `0x1043`，先确认私钥与凭据是同一对，再确认注册时带的证书与 `IDENTITY_RESPONSE` 里返回的证书链一致。
