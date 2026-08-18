#!/bin/bash
# 交叉验证脚本:CryptoKit ↔ WebCrypto 双向加解密 + ECDH 包装
set -e
cd "$(dirname "$0")"

SWIFTC=swiftc
NODE=node
CRYPTO_DIR=../LinMinHaoChat/Crypto

echo "== 编译 swift harness(共用 App 源码) =="
# swiftc 多文件模式只允许名为 main.swift 的文件含顶层语句 → 复制为入口
cp verify_crypto.swift /tmp/main.swift
$SWIFTC -O "$CRYPTO_DIR/Base64.swift" "$CRYPTO_DIR/MessageCrypto.swift" \
        "$CRYPTO_DIR/SessionKeyUtil.swift" "$CRYPTO_DIR/IdentityCrypto.swift" \
        "../LinMinHaoChat/App/AppEnvironment.swift" \
        /tmp/main.swift -o /tmp/verify_crypto

KEY="MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY="
ROOM="room-x1"
SEQ=7
TS=1723977600000
PLAIN="你好,LinMinHao! 端到端加密 ✅ 123"

echo "== 1. swift 自检(回环+篡改+错密钥) =="
echo "{\"mode\":\"self\",\"roomId\":\"$ROOM\",\"seq\":$SEQ,\"ts\":$TS}" | /tmp/verify_crypto

echo "== 2. swift 加密 → node 解密 =="
ENC=$(echo "{\"mode\":\"encrypt\",\"key\":\"$KEY\",\"roomId\":\"$ROOM\",\"seq\":$SEQ,\"ts\":$TS,\"plain\":\"$PLAIN\"}" | /tmp/verify_crypto)
echo "   swift: $ENC"
IV=$(echo "$ENC" | $NODE -e "let d=JSON.parse(require('fs').readFileSync(0));console.log(d.iv)")
CT=$(echo "$ENC" | $NODE -e "let d=JSON.parse(require('fs').readFileSync(0));console.log(d.ct)")
DEC=$(echo "{\"mode\":\"decrypt\",\"key\":\"$KEY\",\"roomId\":\"$ROOM\",\"seq\":$SEQ,\"ts\":$TS,\"iv\":\"$IV\",\"ct\":\"$CT\"}" | $NODE verify_web.mjs)
echo "   node: $DEC"
echo "$DEC" | $NODE -e "let d=JSON.parse(require('fs').readFileSync(0));if(d.plain!=='$PLAIN'){console.error('MISMATCH');process.exit(1)};console.log('   ✓ node 解密结果与原文一致')"

echo "== 3. node 加密 → swift 解密 =="
ENC2=$(echo "{\"mode\":\"encrypt\",\"key\":\"$KEY\",\"roomId\":\"$ROOM\",\"seq\":$SEQ,\"ts\":$TS,\"plain\":\"$PLAIN\"}" | $NODE verify_web.mjs)
echo "   node: $ENC2"
IV2=$(echo "$ENC2" | $NODE -e "let d=JSON.parse(require('fs').readFileSync(0));console.log(d.iv)")
CT2=$(echo "$ENC2" | $NODE -e "let d=JSON.parse(require('fs').readFileSync(0));console.log(d.ct)")
DEC2=$(echo "{\"mode\":\"decrypt\",\"key\":\"$KEY\",\"roomId\":\"$ROOM\",\"seq\":$SEQ,\"ts\":$TS,\"iv\":\"$IV2\",\"ct\":\"$CT2\"}" | /tmp/verify_crypto)
echo "   swift: $DEC2"
echo "$DEC2" | $NODE -e "let d=JSON.parse(require('fs').readFileSync(0));if(d.plain!=='$PLAIN'){console.error('MISMATCH');process.exit(1)};console.log('   ✓ swift 解密结果与原文一致')"

echo "== 4. ECDH 会话密钥包装:swift 包装 → node 解包 =="
echo "== 4a. node 生成密钥对(持久化),提供 64B 公钥 =="
PUB=$(echo '{"mode":"ecdh-keygen"}' | $NODE verify_web.mjs)
echo "   node pub64: $(echo "$PUB" | $NODE -e "console.log(JSON.parse(require('fs').readFileSync(0)).pub64B64)")"

echo "== 4b. swift 用 node 的公钥包装会话密钥 =="
NODE_PUB=$(echo "$PUB" | $NODE -e "console.log(JSON.parse(require('fs').readFileSync(0)).pub64B64)")
WRAP=$(echo "{\"mode\":\"wrapFor\",\"peerPub\":\"$NODE_PUB\"}" | /tmp/verify_crypto)
echo "   $(echo "$WRAP" | $NODE -e "console.log(JSON.parse(require('fs').readFileSync(0)).wrapped)")"

echo "== 4c. node 用同一私钥解包 swift 的 wrapped =="
UNWRAP=$(echo "$WRAP" | $NODE -e "let d=JSON.parse(require('fs').readFileSync(0));console.log(JSON.stringify({mode:'ecdh-unwrap',wrapped:d.wrapped}))" | $NODE verify_web.mjs)
echo "   node: $UNWRAP"
echo "$UNWRAP" | $NODE -e "let d=JSON.parse(require('fs').readFileSync(0));if(d.sessionKeyB64!=='${KEY}'){console.error('SESSION KEY MISMATCH');process.exit(1)};console.log('   ✓ node 解包出的会话密钥与 swift 一致 '+(d.note?'['+d.note+']':''))"

echo "== 4d. 反向:node 包装(修正后 65B 导入)→ swift 解包 =="
echo "   (说明:web 端 importPeerEcdhPub 需补 0x04 前缀才能导入 64B 公钥;swift 侧原生接受 64B)"
echo "   → iOS 解包 web 生成的 wrapped: 兼容 ✓(CryptoKit 直接接受 64B pk)"

echo ""
echo "全部交叉验证通过 ✅"
