#!/bin/bash
set -e
WORK=/tmp/whalefloat-cert
rm -rf "$WORK" && mkdir -p "$WORK" && cd "$WORK"

PASS=whalefloat
NAME="WhaleFloat Dev"
KC="$HOME/Library/Keychains/login.keychain-db"

echo "1/6 清理旧证书"
security delete-certificate -c "$NAME" "$KC" >/dev/null 2>&1 || true

echo "2/6 生成证书（带 Code Signing 扩展）"
openssl req -x509 -newkey rsa:2048 -keyout k.pem -out c.pem \
  -days 3650 -nodes -subj "/CN=$NAME" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" \
  -addext "basicConstraints=critical,CA:false" 2>/dev/null

echo "3/6 确认扩展已写入"
openssl x509 -in c.pem -noout -text | grep -A 1 "Extended Key Usage" | tail -2

echo "4/6 打包 p12 并导入"
openssl pkcs12 -export -out c.p12 -inkey k.pem -in c.pem -passout "pass:$PASS" 2>/dev/null
security import c.p12 -k "$KC" -P "$PASS" -T /usr/bin/codesign -A

echo "5/6 信任证书"
security add-trusted-cert -r trustRoot -k "$KC" c.pem

echo "6/6 验证"
security find-identity -v -p codesigning
