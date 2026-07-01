#!/bin/bash
#
# 手動 deploy fallback (直接 SSH)。
# Docker image を build + push し、Kagoya VPS へ直接 SSH で deploy する。
# 実 deploy ロジック (pull + 入れ替え + health check) は scripts/deploy-remote.sh
# に集約し、CI (Cloudflare Tunnel SSH 経路) と共有している。
set -euo pipefail

cd "$(dirname "$0")/.."

IMAGE="ghcr.io/ohishi-exp/browser-render-rust"
TAG=$(git rev-parse --short HEAD)

echo "=== Browser Render Rust - Deploy to Kagoya VPS ==="
echo "Image: ${IMAGE}:${TAG}"
echo ""

echo "=== Building Docker image ==="
docker build \
    --build-arg CARGO_BUILD_JOBS=2 \
    --cpuset-cpus="0-3" \
    -t "${IMAGE}:${TAG}" -t "${IMAGE}:latest" .

echo ""
echo "=== Pushing to GHCR ==="
docker push "${IMAGE}:${TAG}"
docker push "${IMAGE}:latest"

# 直接 SSH (Tailscale/Cloudflare Tunnel 無し、パブリック IP への疎通)。
export IMAGE
export TAG
export DEPLOY_SSH_HOST="${DEPLOY_SSH_HOST:-133.18.162.83}"
export DEPLOY_SSH_USER="${DEPLOY_SSH_USER:-ubuntu}"
export DEPLOY_SSH_KEY_FILE="${DEPLOY_SSH_KEY_FILE:-$HOME/.ssh/kagoya.key}"

exec bash scripts/deploy-remote.sh
