#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/server"
[ -d node_modules ] || { npm init -y >/dev/null 2>&1; npm i express ws >/dev/null 2>&1; }
export TOKEN="$(cat ../.token 2>/dev/null || echo CHANGE_ME)"
echo "relay starting, token=$TOKEN"
command -v termux-wake-lock >/dev/null && termux-wake-lock || true
exec node server.js
