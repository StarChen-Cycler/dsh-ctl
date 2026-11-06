#!/bin/sh
# pnpm shim: dsh resolves an executable literally named "pnpm" on PATH, and
# some DSH runtimes only ship pnpm as a .cjs entry point.
#
# Delegates to the newest pnpm found next to an installed Node. It deliberately
# does not depend on the DSH-bundled runtime, which belongs to the desktop app
# and disappears when that app is uninstalled.
for d in $(ls -d "$HOME"/.nvm/versions/node/*/bin 2>/dev/null | sort -r) \
         /opt/homebrew/bin /usr/local/bin /usr/bin
do
  if [ -x "$d/pnpm" ]; then exec "$d/pnpm" "$@"; fi
done

# Last resort: a pnpm.cjs shipped inside the DSH runtime.
R="$HOME/.dsh/dsh-runtimes/dsh-primary-runtime/dependencies"
if [ -x "$R/node/bin/node" ] && [ -f "$R/pnpm/bin/pnpm.cjs" ]; then
  exec "$R/node/bin/node" "$R/pnpm/bin/pnpm.cjs" "$@"
fi

echo "pnpm shim: no pnpm found (need one next to a Node install)." >&2
exit 1
