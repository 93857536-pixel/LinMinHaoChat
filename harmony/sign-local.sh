#!/usr/bin/env bash
# sign-local.sh v2 — LinMinHaoChat HarmonyOS 本地 pki_internal 签名(可复用)
#
# 原理:
#   1. 从 SDK toolchains/lib/OpenHarmony.p12 导出全部证书/私钥
#   2. 用「OpenHarmony Application CA」(子CA) 的私钥, 给「app release」私钥签发一张
#      真正的 10 年应用证书(原始 p12 里的 app release 是自签占位, 拼不出合法链)
#   3. 组 根->子CA->app 证书链(与 SDK 自带 OpenHarmonyProfileRelease.pem 顺序一致)
#   4. hap-sign-tool: sign-profile -> sign-app -> verify-app
#
# 依赖: brew openjdk@17 + openssl + ~/command-line-tools
# 用法: cd harmony && bash sign-local.sh [hap路径]
# 产物: 同名 -signed.hap(放原 hap 同目录, 默认桌面)
set -uo pipefail

JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home}"
export PATH="$JAVA_HOME/bin:$PATH"
LIB="$HOME/command-line-tools/sdk/default/26.0.0/toolchains/lib"
P12="$LIB/OpenHarmony.p12"
HAP_IN="${1:-$HOME/Desktop/LinMinHaoChat-harmony-v1.9.16.hap}"
HAP_OUT="${HAP_IN%.hap}-signed.hap"
KS=123456

W="$(mktemp -d /tmp/hap-sign-v2-XXXXXX)"
cd "$W"
echo "[workdir] $W"

echo "== 1. 导出 p12 全部证书/私钥 =="
openssl pkcs12 -in "$P12" -nokeys -nodes -passin pass:$KS -out all-certs.pem 2>/dev/null
openssl pkcs12 -in "$P12" -nocerts -nodes -passin pass:$KS -out all-keys.pem 2>/dev/null
python3 - <<'EOF'
import re
def blocks(name, b, e):
    d = open(name).read()
    return re.findall(b + r".*?" + e, d, re.S)
certs = blocks("all-certs.pem", r"-----BEGIN CERTIFICATE-----", r"-----END CERTIFICATE-----")
keys  = blocks("all-keys.pem",  r"-----BEGIN (?:EC )?PRIVATE KEY-----", r"-----END (?:EC )?PRIVATE KEY-----")
for i,c in enumerate(certs,1): open(f"c{i}.cer","w").write(c+"\n")
for i,k in enumerate(keys,1):  open(f"k{i}.pem","w").write(k+"\n")
print(f"certs={len(certs)} keys={len(keys)}")
EOF

# 按 subject 定位各角色证书
loc() { for i in c*.cer; do openssl x509 -in "$i" -noout -subject | grep -q "$1" && { echo "$i"; return; }; done; echo ""; }
ROOT=$(loc "CN=OpenHarmony Application Root CA$")
SUBCA=$(loc "CN=OpenHarmony Application CA$")
APPPLACEHOLDER=$(loc "CN=OpenHarmony Application Release$")
PROFILE=$(loc "CN=OpenHarmony Application Profile Release$")
echo "ROOT=$ROOT SUBCA=$SUBCA APPPLACEHOLDER=$APPPLACEHOLDER PROFILE=$PROFILE"
[ -z "$ROOT" -o -z "$SUBCA" -o -z "$APPPLACEHOLDER" ] && { echo "[失败] 缺角色证书"; exit 1; }

# 找与证书公钥匹配的私钥
key_for_cert() {
  local h; h=$(openssl x509 -in "$1" -noout -pubkey | shasum -a 256 | cut -c1-16)
  for i in k*.pem; do
    local kh; kh=$(openssl pkey -in "$i" -pubout 2>/dev/null | shasum -a 256 | cut -c1-16)
    [ "$h" = "$kh" ] && { echo "$i"; return; }
  done
  echo ""
}
SUBCA_KEY=$(key_for_cert "$SUBCA")
APP_KEY=$(key_for_cert "$APPPLACEHOLDER")
echo "SUBCA_KEY=$SUBCA_KEY APP_KEY=$APP_KEY"
[ -z "$SUBCA_KEY" -o -z "$APP_KEY" ] && { echo "[失败] 缺私钥"; exit 1; }

echo "== 2. 子CA 给 app 私钥签发 10 年应用证书 =="
cat > appext.cnf <<'EOF'
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
EOF
openssl req -new -key "$APP_KEY" -subj "/C=CN/O=OpenHarmony/OU=OpenHarmony Team/CN=OpenHarmony Application Release" -out app.csr
openssl x509 -req -in app.csr -CA "$SUBCA" -CAkey "$SUBCA_KEY" -CAcreateserial -out app.cer -days 3650 -sha256 -extfile appext.cnf
openssl x509 -in app.cer -noout -subject -issuer 2>/dev/null
openssl verify -CAfile <(cat "$ROOT" "$SUBCA") app.cer

echo "== 3. 组 app 链(根->子CA->app) =="
cat "$ROOT" "$SUBCA" app.cer > app-chain.cer
echo "chain certs: $(grep -c 'BEGIN CERT' app-chain.cer)"

echo "== 4. sign-profile(distribution-certificate = app.cer) =="
python3 - <<'EOF'
import json
p = json.load(open("profile.json")) if __import__("os").path.exists("profile.json") else None
if p is None:
    import uuid, time
    now = int(time.time())
    p = {"version-name":"2.0.0","version-code":2,"app-distribution-type":"public_hap",
         "uuid":str(uuid.uuid4()),"validity":{"not-before":now-86400,"not-after":now+3650*86400},
         "type":"release","bundle-info":{"developer-id":"OpenHarmony","distribution-certificate":"",
         "bundle-name":"com.linminhao.chat","apl":"normal","app-feature":"hos_normal_app"},
         "acls":{"allowed-acls":[]},"permissions":{"restricted-permissions":[]},"issuer":"pki_internal"}
p["bundle-info"]["distribution-certificate"] = open("app.cer").read()
open("profile.json","w").write(json.dumps(p, indent=2))
print("profile.json ok")
EOF
java -jar "$LIB/hap-sign-tool.jar" sign-profile -mode localSign \
  -keyAlias "openharmony application profile release" -keyPwd "$KS" \
  -profileCertFile "$LIB/OpenHarmonyProfileRelease.pem" \
  -inFile profile.json -signAlg SHA256withECDSA \
  -keystoreFile "$P12" -keystorePwd "$KS" \
  -outFile signed-profile.p7b 2>&1 | tail -2

echo "== 5. sign-app(appCertFile = 根->子CA->app 链) =="
java -jar "$LIB/hap-sign-tool.jar" sign-app -mode localSign \
  -keyAlias "openharmony application release" -keyPwd "$KS" \
  -appCertFile app-chain.cer \
  -profileFile signed-profile.p7b \
  -inFile "$HAP_IN" -signAlg SHA256withECDSA \
  -keystoreFile "$P12" -keystorePwd "$KS" \
  -outFile "$HAP_OUT" -compatibleVersion 12 -signCode 1 -permSign 1 2>&1 | tail -5

if [ -f "$HAP_OUT" ]; then
  echo "== 6. verify-app =="
  java -jar "$LIB/hap-sign-tool.jar" verify-app -inFile "$HAP_OUT" -outCertChain v-chain.cer -outProfile v-profile.p7b 2>&1 | tail -3
  echo "== 包内签名条目 =="
  unzip -l "$HAP_OUT" | grep -iE "cert|profile|META"
  echo ""
  echo "================ 完成 ================"
  echo "输入:  $HAP_IN"
  echo "输出:  $HAP_OUT ($(stat -f%z "$HAP_OUT") bytes)"
  echo "SHA256: $(shasum -a 256 "$HAP_OUT" | cut -d' ' -f1)"
else
  echo "[失败] sign-app 未产出 $HAP_OUT"
  exit 1
fi
