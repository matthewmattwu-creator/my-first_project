import hashlib
import json
import os
import re
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

from fastapi import HTTPException
from fastapi.responses import FileResponse

from license_server import app

UPDATE_DIR = Path(os.getenv("CAD100_UPDATE_DIR", str(Path(__file__).resolve().parent / "updates")))
MANIFEST_PATH = UPDATE_DIR / "latest.json"
PACKAGE_PATH = UPDATE_DIR / "CAD-100-latest.zip"
MAX_UPDATE_BYTES = int(os.getenv("CAD100_MAX_UPDATE_BYTES", str(250 * 1024 * 1024)))
_VERSION_RE = re.compile(r"^\d+\.\d+\.\d+(?:\.\d+)?$")


def _utc_now_text() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def read_manifest() -> Optional[dict]:
    try:
        if not MANIFEST_PATH.exists() or not PACKAGE_PATH.exists():
            return None
        data = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
        if not data.get("version"):
            return None
        return data
    except Exception:
        return None


def publish_update_bytes(version: str, notes: str, required: bool, content: bytes) -> dict:
    version = (version or "").strip()
    if not _VERSION_RE.match(version):
        raise HTTPException(status_code=400, detail="版本号格式应为 2.1.0。")
    if not content:
        raise HTTPException(status_code=400, detail="更新包不能为空。")
    if len(content) > MAX_UPDATE_BYTES:
        raise HTTPException(status_code=413, detail="更新包过大。")
    if not content.startswith(b"PK"):
        raise HTTPException(status_code=400, detail="更新包必须是 ZIP 文件。")

    UPDATE_DIR.mkdir(parents=True, exist_ok=True)
    temp_package = UPDATE_DIR / "CAD-100-uploading.zip"
    temp_manifest = UPDATE_DIR / "latest-uploading.json"
    temp_package.write_bytes(content)

    digest = hashlib.sha256(content).hexdigest()
    manifest = {
        "version": version,
        "required": bool(required),
        "notes": (notes or "").strip(),
        "download_url": "/api/v1/update/package",
        "sha256": digest,
        "size": len(content),
        "published_at": _utc_now_text(),
    }
    temp_manifest.write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")
    os.replace(str(temp_package), str(PACKAGE_PATH))
    os.replace(str(temp_manifest), str(MANIFEST_PATH))
    return manifest


@app.get("/api/v1/update/latest")
def update_latest():
    manifest = read_manifest()
    if not manifest:
        return {
            "success": True,
            "available": False,
            "version": "",
            "required": False,
            "notes": "",
            "download_url": "",
            "sha256": "",
            "size": 0,
            "published_at": "",
        }
    result = dict(manifest)
    result["success"] = True
    result["available"] = True
    return result


@app.get("/api/v1/update/package")
def update_package():
    manifest = read_manifest()
    if not manifest or not PACKAGE_PATH.exists():
        raise HTTPException(status_code=404, detail="暂无可下载更新包。")
    return FileResponse(
        path=str(PACKAGE_PATH),
        filename="CAD-100-" + str(manifest.get("version", "latest")) + ".zip",
        media_type="application/zip",
        headers={"Cache-Control": "no-store"},
    )
