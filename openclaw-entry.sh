#!/bin/sh
# openclaw-entry.sh — OpenClaw version-switch entrypoint
# Prefer the upgraded version under HOME (npm_config_prefix),
# fall back to the image-bundled version.

set -e

HOME_PKG="$HOME/.npm-global/lib/node_modules/openclaw/openclaw.mjs"
IMAGE_PKG="/app/openclaw.mjs"

if [ -f "$HOME_PKG" ]; then
  exec node "$HOME_PKG" "$@"
else
  exec node "$IMAGE_PKG" "$@"
fi
