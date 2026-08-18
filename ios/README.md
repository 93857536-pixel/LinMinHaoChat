# LinMinHao Chat · iOS 原生客户端

**正式用户客户端(产品定位 2026-08-18 起生效)**。SwiftUI + CryptoKit + Keychain,零第三方依赖。

## 目录结构

```
project.yml             xcodegen 工程定义(唯一工程源,不提交 .xcodeproj)
LinMinHaoChat/
  LinMinHaoChatApp.swift    入口 + 后台隐私模糊(scenePhase)
  App/AppEnvironment.swift  后端地址(linminhao.top,App 自动连接,用户不可见)
  App/PrivacyMode.swift     强制隐私模式(永久开启,无水印,无关闭开关)
  App/AppState.swift        全局状态(登录态存 Keychain)
  Crypto/                   与 web/src/crypto 协议字节级兼容
    Base64.swift            base64 / base64url
    MessageCrypto.swift     HKDF-SHA256 + AES-GCM-256, AAD=roomId:seq:ts
    SessionKeyUtil.swift    临时聊天会话密钥 + 分享链接 #k=
    IdentityCrypto.swift    ECDH P-256 + Ed25519 + 会话密钥包装 + PBKDF2 导出包
  Keychain/                 Keychain 存取(私钥/令牌)
  Networking/               APIClient(https://linminhao.top/api)+ WebSocketClient
  Models/                   TempMsg / ChatMsg / DecryptedMsg / 访客标签
  ViewModels/               TempChatViewModel(临时聊天全链路)
  Views/                    Home / TempRoom / Chat / Login / Settings / 隐私模糊层
  Assets.xcassets/          AppIcon(脚本生成)+ AccentColor
scripts/make_icon.swift     AppKit 图标生成(无 Pillow 依赖)
verify/                     CryptoKit ↔ WebCrypto 协议交叉验证
```

## 构建

```bash
cd ios
xcodegen generate
xcodebuild -project LinMinHaoChat.xcodeproj -scheme LinMinHaoChat \
  -destination 'generic/platform=iOS Simulator' build   # 免签名
```

真机调试:project.yml 去掉 `CODE_SIGN_IDENTITY` / `CODE_SIGNING_REQUIRED` 两行,填 `DEVELOPMENT_TEAM`。

## 协议验证

`verify/run_verify.sh` 用与 App 相同的源码编译 CLI harness,与 node WebCrypto 交叉验证:

1. swift 自检(回环 + 篡改拒绝 + 错密钥拒绝)
2. swift 加密 → node 解密(证明与 web 端消息协议字节级兼容)
3. node 加密 → swift 解密
4. ECDH 会话密钥包装:swift 包装 → node 解包(同一密钥对)

## 已确认的 web 端协议问题(2026-08-18 交叉验证发现)

- **web `importPeerEcdhPub` 导入 64B raw P-256 公钥会被浏览器拒绝**(WebCrypto 规范要求 65B 带 0x04 前缀;node/OpenSSL 实测拒绝)。iOS CryptoKit 原生接受 64B → iOS 解包 web wrapped 兼容;web 端需补前缀(待修)。
- web 附件上传未前置 iv(decryptAttachment 假设 iv||body 但 encryptAttachment 输出裸 ct||tag)——疑似 web 附件解密 bug(待查)。iOS 附件用自描述 iv||ct||tag 格式。
