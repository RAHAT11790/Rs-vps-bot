#!/usr/bin/env bash
set -e
cd "$(dirname "$0")"
source .venv/bin/activate
set -a; source .env; set +a

mkdir -p logs
echo "[api] starting uvicorn on ${HOST}:${PORT}..."
nohup .venv/bin/uvicorn app.main:app --host "${HOST}" --port "${PORT}" > logs/api.log 2>&1 &
API_PID=$!
sleep 2

echo "[tunnel] starting cloudflared quick tunnel..."
nohup cloudflared tunnel --no-autoupdate --url "http://${HOST}:${PORT}" > logs/tunnel.log 2>&1 &
TUN_PID=$!

echo "Waiting for tunnel URL..."
URL=""
for i in $(seq 1 30); do
  URL=$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' logs/tunnel.log | head -n1 || true)
  [ -n "$URL" ] && break
  sleep 1
done

echo ""
echo "============================================================"
echo "  RS ANIME 03 - VPS READY"
echo "  Public URL : ${URL:-<not detected, check logs/tunnel.log>}"
echo "  API Key    : ${API_KEY}"
echo "  API PID    : ${API_PID}"
echo "  Tunnel PID : ${TUN_PID}"
echo "  Logs       : logs/api.log , logs/tunnel.log"
echo "  -> Paste URL + API Key into the panel Configuration page."
echo "============================================================"
