#!/usr/bin/env bash
set -e
cd "$(dirname "$0")"

echo "[1/3] Creating python venv..."
python3 -m venv .venv
# shellcheck disable=SC1091
source .venv/bin/activate
pip install --upgrade pip >/dev/null
pip install -r requirements.txt

echo "[2/3] Installing cloudflared..."
if ! command -v cloudflared >/dev/null 2>&1; then
  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64) URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64" ;;
    aarch64|arm64) URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64" ;;
    *) echo "Unsupported arch $ARCH — install cloudflared manually"; exit 1 ;;
  esac
  sudo curl -L "$URL" -o /usr/local/bin/cloudflared
  sudo chmod +x /usr/local/bin/cloudflared
fi

echo "[3/3] Preparing .env..."
if [ ! -f .env ]; then
  KEY="rs_$(head -c 24 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 32)"
  cp .env.example .env
  sed -i "s|change_me_auto_generated_on_first_run|$KEY|" .env
fi

mkdir -p projects logs
echo "Done. Run: ./start.sh"
*** Add File: /tmp/vps-src/rs-anime-vps/start.sh
#!/usr/bin/env bash
set -e
cd "$(dirname "$0")"
# shellcheck disable=SC1091
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
echo "  RS ANIME 03 — VPS READY"
echo "  Public URL : ${URL:-<not detected — check logs/tunnel.log>}"
echo "  API Key    : ${API_KEY}"
echo "  API PID    : ${API_PID}"
echo "  Tunnel PID : ${TUN_PID}"
echo "  Logs       : logs/api.log , logs/tunnel.log"
echo "  → Paste URL + API Key into the panel Configuration page."
echo "============================================================"
*** Add File: /tmp/vps-src/rs-anime-vps/rs-anime.service
[Unit]
Description=RS Anime 03 VPS backend
After=network.target

[Service]
Type=simple
WorkingDirectory=/opt/rs-anime-vps
EnvironmentFile=/opt/rs-anime-vps/.env
ExecStart=/opt/rs-anime-vps/.venv/bin/uvicorn app.main:app --host 127.0.0.1 --port 8787
Restart=on-failure
User=root

[Install]
WantedBy=multi-user.target
*** Add File: /tmp/vps-src/rs-anime-vps/app/__init__.py
*** Add File: /tmp/vps-src/rs-anime-vps/app/main.py
"""RS Anime 03 — VPS backend.

Minimal FastAPI surface the panel expects. Extend as needed; the panel
only calls what it renders, so 501s are acceptable while you iterate.
"""
from __future__ import annotations

import os
import shutil
import signal
import subprocess
import time
import uuid
from pathlib import Path
from typing import Optional

import psutil
from fastapi import Depends, FastAPI, Header, HTTPException, UploadFile, File
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel

API_KEY = os.getenv("API_KEY", "")
PROJECTS_DIR = Path(os.getenv("PROJECTS_DIR", "./projects")).resolve()
PROJECTS_DIR.mkdir(parents=True, exist_ok=True)

app = FastAPI(title="RS Anime 03 VPS", version="1.0.0")
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

# in-memory process registry: project_id -> Popen
PROCS: dict[str, subprocess.Popen] = {}


def auth(x_api_key: Optional[str] = Header(default=None)) -> None:
    if not API_KEY or x_api_key != API_KEY:
        raise HTTPException(status_code=401, detail="Invalid API key")


def project_path(pid: str) -> Path:
    p = (PROJECTS_DIR / pid).resolve()
    if PROJECTS_DIR not in p.parents and p != PROJECTS_DIR:
        raise HTTPException(status_code=400, detail="Bad project id")
    return p


def safe_path(pid: str, rel: str) -> Path:
    root = project_path(pid)
    target = (root / rel.lstrip("/")).resolve()
    if root not in target.parents and target != root:
        raise HTTPException(status_code=400, detail="Path traversal")
    return target


@app.get("/health")
def health():
    return {"status": "ok", "version": app.version, "uptime": time.time() - psutil.boot_time()}


@app.get("/system", dependencies=[Depends(auth)])
def system():
    vm = psutil.virtual_memory()
    du = psutil.disk_usage(str(PROJECTS_DIR))
    return {
        "cpu_percent": psutil.cpu_percent(interval=0.2),
        "ram": {"total": vm.total, "used": vm.used, "percent": vm.percent},
        "disk": {"total": du.total, "used": du.used, "percent": du.percent},
        "python": f"{os.sys.version_info.major}.{os.sys.version_info.minor}.{os.sys.version_info.micro}",
        "platform": os.uname().sysname + " " + os.uname().release,
    }


# ---------------- projects ----------------
class ProjectIn(BaseModel):
    name: str
    owner_id: str
    ram_mb: int = 500
    storage_gb: int = 5


@app.get("/projects", dependencies=[Depends(auth)])
def list_projects(owner_id: Optional[str] = None):
    out = []
    for p in PROJECTS_DIR.iterdir():
        if not p.is_dir():
            continue
        meta_file = p / ".meta"
        meta = {}
        if meta_file.exists():
            for line in meta_file.read_text().splitlines():
                if "=" in line:
                    k, v = line.split("=", 1)
                    meta[k] = v
        if owner_id and meta.get("owner_id") != owner_id:
            continue
        running = p.name in PROCS and PROCS[p.name].poll() is None
        out.append({"id": p.name, "name": meta.get("name", p.name),
                    "owner_id": meta.get("owner_id", ""),
                    "status": "running" if running else "stopped"})
    return {"projects": out}


@app.post("/projects", dependencies=[Depends(auth)])
def create_project(body: ProjectIn):
    pid = uuid.uuid4().hex[:12]
    root = project_path(pid)
    root.mkdir(parents=True, exist_ok=True)
    (root / ".meta").write_text(
        f"name={body.name}\nowner_id={body.owner_id}\nram_mb={body.ram_mb}\nstorage_gb={body.storage_gb}\n"
    )
    (root / "main.py").write_text("print('Hello from RS Anime 03')\n")
    return {"id": pid, "name": body.name, "status": "stopped"}


@app.delete("/projects/{pid}", dependencies=[Depends(auth)])
def delete_project(pid: str):
    stop_project(pid)
    shutil.rmtree(project_path(pid), ignore_errors=True)
    return {"ok": True}


# ---------------- process control ----------------
@app.post("/projects/{pid}/start", dependencies=[Depends(auth)])
def start_project(pid: str):
    root = project_path(pid)
    entry = root / "main.py"
    if not entry.exists():
        raise HTTPException(404, "main.py not found")
    if pid in PROCS and PROCS[pid].poll() is None:
        return {"ok": True, "already": True}
    log = open(root / "run.log", "ab")
    proc = subprocess.Popen(
        ["python3", "-u", "main.py"],
        cwd=root, stdout=log, stderr=log,
        preexec_fn=os.setsid,
    )
    PROCS[pid] = proc
    return {"ok": True, "pid": proc.pid}


@app.post("/projects/{pid}/stop", dependencies=[Depends(auth)])
def stop_project(pid: str):
    proc = PROCS.get(pid)
    if proc and proc.poll() is None:
        try:
            os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
        except ProcessLookupError:
            pass
    return {"ok": True}


@app.post("/projects/{pid}/restart", dependencies=[Depends(auth)])
def restart_project(pid: str):
    stop_project(pid)
    time.sleep(0.5)
    return start_project(pid)


@app.get("/projects/{pid}/logs", dependencies=[Depends(auth)])
def logs(pid: str, tail: int = 500):
    log_file = project_path(pid) / "run.log"
    if not log_file.exists():
        return {"lines": []}
    lines = log_file.read_text(errors="ignore").splitlines()[-tail:]
    return {"lines": lines}


# ---------------- files ----------------
@app.get("/projects/{pid}/files", dependencies=[Depends(auth)])
def list_files(pid: str, path: str = ""):
    p = safe_path(pid, path)
    if not p.exists():
        raise HTTPException(404, "Not found")
    if p.is_file():
        return {"type": "file", "content": p.read_text(errors="ignore")}
    entries = []
    for c in sorted(p.iterdir(), key=lambda x: (x.is_file(), x.name.lower())):
        entries.append({
            "name": c.name, "is_dir": c.is_dir(),
            "size": c.stat().st_size, "mtime": c.stat().st_mtime,
        })
    return {"type": "dir", "entries": entries}


class FileWrite(BaseModel):
    content: str


@app.put("/projects/{pid}/files", dependencies=[Depends(auth)])
def write_file(pid: str, path: str, body: FileWrite):
    p = safe_path(pid, path)
    p.parent.mkdir(parents=True, exist_ok=True)
    tmp = p.with_suffix(p.suffix + ".tmp")
    tmp.write_text(body.content)
    tmp.replace(p)
    return {"ok": True, "size": p.stat().st_size}


@app.delete("/projects/{pid}/files", dependencies=[Depends(auth)])
def delete_file(pid: str, path: str):
    p = safe_path(pid, path)
    if p.is_dir():
        shutil.rmtree(p)
    elif p.exists():
        p.unlink()
    return {"ok": True}


@app.post("/projects/{pid}/upload", dependencies=[Depends(auth)])
async def upload(pid: str, path: str = "", file: UploadFile = File(...)):
    target = safe_path(pid, f"{path}/{file.filename}")
    target.parent.mkdir(parents=True, exist_ok=True)
    with target.open("wb") as f:
        shutil.copyfileobj(file.file, f)
    return {"ok": True, "name": file.filename}