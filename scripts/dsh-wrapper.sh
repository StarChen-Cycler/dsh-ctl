#!/bin/sh
# dsh — wrapper around the DSH CLI, for install at ~/.local/bin/dsh (or anywhere
# already on PATH).
#
# Why a wrapper instead of exporting a PATH entry for the CLI:
#
#  - dsh 0.2.1-rc.5 needs Node >= 22. If nvm's default is v20, `dsh` exits
#    silently with no output at all — the worst possible failure mode.
#  - The DSH-bundled Node cannot be used either: it is hardened-runtime signed
#    and refuses to dlopen the ad-hoc-signed native addon that npm installs
#    ("different Team IDs").
#
# Prepending a Node to the global PATH would change `node` for every other
# project on the machine. Scoping the choice to this one command keeps the
# rest of the environment untouched.
PNPM_HOME="$HOME/.dsh/pnpm-global"

NODE_BIN=""
for c in $(ls -d "$HOME"/.nvm/versions/node/v24*/bin/node 2>/dev/null | sort -r) \
         /opt/homebrew/bin/node \
         /usr/local/bin/node \
         /usr/bin/node
do
  if [ -x "$c" ]; then NODE_BIN="$c"; break; fi
done

if [ -z "$NODE_BIN" ]; then
  echo "dsh: no suitable Node found (need >= 22). Set DSH_NODE_BIN or install one." >&2
  exit 1
fi

export PNPM_HOME
export PATH="$(dirname "$NODE_BIN"):$PNPM_HOME/bin:$PATH"
if [ -d "$PNPM_HOME/node-path" ]; then
  export NODE_PATH="${NODE_PATH:+$NODE_PATH:}$PNPM_HOME/node-path"
fi

exec "$PNPM_HOME/bin/dsh" "$@"
