#!/usr/bin/env bash
set -euo pipefail
IPA="$HOME/dl/Life360-ipa/Life360.ipa"
[ -f "$IPA" ] || { echo "no ipa at $IPA - run go.sh first"; exit 1; }
TAG="v$(date +%Y%m%d%H%M)"
gh release create "$TAG" "$IPA" --title "$TAG" 2>/dev/null || true
URL=$(gh release view "$TAG" --json assets --jq '.assets[0].url')
echo ""
echo "Paste this URL into ESign / Feather on her iPhone:"
echo "$URL"
echo ""
command -v termux-clipboard-set >/dev/null && echo "$URL" | termux-clipboard-set || true
