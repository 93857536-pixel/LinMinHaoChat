# Android 端规格(APK)· LinMinHaoChat 功能对等版

> 本文件是**唯一权威规格**。委派子代理时只传「先完整读本文件」+ 顶层约束,不要内联复述。
> 版本基准:iOS v1.9.13(build 13,`com.linminhao.chat`)。目标:Android 12+(minSdk 31)。

---

## 0. 目标

产出一个**可直接安装的 Android APK**,功能与 iOS v1.9.13 **完全对等**,并且能与现有 iOS 用户 / Web 用户**互通**(同账号跨端收发消息)。

---

## 1. 铁律(违反即返工)

1. **服务端 `server/` 一个字节都不许改**。后端是共享的,Android 只是新客户端。所有能力都必须用现有 API 实现;若发现缺接口 → 记入汇报的「阻塞清单」,不要自己加路由。
2. **`ios/` 一个字节都不许改**。
3. **`web/src/crypto/**` 是只读锚点,禁止修改**。E2EE 协议必须与 iOS/Web 字节级一致,改一个参数就会让 Android 用户被孤立(收不到别人的消息)。
4. **`web/src/{api.ts,ws.ts,auth.tsx}` 只允许"加法"扩展**(新增文件,或在文件末尾追加导出),**不得改动既有导出函数的语义/签名**——现有 Web 端必须继续正常工作。
5. **新代码只进这两个目录**:`web/src/features/**`(业务功能)、`web/src/mobile/**`(移动端壳/原生桥)。其他目录视为锚点。
6. **不许假装成功**:没跑过的命令不许写"通过";构建失败就把编译器原文贴进汇报。修错上限 **6 轮**,超限停下写 `build-notes.md` 汇报。
7. **不得引入需要联网下载的运行时依赖**;npm 依赖只允许在当前 `web/package.json` 声明的范围内 + Capacitor 官方包。

---

## 2. 架构定案(不要重新讨论)

```
Capacitor 6 (Android WebView 壳) + Vite + React 18(复用 web/ 现有代码)
                     │
       ┌─────────────┴─────────────┐
   web/src/crypto/**           web/src/api.ts + ws.ts
   (E2EE, 原样复用)            (REST/WS, 加法扩展)
                     │
              web/src/features/**   ← 本次要写的新功能
```

**为什么用 WebView 而不是 Kotlin 原生**:E2EE 走 WebCrypto(`subtle`),Android WebView 原生支持;复用同一份 `crypto/` 代码 = 互操作性天然成立。用 Kotlin 重写密码学 = 协议漂移风险(RSA/ECDH 参数、HKDF info、AAD 拼法)极高,不可接受。

---

## 3. 必读契约(动手前先读完)

| 文件 | 作用 |
|---|---|
| `web/src/crypto/keys.ts` | 身份密钥:Ed25519(签名)+ **ECDH P-256**(交换);JWK 存 IndexedDB `lmh-keys`;对端公钥线格式 = **64B x‖y 的 raw base64**(导入时需补 `0x04`) |
| `web/src/crypto/session.ts` | 会话密钥包装:ECDH→HKDF-SHA256(`info='lmh-session-wrap-v1'`, salt 空)→AES-256-GCM;wrapped = JSON `{v:1,iv,ct,pk}` |
| `web/src/crypto/message.ts` | 消息/附件加密:HKDF salt=iv,`info='lmh-msg-v1:<roomId>:<seq>'` / `'lmh-att-v1:<roomId>:<ts>'`;AAD=`<roomId>:<seq>:<ts>` / `<roomId>:<ts>`;附件输出 = `iv(12B)‖ct` |
| `web/src/api.ts` | 现有 REST 封装(auth/keys/temp/invite/chat/attachments/admin) |
| `web/src/ws.ts` | WebSocket 协议(join/收发/已读) |
| `web/src/pages/Chat.tsx` | **账号聊天的参考实现**(消息收发、附件加解密全链路)——新功能要与它风格一致 |
| `server/src/routes/{friends,avatars,realname,chat,attachments}.ts` | 端点契约(响应字段名必须逐字对齐) |
| `ios/LinMinHaoChat/Views/ChatView.swift` | 语音实现参考:`{"f":{"attId":..,"name":"voice.m4a","size":N,"mime":"audio/aac","duration":<ms>}}` |

---

## 4. API 全集(已核对,可直接用)

```
POST /api/auth/send-code            {type:'sms'|'email', target}                    → {ok, expiresInSec}
POST /api/auth/register             {type,target,code,handle?,deviceId?,ed25519Pub?,ecdhPub?} → {ok,token,sessionId,user}
POST /api/auth/login                同上                                              → {ok,token,sessionId,user}
POST /api/auth/logout               {sessionId}

POST /api/keys/register             {ed25519Pub,ecdhPub,deviceId}
POST /api/keys/export-package       {pkg,deviceId}
GET  /api/keys/export-package?deviceId=                                             → {ok,pkg|null}
GET  /api/keys/public/:userId                                                       → {ok,devices:[{device_id,ed25519_pub,ecdh_pub}]}
GET  /api/keys/my                                                                   → (本设备密钥状态)
GET  /api/keys/lookup?q=                                                            → {ok,user:{id,handle}}   ← 加好友前查账号

GET  /api/chat/rooms                                                                → {ok,rooms:RoomMeta[]}
POST /api/chat/rooms                {type:'dm'|'group',memberIds:[],nameEnc?,wrappedKeys:[{userId,deviceId,wrappedKey}]} → {ok,room}
GET  /api/chat/rooms/:id                                                            → {ok,room}
GET  /api/chat/rooms/:id/keys?deviceId=                                             → {ok,keys:string[]}
POST /api/chat/rooms/:id/keys        {userId,deviceId,wrappedKey}
POST /api/chat/rooms/:id/add-member  {userId}
GET  /api/chat/rooms/:id/members                                                    → {ok,members:[{userId,handle,nickname,hasAvatar?,avatarUpdatedAt?,role?}]}
DEL  /api/chat/rooms/:id/members/:userId
POST /api/chat/rooms/:id/messages    {iv,cipher,kind:'msg'|'attachment',meta?,seq,ts} → {ok,seq,id,ts}
GET  /api/chat/rooms/:id/messages?afterSeq=&limit=                                   → {ok,messages:ChatMsg[],hasMore}
POST /api/chat/rooms/:id/read        {lastSeq}
GET  /api/chat/rooms/:id/online                                                     → {ok,online:number[]}
POST /api/chat/rooms/:id/forward                                                    ← 转发
POST /api/chat/rooms/:id/leave
POST   /api/chat/messages/:msgId/star                                               ← 收藏
DELETE /api/chat/messages/:msgId/star
GET  /api/chat/starred                                                             → 收藏列表

POST /api/attachments?roomId=&declaredMime=   (body=密文原始字节)                    → {ok,attId,size,roomId}
GET  /api/attachments/:id                                                           → 密文字节(octet-stream)

POST /api/avatars                   (body=图片原始字节,≤2MB,jpeg/png/webp)          → {ok,hasAvatar,avatarUpdatedAt,size}
GET  /api/avatars/:userId           (:userId 可为 'me')                             → 图片字节(任何已登录用户可见)
DELETE /api/avatars

GET  /api/friends                                                                   → {ok,friends:[{userId,handle,nickname,hasAvatar,avatarUpdatedAt,...}]}
GET  /api/friends/search?query=                                                      → {ok,users:[{userId,handle,nickname,hasAvatar,avatarUpdatedAt}]}
POST /api/friends                   {handle|userId,...}                             → 发起/接受好友请求
DELETE /api/friends/:userId

GET  /api/realname/status                                                           → 实名状态
POST /api/realname/verify           {name,idcard}                                   → 已认证再提交必返 **409 {error:'already_verified'}**

POST /api/pns/phone-check           {spToken}                                       → 一键登录换号(Android 可用阿里云 Dypns SDK;可后置)
```

---

## 5. 功能对等清单(验收基准)

| # | 功能 | iOS 位置 | Web 现状 | 本次要做 |
|---|---|---|---|---|
| 1 | 四 Tab 壳(聊天/通讯录/发现/我的) | RootView | ✗ | ✅ 移动壳 |
| 2 | 邮箱验证码登录/注册 | LoginView | ✅ 有 | 复用 |
| 3 | 手机一键登录 | PNSAuthManager | ✗ | ⚠️ 可后置(需阿里云 Android SDK) |
| 4 | 账号聊天(文字, E2EE) | ChatView | ✅ 有 | 复用+移动化 |
| 5 | 图片附件(加密) | ChatView | ✅ 有 | 复用 |
| 6 | **语音消息**(录/播/时长) | ChatView | ✗ | ✅ **必须 m4a/AAC** |
| 7 | 已读回执 | ChatView | ✅ 有 | 复用 |
| 8 | 长按菜单(复制/删除单条) | ChatView | ✗ | ✅ |
| 9 | **转发消息** | ChatView | ✗ | ✅ `/chat/rooms/:id/forward` |
| 10 | **收藏/星标** | StarredListView | ✗ | ✅ `/chat/starred` |
| 11 | 好友:搜索/添加/删除 | FindFriendsSheet | ✗ | ✅ |
| 12 | 通讯录列表(头像+昵称) | ContactsTab | ✗ | ✅ |
| 13 | 发起私聊 | NewDMSheet | ✗ | ✅ |
| 14 | **群聊 + 成员管理** | MemberManageView | 部分(API 有) | ✅ |
| 15 | 头像上传/更换/移除 | MeTab | ✗ | ✅ |
| 16 | 实名认证(一次性,只读) | RealNameView | ✗ | ✅ **已认证必须只读,无重核** |
| 17 | 昵称/账号 ID 展示与修改 | MeTab | ✗ | ✅ |
| 18 | **全 App 仅一处退出登录**(我的→账号与安全) | MeTab | ✗ | ✅ 铁律 |
| 19 | 隐私模式(切后台模糊) | PrivacyMode | ✗ | ✅ |
| 20 | 临时聊天 / 邀请聊天 | TempChatView | ✅ 有 | 移动化 |
| 21 | 深链(lmhchat:// 与网页链接) | RootView | ✗ | ⚠️ 可选 |

---

## 6. 目录树与文件归属(谁写谁)

> ⚠️ 标 `[主]` 的已由主会话落盘,**代理只读、禁止修改**(改了会与其他代理冲突)。

```
web/
├── capacitor.config.ts                 [主] 已落盘(appId=com.linminhao.chat, androidScheme=https)
├── android/**                          [主] Capacitor 原生工程(minSdk 31 / compileSdk 35 / targetSdk 34)
└── src/
    ├── main.tsx                        [主] 已改:检测原生壳 → 注入绝对基址 → 动态加载 MobileApp
    ├── api.ts / ws.ts                  [主] 已加"运行时基址覆盖"机制,不得再动
    ├── crypto/**                       [只读锚点] 禁止修改
    ├── styles.css / pages/**           [只读锚点] 禁止修改(复用)
    ├── mobile/                         [主] MobileApp / PrivacyGate / mobile.css / native.ts
    └── features/
        ├── api-ext.ts                  [主·只读契约] 全部新端点的唯一出处,**代理禁止修改**
        ├── shell/DiscoverScreen.tsx    [主]
        ├── chat/ChatsScreen.tsx        [主]
        ├── contacts/**                 [代理C] ← 本次交付
        ├── me/**                       [代理D] ← 本次交付
        └── chat/{StarredScreen,VoiceRecorder,ForwardDialog,MemberManageScreen,MessageActionSheet}.tsx + forward.ts  [代理E] ← 本次交付
```

**样式规则**:统一用 `mobile/mobile.css` 里已有的原子类(`mv-page / mv-card / mv-row / mv-btn / mv-avatar / mv-input / mv-hint / mv-error / mv-navbar`)。需要新样式时,**追加到 `mobile/mobile.css` 末尾**(每个代理用自己独立的注释块包裹,如 `/* ==== contacts ==== */`),不要改既有规则。

---

## 6.5 已落盘契约(动手前必读,不要重复实现)

1. **`web/src/features/api-ext.ts`** —— 所有新端点的唯一出处,已导出:
   - `meApi.me(token)` / `meApi.setNickname(nickname, token)`
   - `avatarExt.upload(bytes, mime, token)` / `.download(userId|'me', token)` / `.remove(token)`
   - `friendsExt.list/search/add/remove`
   - `realnameExt.status/verify`
   - `membersExt.list/remove/add/leave`
   - `msgExt.forward/star/unstar/starred`
   - 工具:`avatarUrl(userId, updatedAt, token) -> Promise<string|null>`(自动带缓存)、`initialOf(name)`
   - 全部类型:`MeUser / FriendEntry / SearchUser / RealnameStatus / RoomMember / StarredItem`
2. **基址机制**:移动端由 `main.tsx` 注入 `__LMH_API_BASE__` / `__LMH_WS_BASE__`;**新代码要发请求必须走 api-ext.ts 或既有 `api.ts`,不要自己写 `fetch` 拼路径**。
3. **复用既有能力**(不要重写):
   - 加解密:`crypto/message.ts`(`encryptMessage/decryptMessage/encryptAttachment/decryptAttachment/decodeMessageBody/encodeMessageBody`)
   - 会话密钥:`crypto/session.ts`(`wrapSessionKey/unwrapSessionKey/generateSessionKey`)
   - 已有会话/消息 API:`api.ts` 的 `chatApi`(`rooms/keys/send/history/read/online/createRoom`)
   - 认证与登出:`useAuth()`(来自 `auth.tsx`)→ `{ session, identity, login, logout, refreshIdentity }`
   - 注意:`session` 里**没有 nickname/头像**,要显示需自己调 `meApi.me(token)`

---

## 7. 构建命令(逐字照抄)

```bash
export JAVA_HOME=/opt/homebrew/opt/openjdk@17
export ANDROID_HOME="$HOME/Library/Android/sdk"
export PATH="$JAVA_HOME/bin:$ANDROID_HOME/platform-tools:$PATH"

cd web
npm install                     # 首次
npx vite build                  # 必须成功(这是 Web 端的自检)
npx cap sync android            # 把 dist 同步进原生工程
cd android && ./gradlew assembleDebug     # 产物:app/build/outputs/apk/debug/app-debug.apk
```

---

## 8. 验收标准

1. `npx vite build` 退出码 0(现有 Web 端不回归)
2. `./gradlew assembleDebug` 退出码 0,产出 `app-debug.apk`
3. `aapt2 dump badging app-debug.apk` 显示 `package: name='com.linminhao.chat'`、`sdkVersion:'31'`
4. **E2EE 互通测试**(主会话做):本机起抛弃式服务端 → 用 Node 侧 `crypto/` 逻辑建房间发消息 → 断言密文能被标准 WebCrypto 解回原文(证明协议未漂移)
5. 每个功能的 UI 必须在 Android 12 模拟器/真机上可见(截图为证)

## 9. 汇报格式(每个子代理必须照此交)

```
## 交付
- 新增/修改文件: <逐个绝对路径 + 行数>
- 自检命令与原文输出: <npx vite build 的尾部 10 行 / tsc 输出>
- 未验证项(诚实标注): <例如"录音功能未在真机验证,仅静态检查">
- 阻塞清单: <缺失的 API / 需要主会话决策的点>
- 已知风险: <一行一条>
```
