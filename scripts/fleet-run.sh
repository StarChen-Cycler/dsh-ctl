#!/bin/sh
# Launch the DSH fleet profile (web app) on macOS.
#
# Two deployment facts drive this script:
#
# 1. `dsh` resolves an executable named `node` on PATH. The DSH runtime ships a
#    node binary but does not put it on the login PATH, so we prepend one.
#
# 2. The DSH-bundled node is signed with the vendor's Developer ID and hardened
#    runtime, which refuses to dlopen the ad-hoc-signed native binding that a
#    package manager downloads. A regular Node install loads it fine. We
#    therefore prefer a normal Node and only fall back to the bundled one.
#    Override with DSH_NODE_BIN=/path/to/node.
#
# 3. A pnpm *global* install lays packages out isolated behind symlinks, so the
#    addon loader's bare `require('node-addon-require-builtin-<platform>')`
#    cannot see the platform package. NODE_PATH is the CommonJS fallback root;
#    we point it at a shim directory built by mac-link-native-binding.sh.
set -eu

PNPM_HOME="${PNPM_HOME:-$HOME/.dsh/pnpm-global}"
export PNPM_HOME

find_node() {
  if [ -n "${DSH_NODE_BIN:-}" ] && [ -x "${DSH_NODE_BIN}" ]; then
    printf '%s\n' "$DSH_NODE_BIN"
    return 0
  fi
  # Newest nvm install first: lexicographic glob order would pick v20 before
  # v24, and some DSH packages need a newer Node than the oldest one present.
  for candidate in $(ls -d "$HOME"/.nvm/versions/node/*/bin/node 2>/dev/null | sort -r) \
                   /opt/homebrew/bin/node \
                   /usr/local/bin/node \
                   /usr/bin/node
  do
    if [ -x "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

NODE_BIN="$(find_node || true)"
if [ -n "$NODE_BIN" ]; then
  NODE_DIR="$(dirname "$NODE_BIN")"
else
  NODE_DIR="$HOME/.dsh/dsh-runtimes/dsh-primary-runtime/dependencies/node/bin"
fi

export PATH="$NODE_DIR:$PNPM_HOME/bin:$PATH"
if [ -d "$PNPM_HOME/node-path" ]; then
  export NODE_PATH="${NODE_PATH:+$NODE_PATH:}$PNPM_HOME/node-path"
fi

PORT="${DSH_FLEET_PORT:-17390}"
PROFILE="${DSH_FLEET_PROFILE:-fleet}"

echo "node: ${NODE_BIN:-$NODE_DIR/node} ($("${NODE_DIR}/node" -v 2>/dev/null || echo unknown))"
exec dsh "$PROFILE" --port "$PORT" --no-open
