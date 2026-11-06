#!/bin/sh
set -u
export PNPM_HOME="$HOME/.dsh/pnpm-global"
P=$(ls -d "$PNPM_HOME"/store/v11/links/@/node-addon-require-builtin-darwin-arm64/*/*/node_modules/node-addon-require-builtin-darwin-arm64 2>/dev/null | head -1)
RT="$HOME/.dsh/dsh-runtimes/dsh-primary-runtime/dependencies"

echo "== nvm versions =="
ls -1 "$HOME/.nvm/versions/node" 2>/dev/null || echo "no nvm"

echo
echo "== codesign: bundled node =="
codesign -dv --verbose=2 "$RT/node/bin/node" 2>&1 | grep -E 'TeamIdentifier|Authority|Identifier|flags' | head -6

echo "== codesign: the .node =="
codesign -dv --verbose=2 "$P/prebuilt/darwin-arm64-napi-v9.node" 2>&1 | grep -E 'TeamIdentifier|Authority|Identifier|flags' | head -6

echo
echo "== try loading with nvm node v20.20.2 =="
N20="$HOME/.nvm/versions/node/v20.20.2/bin/node"
if [ -x "$N20" ]; then
  "$N20" -e "require('$P/prebuilt/darwin-arm64-napi-v9.node'); console.log('NODE20 LOAD ok')" 2>&1 | head -4
else
  echo "v20.20.2 missing"
fi

echo
echo "== quarantine attributes =="
xattr -l "$P/prebuilt/darwin-arm64-napi-v9.node" 2>&1 | head -5 || echo "no xattrs"
