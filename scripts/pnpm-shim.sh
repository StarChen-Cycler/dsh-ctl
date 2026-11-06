#!/bin/sh
# pnpm shim: dsh resolves an executable literally named "pnpm" on PATH, while
# the DSH runtime ships pnpm as a .cjs entry point run through node.
R="$HOME/.dsh/dsh-runtimes/dsh-primary-runtime/dependencies"
exec "$R/node/bin/node" "$R/pnpm/bin/pnpm.cjs" "$@"
