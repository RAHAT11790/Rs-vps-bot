"""RS Anime 03 - VPS backend (FastAPI)."""
from __future__ import annotations
import os, shutil, signal, subprocess, sys, time, uuid
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
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])

PROCS: dict[str, subprocess.Popen] = {}

def auth(x_api_key: Optional[str] = Header(default=None)) -> None:
    if not API_KEY or x_api_key != API_KEY:
        raise HTTPException(status_code=401, detail="Invalid API key")

def project_path(pid: str) -> Path:
    p = (PROJECTS_DIR / pid).resolve()
    if PROJECTS_DIR not in p.parents and p != PROJECTS_DIR:
        raise HTTPException(400, "Bad project id")
    return p

def safe_path(pid: str, rel: str) -> Path:
    root = project_path(pid)
    target = (root / rel.lstrip("/")).resolve()
    if root not in target.parents and target != root:
        raise HTTPException(400, "Path traversal")
    return target

@app.get("/health")
def health():
    return {"status": "ok", "version": app.version, "uptime": time.time() - psutil.boot_time()}

@app.get("/system", dependencies=[Depends(auth)])
def system():
    vm = psutil.virtual_memory(); du = psutil.disk_usage(str(PROJECTS_DIR))
    return {
        "cpu_percent": psutil.cpu_percent(interval=0.2),
        "ram": {"total": vm.total, "used": vm.used, "percent": vm.percent},
        "disk": {"total": du.total, "used": du.used, "percent": du.percent},
        "python": f"{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}",
        "platform": os.uname().sysname + " " + os.uname().release,
    }

class ProjectIn(BaseModel):
    name: str
    owner_id: str
    ram_mb: int = 500
    storage_gb: int = 5

@app.get("/projects", dependencies=[Depends(auth)])
def list_projects(owner_id: Optional[str] = None):
    out = []
    for p in PROJECTS_DIR.iterdir():
        if not p.is_dir(): continue
        meta = {}
        mf = p / ".meta"
        if mf.exists():
            for line in mf.read_text().splitlines():
                if "=" in line:
                    k, v = line.split("=", 1); meta[k] = v
        if owner_id and meta.get("owner_id") != owner_id: continue
        running = p.name in PROCS and PROCS[p.name].poll() is None
        out.append({"id": p.name, "name": meta.get("name", p.name),
                    "owner_id": meta.get("owner_id", ""),
                    "status": "running" if running else "stopped"})
    return {"projects": out}

@app.post("/projects", dependencies=[Depends(auth)])
def create_project(body: ProjectIn):
    pid = uuid.uuid4().hex[:12]
    root = project_path(pid); root.mkdir(parents=True, exist_ok=True)
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

@app.post("/projects/{pid}/start", dependencies=[Depends(auth)])
def start_project(pid: str):
    root = project_path(pid)
    if not (root / "main.py").exists(): raise HTTPException(404, "main.py not found")
    if pid in PROCS and PROCS[pid].poll() is None: return {"ok": True, "already": True}
    log = open(root / "run.log", "ab")
    proc = subprocess.Popen(["python3", "-u", "main.py"], cwd=root, stdout=log, stderr=log, preexec_fn=os.setsid)
    PROCS[pid] = proc
    return {"ok": True, "pid": proc.pid}

@app.post("/projects/{pid}/stop", dependencies=[Depends(auth)])
def stop_project(pid: str):
    proc = PROCS.get(pid)
    if proc and proc.poll() is None:
        try: os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
        except ProcessLookupError: pass
    return {"ok": True}

@app.post("/projects/{pid}/restart", dependencies=[Depends(auth)])
def restart_project(pid: str):
    stop_project(pid); time.sleep(0.5); return start_project(pid)

@app.get("/projects/{pid}/logs", dependencies=[Depends(auth)])
def logs(pid: str, tail: int = 500):
    lf = project_path(pid) / "run.log"
    if not lf.exists(): return {"lines": []}
    return {"lines": lf.read_text(errors="ignore").splitlines()[-tail:]}

@app.get("/projects/{pid}/files", dependencies=[Depends(auth)])
def list_files(pid: str, path: str = ""):
    p = safe_path(pid, path)
    if not p.exists(): raise HTTPException(404, "Not found")
    if p.is_file(): return {"type": "file", "content": p.read_text(errors="ignore")}
    entries = [{"name": c.name, "is_dir": c.is_dir(), "size": c.stat().st_size, "mtime": c.stat().st_mtime}
               for c in sorted(p.iterdir(), key=lambda x: (x.is_file(), x.name.lower()))]
    return {"type": "dir", "entries": entries}

class FileWrite(BaseModel):
    content: str

@app.put("/projects/{pid}/files", dependencies=[Depends(auth)])
def write_file(pid: str, path: str, body: FileWrite):
    p = safe_path(pid, path); p.parent.mkdir(parents=True, exist_ok=True)
    tmp = p.with_suffix(p.suffix + ".tmp"); tmp.write_text(body.content); tmp.replace(p)
    return {"ok": True, "size": p.stat().st_size}

@app.delete("/projects/{pid}/files", dependencies=[Depends(auth)])
def delete_file(pid: str, path: str):
    p = safe_path(pid, path)
    if p.is_dir(): shutil.rmtree(p)
    elif p.exists(): p.unlink()
    return {"ok": True}

@app.post("/projects/{pid}/upload", dependencies=[Depends(auth)])
async def upload(pid: str, path: str = "", file: UploadFile = File(...)):
    target = safe_path(pid, f"{path}/{file.filename}")
    target.parent.mkdir(parents=True, exist_ok=True)
    with target.open("wb") as f:
        shutil.copyfileobj(file.file, f)
    return {"ok": True, "name": file.filename}
