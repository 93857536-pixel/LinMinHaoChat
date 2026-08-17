export default function About() {
  return (
    <div className="about">
      <h1>关于端到端加密</h1>
      <p>
        <strong>LinMinHao Chat</strong> 是一个端到端加密(E2EE)通讯服务。
        你的消息在<strong>发送前会在你的设备上加密</strong>,服务器只保存加密后的数据(密文)。
        即使服务器被入侵、管理员查看数据库,也看不到任何聊天内容。
      </p>

      <h2>加密原理</h2>
      <ul>
        <li><strong>身份密钥</strong>:每个设备生成一对 Ed25519 签名密钥和一对 ECDH P-256 密钥,私钥只保存在浏览器本地(IndexedDB),公钥上传服务器。</li>
        <li><strong>会话密钥</strong>:每个聊天会话使用独立的 256 位随机会话密钥。创建会话时,用成员公钥通过 ECDH 密钥交换加密包装后,经服务器分发给成员。</li>
        <li><strong>消息加密</strong>:每条消息使用 AES-256-GCM 认证加密,密钥由会话密钥 + HKDF 派生,每条消息独立随机 IV(nonce),附加认证数据(AAD)绑定会话、序号与时间戳,任何篡改都会被客户端立刻发现。</li>
      </ul>

      <h2>服务器保存什么</h2>
      <ul>
        <li>加密后的消息(密文文件,按日期归档)</li>
        <li>必要元数据:时间、会话 ID、消息序号、已读状态</li>
        <li>用户账号信息(脱敏后的手机号 / 邮箱)</li>
      </ul>
      <p>服务器<strong>永远不保存</strong>:消息明文、你的私钥、任何万能解密密钥。</p>

      <h2>临时聊天如何工作</h2>
      <ul>
        <li>创建者生成一个临时房间和随机会话密钥。</li>
        <li>会话密钥放在分享链接的 <code>#</code> 片段中(例如 <code>/t/abc123#k=xxxx</code>)。URL 片段<strong>不会发送给服务器</strong>,因此服务器看不到密钥。</li>
        <li>你把链接发给对方,对方打开链接即获得密钥,双方开始加密对话。</li>
        <li>刷新页面 = 本地密钥立即销毁,界面清空;但服务器上的密文归档继续保留(符合「客户端临时,服务器加密归档」设计)。</li>
      </ul>

      <h2>多设备与密钥迁移</h2>
      <p>
        在「设置」中可以把你的身份密钥打包成<strong>口令加密的导出包</strong>(PBKDF2 + AES-256-GCM)。
        新设备输入相同口令即可恢复身份。服务器只中转加密包,无法解密。
      </p>

      <h2>技术栈</h2>
      <ul>
        <li>前端:React + TypeScript + Web Crypto API</li>
        <li>后端:Node.js + Express + WebSocket</li>
        <li>存储:SQLite(索引/元数据)+ 文件系统(密文)</li>
        <li>传输:HTTPS / WSS(TLS 1.2+),HSTS 强制</li>
      </ul>
    </div>
  );
}
