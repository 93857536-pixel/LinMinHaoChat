# 产品定位(Product Direction)

> 本文件是 LinMinHao Chat 的产品方向总纲,自 2026-08-18 起生效。
> 产品定位变更:**原生 iOS App 是正式用户客户端,Web 前端降级为测试/兼容客户端。**

## 一、正式产品结构

```
iOS 原生 App(用户主要客户端)
    ↓ HTTPS API / WSS
linminhao.top 后端(基础设施)
    ↓
E2EE 密文存储
```

- **iOS App** = 用户主要使用的客户端
- **linminhao.top** = 后端基础设施:API、WebSocket、数据存储、必要的管理服务
- 服务器永远只持有密文;私钥在用户设备 Keychain,服务器无万能密钥

## 二、Web 前端处理

现有 Web 前端**不删除**,保留作为:

- 开发测试客户端
- E2EE 协议测试客户端
- 后端 API 测试工具
- iOS 发布前兼容性测试工具

但 Web **不再作为正式用户客户端**:

- 不为 Web 用户体验削弱 iOS App 的安全设计
- 不在 Web 上优先开发新功能

## 三、iOS App 为第一优先级

新功能开发顺序:**优先 iOS App**。所有新功能必须考虑:

- SwiftUI
- CryptoKit(或合适的密码学库)
- Keychain
- 原生 iOS 生命周期
- iOS 隐私保护

不做「先 Web 后简单移植 iOS」的路线。

## 四、原生 App 强制隐私模式

隐私模式:

- 永久开启
- 没有关闭按钮
- 没有设置开关
- 没有隐藏 API
- 没有普通用户可使用的关闭方式

聊天界面**不显示水印**。

## 五、后端地址

后端继续使用 **linminhao.top**,但用户不需要在浏览器输入该网址。

App 内部自动连接:

- API:`https://linminhao.top/api/…`
- WebSocket:`wss://linminhao.top/…`

(具体路径按实际项目决定,当前实现见 [API.md](API.md))。

## 六、目标用户体验

用户安装 App → 打开 → 看到「LinMinHao Chat」→ 登录/注册 或 临时聊天。

聊天全程不需要打开浏览器。

## 七、App Store 产品方向

按真正的 iOS App 产品开发,考虑:

- App Icon
- Launch Screen
- Bundle Identifier
- Signing
- Capabilities
- Push Notifications
- Keychain
- Face ID
- App Store 隐私说明
- TestFlight

发布 App Store 后,不依赖网页作为主要用户入口。

## 八、Push Notification(后续)

接入 APNs,但**推送不得泄露 E2EE 消息明文**:

- 锁屏通知不显示敏感聊天内容
- 示例格式:「LinMinHao Chat:收到一条新消息」(而非「张三:今晚……」)
- 具体实现按 E2EE 与用户隐私需求设计(如推送仅携带房间元数据 + 本地解密提示)

## 九、数据架构(保持不变)

服务器继续保存加密后的聊天密文;服务器**不能获得**:

- 用户私钥
- 聊天明文
- 万能解密密钥

iOS 端:

- 私钥 → Keychain
- 消息:服务器密文 → App 下载 → 本地解密 → 显示

## 十、最终目标

最终用户体验:

```
安装 LinMinHao Chat iOS App → 注册/登录 → 开始聊天
或
安装 App → 临时聊天 → 分享临时聊天邀请 → 双方 App 加入 → E2EE 通讯
```

用户**不需要知道**:服务器 IP、API、WebSocket、数据库、聊天文件目录、linminhao.top。
这些全部由 App 后台处理。

---

## 变更记录

| 日期 | 内容 |
|------|------|
| 2026-08-18 | 确立产品定位:iOS 原生 App 为正式客户端;Web 保留为测试/兼容客户端;linminhao.top 为纯后端基础设施 |
