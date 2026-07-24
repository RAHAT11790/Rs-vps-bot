# RS Anime 03 — VPS Backend

FastAPI backend that the RS Anime 03 web panel talks to.
Runs on your VPS, exposes a public URL via Cloudflare Tunnel (quick tunnel, no domain needed),
and prints an API key you paste into the panel's **Configuration** page.

## Quick start

```bash
unzip rs-anime-vps.zip
cd rs-anime-vps
chmod +x install.sh start.sh
./install.sh          # installs python deps + cloudflared
./start.sh            # starts API + tunnel, prints URL & API key
```

At the end you will see:

```
============================================================
  RS ANIME 03 — VPS READY
  Public URL : https://xxxxx.trycloudflare.com
  API Key    : rs_xxxxxxxxxxxxxxxxxxxxxxxx
  → Paste both into the panel Configuration page.
============================================================
```

## Files
- `app/main.py`     — FastAPI app (projects, files, logs, process control)
- `requirements.txt`
- `install.sh`      — one-shot installer (python venv + cloudflared)
- `start.sh`        — launches uvicorn + `cloudflared tunnel --url`
- `rs-anime.service`— optional systemd unit
- `.env.example`

## Security
Every request must include header `X-API-Key: <key from start.sh>`.
The key is generated on first run and stored in `.env`.