#!/bin/sh
set -u

echo "== 1. dsh executables on PATH / known locations =="
for c in "$HOME/.dsh/pnpm-global/bin/dsh" \
         /usr/local/bin/dsh \
         /opt/homebrew/bin/dsh \
         "$HOME/.npm-global/bin/dsh"
do
  if [ -x "$c" ]; then
    echo "FOUND $c"
  fi
done
command -v dsh 2>/dev/null && echo "PATH dsh -> $(command -v dsh)" || echo "PATH: no dsh (login shell)"

echo
echo "== 2. every @deepseek-ai/dsh package.json on disk =="
for root in "$HOME/.dsh" "$HOME/dsh-plugins" "$HOME/.nvm" \
            /usr/local/lib /opt/homebrew/lib \
            "/Applications/DeepSeek Harness.app/Contents/Resources"
do
  [ -d "$root" ] || continue
  find "$root" -maxdepth 12 -type d -name dsh -path '*@deepseek-ai/dsh' 2>/dev/null
done | while read -r d; do
  v=$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$d/package.json" 2>/dev/null | head -1)
  echo "  version=$v  at $d"
done | sort -u

echo
echo "== 3. Electron app version =="
defaults read "/Applications/DeepSeek Harness.app/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null

echo
echo "== 4. desktop runtime manifest =="
cat "$HOME/.dsh/dsh-runtimes/dsh-primary-runtime/runtime.json" 2>/dev/null | sed -n '1,8p'

echo
echo "== 5. profiles =="
ls -1 "$HOME/.dsh/profiles" 2>/dev/null

echo
echo "== 6. which dsh version each profile resolves =="
for p in "$HOME/.dsh/profiles"/*/; do
  n=$(basename "$p")
  [ "$n" = "node_modules" ] && continue
  b=$(sed -n 's/.*"bundles"[^]]*\]//p' "$p/package.json" 2>/dev/null | head -1)
  echo "  profile $n"
done

echo
echo "== 7. running process version =="
curl -s --max-time 4 http://127.0.0.1:17390/ctl/health 2>/dev/null || echo "(control plane not responding)"
echo
