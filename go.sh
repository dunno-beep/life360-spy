#!/usr/bin/env bash
set -euo pipefail
REPO="${REPO:-life360-spy}"

command -v gh >/dev/null || { echo "run: pkg install gh"; exit 1; }

git init -q 2>/dev/null || true
git add -A
git commit -qm "init" 2>/dev/null || true
git branch -M main 2>/dev/null || true

if ! gh auth status >/dev/null 2>&1; then
  echo "== GitHub sign-in. Copy the code it shows, open the browser. =="
  gh auth login --hostname github.com --git-protocol https --web
fi

if ! git remote get-url origin >/dev/null 2>&1; then
  gh repo create "$REPO" --public --source=. --push
else
  git push -q
fi

echo "== Triggering builds =="
gh workflow run ios.yml
gh workflow run android.yml
sleep 8

echo "== Building (3-6 min). Coffee. =="
while :; do
  n=$(gh run list --limit 20 --json status --jq '[.[]|select(.status!="completed")]|length' 2>/dev/null || echo 1)
  [ "$n" -eq 0 ] && break
  echo "   $n still running..."
  sleep 20
done

echo "== Downloading =="
mkdir -p ~/dl && cd ~/dl
for wf in ios.yml android.yml; do
  id=$(gh run list --workflow="$wf" --limit 1 --json databaseId --jq '.[0].databaseId')
  gh run download "$id" || echo "   (no artifact for $wf)"
done

echo ""
echo "== Done =="
find ~/dl -type f | sort
echo ""
echo "Next: termux-open ~/dl/Monitor-apk/app-debug.apk"
echo "Then: bash start-relay.sh"
echo "Then: bash publish-ipa.sh"
