#!/bin/bash
#
# Docker image を Kagoya VPS へ SSH 経由で pull + restart させる共通 deploy
# ロジック。build/push は呼び出し側 (ci.yml の deploy job、または
# scripts/deploy-kagoya.sh) が担当し、本スクリプトは「イメージを配って
# コンテナを入れ替える」部分だけを担う。
#
# 接続方式は直接 SSH が基本 (dtako-scraper と同じ Kagoya VPS への直接到達):
#   - ci.yml deploy job (自動)     … webfactory/ssh-agent で秘密鍵を ssh-agent に
#                                    載せ、DEPLOY_SSH_HOST/USER だけ渡す
#   - scripts/deploy-kagoya.sh (手動 fallback) … DEPLOY_SSH_KEY_FILE で鍵ファイル指定
# Cloudflare Tunnel 経由 (DEPLOY_SSH_PROXY_COMMAND) も引き続きサポートするが、
# 現状 CI/手動どちらも使用していない (将来 VPS 側を Tunnel 化する場合の保険)。
#
# 必須 env:
#   DEPLOY_SSH_HOST   … 接続先 SSH ホスト名 (IP でも可)
#   IMAGE             … pull する image (タグ無し。例: ghcr.io/ohishi-exp/browser-render-rust)
#   TAG               … デプロイするタグ
#
# 任意 env:
#   DEPLOY_SSH_USER          … SSH ユーザー (default: ubuntu)
#   DEPLOY_SSH_KEY_FILE      … 秘密鍵 path (未指定なら ssh-agent / 既定鍵を使う)
#   DEPLOY_SSH_PROXY_COMMAND … ssh -o ProxyCommand=<...> に渡す値
#                               (Cloudflare Tunnel SSH なら "cloudflared access ssh --hostname %h")
#   CF_ACCESS_CLIENT_ID       … CF Access service token id  (cloudflared が読む、Tunnel 使用時のみ)
#   CF_ACCESS_CLIENT_SECRET   … CF Access service token secret (Tunnel 使用時のみ)
#   CONTAINER_NAME            … デプロイ先コンテナ名 (default: browser-render)
#   DEPLOY_HEALTH_PORT        … 疎通確認する remote localhost ポート (default: 8080)
#   GHCR_TOKEN / GHCR_USER    … remote docker pull 用の GHCR credential。CI からは
#                               job 限りの ${{ secrets.GITHUB_TOKEN }} (packages:read)
#                               + ${{ github.actor }} を渡す想定 (dtako-scraper/
#                               .github/workflows/deploy.yml と同パターン)。未指定なら
#                               VPS 側 /opt/browser-render/.env の GHCR_TOKEN に fallback
#                               (旧 namespace 用の静的 PAT。org package には効かない場合あり)
#   AUTH_WORKER_URL           … dtakologs 送信の device JWT 発行元 (rust-alc-api#434)。
#   DEVICE_ID / DEVICE_SECRET … device pairing で発行した credential。
#                               この 3 つは指定されていれば VPS 側 /opt/browser-render/.env に
#                               upsert される (= VPS が変わっても deploy し直すだけで再設定
#                               不要になる)。device credential は VPS ではなく tenant に紐付く
#                               ため、同じ値をどの VPS でも使い回せる。**空なら .env を触らない**
#                               (= 既存の手動 .env 運用と後方互換)。CI からは
#                               ${{ secrets.BROWSER_RENDER_DEVICE_ID / _SECRET }} を渡す想定
#                               (GHCR_TOKEN と同じ SSH env-var 前置き経路で値をログに出さない)。
#
# deploy 失敗 (image 未指定 / ssh / health) は即 exit != 0 で loud fail する。
set -euo pipefail

SSH_USER="${DEPLOY_SSH_USER:-ubuntu}"
TARGET_HOST="${DEPLOY_SSH_HOST:?DEPLOY_SSH_HOST is required}"
TARGET="$SSH_USER@$TARGET_HOST"
IMAGE="${IMAGE:?IMAGE is required}"
TAG="${TAG:?TAG is required}"
CONTAINER_NAME="${CONTAINER_NAME:-browser-render}"
HEALTH_PORT="${DEPLOY_HEALTH_PORT:-8080}"
GHCR_TOKEN="${GHCR_TOKEN:-}"
GHCR_USER="${GHCR_USER:-ohishi-exp}"
# dtakologs 送信の device JWT 設定 (rust-alc-api#434)。空なら .env を触らない。
AUTH_WORKER_URL="${AUTH_WORKER_URL:-}"
DEVICE_ID="${DEVICE_ID:-}"
DEVICE_SECRET="${DEVICE_SECRET:-}"

# Cloudflare Access service token は cloudflared が TUNNEL_SERVICE_TOKEN_* env を読む。
if [[ -n "${CF_ACCESS_CLIENT_ID:-}" ]]; then
  export TUNNEL_SERVICE_TOKEN_ID="$CF_ACCESS_CLIENT_ID"
fi
if [[ -n "${CF_ACCESS_CLIENT_SECRET:-}" ]]; then
  export TUNNEL_SERVICE_TOKEN_SECRET="$CF_ACCESS_CLIENT_SECRET"
fi

# ssh 共通オプションを組み立てる。
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o BatchMode=yes)
if [[ -n "${DEPLOY_SSH_KEY_FILE:-}" ]]; then
  SSH_OPTS+=(-i "$DEPLOY_SSH_KEY_FILE" -o IdentitiesOnly=yes)
fi
if [[ -n "${DEPLOY_SSH_PROXY_COMMAND:-}" ]]; then
  SSH_OPTS+=(-o "ProxyCommand=$DEPLOY_SSH_PROXY_COMMAND")
fi

echo "=== Deploying ${IMAGE}:${TAG} to ${TARGET} (container: ${CONTAINER_NAME}) ==="

# リモート側の手順 (pull → 入れ替え → health check) はここでヒアドキュメントとして
# 送り込む。IMAGE/TAG/CONTAINER_NAME/HEALTH_PORT は引数で渡す (remote 側の env
# 汚染を避ける)。GHCR_TOKEN/GHCR_USER は `VAR=val ... bash -s` の env-var 前置き
# 形式で渡す (positional arg にすると remote 側の `ps` に短時間映り込みうるため、
# secret はこちらの経路を使う。dtako-scraper/.github/workflows/deploy.yml と同パターン)。
if ! ssh "${SSH_OPTS[@]}" "$TARGET" \
    GHCR_TOKEN="$GHCR_TOKEN" GHCR_USER="$GHCR_USER" \
    AUTH_WORKER_URL="$AUTH_WORKER_URL" DEVICE_ID="$DEVICE_ID" DEVICE_SECRET="$DEVICE_SECRET" \
    bash -s -- "$IMAGE" "$TAG" "$CONTAINER_NAME" "$HEALTH_PORT" <<'REMOTE_SCRIPT'
set -e
IMAGE="$1"
TAG="$2"
CONTAINER_NAME="$3"
HEALTH_PORT="$4"
ENV_FILE=/opt/browser-render/.env

# GHCR ログイン。CI から渡された job 限りの GHCR_TOKEN (packages:read) を優先し、
# 未指定なら VPS 側 .env の静的 GHCR_TOKEN に fallback する。
if [ -n "${GHCR_TOKEN:-}" ]; then
    echo "$GHCR_TOKEN" | docker login ghcr.io -u "${GHCR_USER:-ohishi-exp}" --password-stdin
elif [ -f "$ENV_FILE" ]; then
    FALLBACK_TOKEN=$(grep -E '^GHCR_TOKEN=' "$ENV_FILE" | cut -d= -f2-)
    if [ -n "$FALLBACK_TOKEN" ]; then
        echo "$FALLBACK_TOKEN" | docker login ghcr.io -u ohishi-exp --password-stdin
    fi
fi

# device JWT 設定を .env に upsert する。値が空のキーは触らない (= 手動運用と後方互換)。
# value は printf でファイルに書くだけで stdout に出さない (ログ非表示、key 名だけ echo)。
upsert_env() {
    key="$1"
    val="$2"
    [ -n "$val" ] || return 0
    touch "$ENV_FILE"
    tmp="${ENV_FILE}.tmp.$$"
    # 当該 key 以外の行を残す (grep は no-match で exit 1 になり得るので許容)。
    grep -v "^${key}=" "$ENV_FILE" > "$tmp" 2>/dev/null || true
    printf '%s=%s\n' "$key" "$val" >> "$tmp"
    chmod 600 "$tmp"
    mv "$tmp" "$ENV_FILE"
    echo "  .env updated: ${key}"
}
upsert_env AUTH_WORKER_URL "${AUTH_WORKER_URL:-}"
upsert_env DEVICE_ID "${DEVICE_ID:-}"
upsert_env DEVICE_SECRET "${DEVICE_SECRET:-}"

echo 'Pulling new image...'
docker pull "${IMAGE}:${TAG}"

echo 'Stopping existing container...'
docker stop "$CONTAINER_NAME" 2>/dev/null || true
docker rm "$CONTAINER_NAME" 2>/dev/null || true

echo 'Starting new container...'
docker run -d \
    --name "$CONTAINER_NAME" \
    --restart=unless-stopped \
    --init \
    -p 127.0.0.1:8080:8080 \
    -p 127.0.0.1:50051:50051 \
    -v /opt/browser-render/data:/app/data \
    -v /opt/browser-render/logs:/app/logs \
    -v /opt/browser-render/downloads:/app/downloads \
    --env-file /opt/browser-render/.env \
    --shm-size=1g \
    --ulimit nofile=65536:65536 \
    --security-opt seccomp=unconfined \
    "${IMAGE}:${TAG}"

echo 'Waiting for health check...'
for i in $(seq 1 15); do
    if curl -sf "http://localhost:${HEALTH_PORT}/health" > /dev/null 2>&1; then
        echo 'Health check passed!'
        docker ps -f "name=${CONTAINER_NAME}"
        echo 'Cleaning up old images...'
        docker image prune -af --filter 'until=24h'
        exit 0
    fi
    echo "Waiting... (${i}/15)"
    sleep 2
done

echo 'Health check failed!'
docker logs "$CONTAINER_NAME"
exit 1
REMOTE_SCRIPT
then
  echo "::error::deploy failed on remote host ${TARGET_HOST}" >&2
  exit 1
fi

echo "=== Done! deployed ${IMAGE}:${TAG} on ${TARGET_HOST} ==="
