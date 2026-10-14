#!/bin/zsh
# 编出「<BRAND>.app」（Mac 用户版菜单栏程序：没有「用户」管理页，多了使用说明 / 立即更新 / 卸载），
# 通用二进制（Apple 芯片 + Intel），用钥匙串里的 Developer ID 签名，打成 zip 经服务器推到订阅服务的下载区
# （<SUB_BASE>/dl/<小写 APP_ID>-mac.zip）。用户的安装命令从那里下载。BRAND / APP_ID 见 lib/defaults.env。
#
#   client/macos/build-user-app.sh [--no-upload]
#
# 不需要公证：用户用 curl 下载，文件没有「来自网络」的隔离标记，Gatekeeper 不检查。
set -euo pipefail
REPO=${0:A:h:h:h}; source $REPO/lib/site.sh
UPLOAD=1; [[ ${1:-} == --no-upload ]] && UPLOAD=0
ID=${(L)APP_ID}
D="/Library/Application Support/$APP_ID"
VERSION=$(git -C $REPO log -1 --format=%cd --date=format:%Y.%m.%d.%H%M)
T=$(mktemp -d); trap 'rm -rf $T' EXIT
APP="$T/$BRAND.app"
say() { print -P "%F{cyan}==%f $*"; }

cat > $T/Site.swift <<EOF
import Foundation
let label = "com.$ID.vpn"
let configPath = "$D/config.json"
let serverIP = "$SERVER_V4"
let serverSSH = ""
let serverRepo = ""
let userEdition = true
let secretPath = "$D/clash.secret"
let helpPath = "$D/help.txt"
let uninstallPath = "$D/uninstall.sh"
let expiredPath = "$D/expired"
let clashAddr = "127.0.0.1:19090"   // make-config.py USER_EDITION
let brand = "$BRAND"
let exitName = "$EXIT_NAME"
let errLogPath = "$D/sing-box.log"
let menubarLabel = "com.$ID.menubar"
EOF

say "编译（arm64 + x86_64）"
for arch in arm64 x86_64; do
  swiftc -O -target $arch-apple-macos13 -o $T/$APP_ID-$arch $REPO/client/macos/menubar/*.swift $T/Site.swift \
    -framework AppKit -framework Network -framework SwiftUI 2>&1 | grep -v "warning:\|DeprecatedDeclaration\|^ *|\|^\s*$\|^\[#" || true
  [[ -x $T/$APP_ID-$arch ]] || { echo "❌ $arch 编译失败"; exit 1; }
done
mkdir -p "$APP/Contents/MacOS"
lipo -create -output "$APP/Contents/MacOS/$APP_ID" $T/$APP_ID-arm64 $T/$APP_ID-x86_64
/usr/bin/python3 - "$APP/Contents/Info.plist" "$VERSION" "$BRAND" "$APP_ID" <<'PY'
import plistlib, sys
out, ver, brand, app_id = sys.argv[1:]
plistlib.dump({"CFBundleIdentifier": f"com.{app_id.lower()}.menubar", "CFBundleName": brand, "CFBundleDisplayName": brand,
               "CFBundleExecutable": app_id, "CFBundlePackageType": "APPL", "CFBundleShortVersionString": ver,
               "CFBundleVersion": ver, "LSUIElement": True, "LSMinimumSystemVersion": "13.0",
               "NSHumanReadableCopyright": brand}, open(out, "wb"))
PY

SIGN_ID=${JPX_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"')}
[[ -n $SIGN_ID ]] || { echo "❌ 钥匙串里没有 Developer ID Application 证书"; exit 1; }
codesign --force --options runtime --timestamp -s "$SIGN_ID" "$APP"
codesign --verify --strict "$APP"
say "已签名：$SIGN_ID（版本 $VERSION）"

OUT=$REPO/client/macos/.build; mkdir -p $OUT
ditto -c -k --keepParent "$APP" $OUT/$ID-mac.zip
say "打包：$OUT/$ID-mac.zip（$(du -h $OUT/$ID-mac.zip | cut -f1)）"
if (( UPLOAD )); then
  scp -q $OUT/$ID-mac.zip $SERVER_SSH:/tmp/$ID-mac.zip
  ssh $SERVER_SSH "/usr/bin/python3 $SERVER_REPO/server/sub.py upload $ID-mac.zip /tmp/$ID-mac.zip $VERSION && rm -f /tmp/$ID-mac.zip"
fi
