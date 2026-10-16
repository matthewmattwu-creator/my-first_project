import base64
import hashlib
import hmac
import json
import os
import secrets
import sqlite3
import time
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Optional

from fastapi import FastAPI, Header, HTTPException
from pydantic import BaseModel, Field
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding

APP_ROOT = Path(__file__).resolve().parent
DB_PATH = Path(os.getenv("CAD100_LICENSE_DB", str(APP_ROOT / "license.db")))
PRIVATE_KEY_PATH = Path(os.getenv("CAD100_PRIVATE_KEY", str(APP_ROOT / "keys" / "private_key.pem")))
ADMIN_TOKEN = os.getenv("CAD100_ADMIN_TOKEN", "")
TOKEN_TTL_DAYS = int(os.getenv("CAD100_TOKEN_TTL_DAYS", "30"))
OFFLINE_DAYS = int(os.getenv("CAD100_OFFLINE_DAYS", "7"))
DEFAULT_MAX_DEVICES = int(os.getenv("CAD100_DEFAULT_MAX_DEVICES", "2"))

app = FastAPI(title="CAD-100 License Server", version="2.0")


class ActivateRequest(BaseModel):
    name: str = Field(min_length=1, max_length=100)
    code: str = Field(min_length=1, max_length=100)
    device_id: str = Field(min_length=16, max_length=256)
    device_name: str = Field(default="", max_length=200)
    app_version: str = Field(default="", max_length=50)


class CheckRequest(BaseModel):
    token: str = Field(min_length=10)
    device_id: str = Field(min_length=16, max_length=256)
    app_version: str = Field(default="", max_length=50)


class AdminCreateUserRequest(BaseModel):
    name: str = Field(min_length=1, max_length=100)
    code: str = Field(min_length=1, max_length=100)
    max_devices: int = Field(default=DEFAULT_MAX_DEVICES, ge=1, le=20)


class AdminSetStatusRequest(BaseModel):
    active: bool


class AdminUnbindRequest(BaseModel):
    device_id: str = Field(min_length=16, max_length=256)


@contextmanager
def db():
    connection = sqlite3.connect(str(DB_PATH), timeout=20)
    connection.row_factory = sqlite3.Row
    connection.execute("PRAGMA foreign_keys = ON")
    try:
        yield connection
        connection.commit()
    finally:
        connection.close()


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


def iso_utc(value: datetime) -> str:
    return value.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).decode("ascii").rstrip("=")


def b64url_decode(value: str) -> bytes:
    return base64.urlsafe_b64decode(value + "=" * (-len(value) % 4))


def normalize_name(name: str) -> str:
    return " ".join(name.strip().split())


def hash_code(code: str, salt: Optional[str] = None) -> tuple[str, str]:
    salt_bytes = bytes.fromhex(salt) if salt else secrets.token_bytes(16)
    digest = hashlib.pbkdf2_hmac("sha256", code.encode("utf-8"), salt_bytes, 180_000)
    return salt_bytes.hex(), digest.hex()


def verify_code(code: str, salt: str, expected_hash: str) -> bool:
    _, actual = hash_code(code, salt)
    return hmac.compare_digest(actual, expected_hash)


def load_private_key():
    if not PRIVATE_KEY_PATH.exists():
        raise RuntimeError(f"RSA private key not found: {PRIVATE_KEY_PATH}")
    return serialization.load_pem_private_key(PRIVATE_KEY_PATH.read_bytes(), password=None)


def sign_token(user_id: int, name: str, device_id: str) -> str:
    now = int(time.time())
    payload = {
        "uid": user_id,
        "name": name,
        "device_id": device_id,
        "iat": now,
        "exp": now + TOKEN_TTL_DAYS * 86400,
    }
    payload_b64 = b64url(json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8"))
    signature = load_private_key().sign(
        payload_b64.encode("ascii"),
        padding.PKCS1v15(),
        hashes.SHA256(),
    )
    return payload_b64 + "." + b64url(signature)


def verify_token(token: str) -> dict:
    try:
        payload_b64, signature_b64 = token.split(".", 1)
        public_key = load_private_key().public_key()
        public_key.verify(
            b64url_decode(signature_b64),
            payload_b64.encode("ascii"),
            padding.PKCS1v15(),
            hashes.SHA256(),
        )
        payload = json.loads(b64url_decode(payload_b64).decode("utf-8"))
    except Exception as exc:
        raise HTTPException(status_code=401, detail=f"invalid token: {exc}")
    if int(payload.get("exp", 0)) < int(time.time()):
        raise HTTPException(status_code=401, detail="token expired")
    return payload


def require_admin(x_admin_token: Optional[str]) -> None:
    if not ADMIN_TOKEN:
        raise HTTPException(status_code=503, detail="CAD100_ADMIN_TOKEN is not configured")
    if not x_admin_token or not hmac.compare_digest(x_admin_token, ADMIN_TOKEN):
        raise HTTPException(status_code=401, detail="invalid admin token")


def init_db() -> None:
    DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    with db() as conn:
        conn.executescript(
            """
            CREATE TABLE IF NOT EXISTS users (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT NOT NULL UNIQUE COLLATE NOCASE,
                activation_salt TEXT NOT NULL,
                activation_hash TEXT NOT NULL,
                max_devices INTEGER NOT NULL DEFAULT 2,
                active INTEGER NOT NULL DEFAULT 1,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS devices (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                user_id INTEGER NOT NULL,
                device_id TEXT NOT NULL,
                device_name TEXT NOT NULL DEFAULT '',
                active INTEGER NOT NULL DEFAULT 1,
                first_bound_at TEXT NOT NULL,
                last_seen_at TEXT NOT NULL,
                app_version TEXT NOT NULL DEFAULT '',
                UNIQUE(user_id, device_id),
                FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE CASCADE
            );

            CREATE INDEX IF NOT EXISTS idx_devices_user_active
                ON devices(user_id, active);
            """
        )


@app.on_event("startup")
def startup() -> None:
    init_db()


@app.get("/health")
def health():
    return {"ok": True, "service": "cad100-license", "version": "2.0"}


@app.post("/api/v1/activate")
def activate(req: ActivateRequest):
    name = normalize_name(req.name)
    now = utc_now()
    with db() as conn:
        user = conn.execute("SELECT * FROM users WHERE name = ? COLLATE NOCASE", (name,)).fetchone()
        if not user or not user["active"]:
            return {"success": False, "valid": False, "message": "姓名或激活码不正确。"}
        if not verify_code(req.code, user["activation_salt"], user["activation_hash"]):
            return {"success": False, "valid": False, "message": "姓名或激活码不正确。"}

        existing = conn.execute(
            "SELECT * FROM devices WHERE user_id = ? AND device_id = ?",
            (user["id"], req.device_id),
        ).fetchone()

        if existing:
            if not existing["active"]:
                conn.execute("UPDATE devices SET active = 1 WHERE id = ?", (existing["id"],))
        else:
            active_count = conn.execute(
                "SELECT COUNT(*) AS c FROM devices WHERE user_id = ? AND active = 1",
                (user["id"],),
            ).fetchone()["c"]
            if active_count >= user["max_devices"]:
                return {
                    "success": False,
                    "valid": False,
                    "message": f"该用户已绑定 {active_count} 台电脑，达到上限 {user['max_devices']} 台。请联系管理员解绑旧设备。",
                    "devices_used": active_count,
                    "devices_limit": user["max_devices"],
                }
            conn.execute(
                """INSERT INTO devices
                   (user_id, device_id, device_name, active, first_bound_at, last_seen_at, app_version)
                   VALUES (?, ?, ?, 1, ?, ?, ?)""",
                (user["id"], req.device_id, req.device_name, iso_utc(now), iso_utc(now), req.app_version),
            )

        conn.execute(
            "UPDATE devices SET device_name = ?, last_seen_at = ?, app_version = ?, active = 1 WHERE user_id = ? AND device_id = ?",
            (req.device_name, iso_utc(now), req.app_version, user["id"], req.device_id),
        )
        active_count = conn.execute(
            "SELECT COUNT(*) AS c FROM devices WHERE user_id = ? AND active = 1",
            (user["id"],),
        ).fetchone()["c"]

    token = sign_token(user["id"], user["name"], req.device_id)
    return {
        "success": True,
        "valid": True,
        "message": "授权成功。",
        "token": token,
        "name": user["name"],
        "devices_used": active_count,
        "devices_limit": user["max_devices"],
        "offline_until_utc": iso_utc(now + timedelta(days=OFFLINE_DAYS)),
    }


@app.post("/api/v1/check")
def check(req: CheckRequest):
    payload = verify_token(req.token)
    if payload.get("device_id") != req.device_id:
        return {"success": False, "valid": False, "message": "授权不属于当前电脑。"}

    now = utc_now()
    with db() as conn:
        user = conn.execute("SELECT * FROM users WHERE id = ?", (payload.get("uid"),)).fetchone()
        if not user or not user["active"]:
            return {"success": False, "valid": False, "message": "用户授权已停用。"}
        device = conn.execute(
            "SELECT * FROM devices WHERE user_id = ? AND device_id = ? AND active = 1",
            (user["id"], req.device_id),
        ).fetchone()
        if not device:
            return {"success": False, "valid": False, "message": "此电脑的授权已被解绑或停用。"}
        conn.execute(
            "UPDATE devices SET last_seen_at = ?, app_version = ? WHERE id = ?",
            (iso_utc(now), req.app_version, device["id"]),
        )
        active_count = conn.execute(
            "SELECT COUNT(*) AS c FROM devices WHERE user_id = ? AND active = 1",
            (user["id"],),
        ).fetchone()["c"]

    refreshed = sign_token(user["id"], user["name"], req.device_id)
    return {
        "success": True,
        "valid": True,
        "message": "授权有效。",
        "token": refreshed,
        "name": user["name"],
        "devices_used": active_count,
        "devices_limit": user["max_devices"],
        "offline_until_utc": iso_utc(now + timedelta(days=OFFLINE_DAYS)),
    }


@app.post("/admin/users")
def admin_create_user(req: AdminCreateUserRequest, x_admin_token: Optional[str] = Header(default=None)):
    require_admin(x_admin_token)
    name = normalize_name(req.name)
    salt, code_hash = hash_code(req.code)
    now = iso_utc(utc_now())
    try:
        with db() as conn:
            cursor = conn.execute(
                """INSERT INTO users
                   (name, activation_salt, activation_hash, max_devices, active, created_at, updated_at)
                   VALUES (?, ?, ?, ?, 1, ?, ?)""",
                (name, salt, code_hash, req.max_devices, now, now),
            )
            user_id = cursor.lastrowid
    except sqlite3.IntegrityError:
        raise HTTPException(status_code=409, detail="user already exists")
    return {"success": True, "id": user_id, "name": name, "max_devices": req.max_devices}


@app.get("/admin/users")
def admin_list_users(x_admin_token: Optional[str] = Header(default=None)):
    require_admin(x_admin_token)
    with db() as conn:
        users = conn.execute(
            """SELECT u.id, u.name, u.max_devices, u.active, u.created_at,
                      SUM(CASE WHEN d.active = 1 THEN 1 ELSE 0 END) AS devices_used
               FROM users u
               LEFT JOIN devices d ON d.user_id = u.id
               GROUP BY u.id
               ORDER BY u.id DESC"""
        ).fetchall()
        result = []
        for user in users:
            devices = conn.execute(
                "SELECT device_id, device_name, active, first_bound_at, last_seen_at, app_version FROM devices WHERE user_id = ? ORDER BY id",
                (user["id"],),
            ).fetchall()
            result.append({
                "id": user["id"],
                "name": user["name"],
                "active": bool(user["active"]),
                "max_devices": user["max_devices"],
                "devices_used": user["devices_used"] or 0,
                "created_at": user["created_at"],
                "devices": [dict(row) for row in devices],
            })
    return {"success": True, "users": result}


@app.post("/admin/users/{user_id}/status")
def admin_set_status(user_id: int, req: AdminSetStatusRequest, x_admin_token: Optional[str] = Header(default=None)):
    require_admin(x_admin_token)
    with db() as conn:
        cursor = conn.execute(
            "UPDATE users SET active = ?, updated_at = ? WHERE id = ?",
            (1 if req.active else 0, iso_utc(utc_now()), user_id),
        )
        if cursor.rowcount == 0:
            raise HTTPException(status_code=404, detail="user not found")
    return {"success": True, "active": req.active}


@app.post("/admin/users/{user_id}/unbind")
def admin_unbind(user_id: int, req: AdminUnbindRequest, x_admin_token: Optional[str] = Header(default=None)):
    require_admin(x_admin_token)
    with db() as conn:
        cursor = conn.execute(
            "UPDATE devices SET active = 0, last_seen_at = ? WHERE user_id = ? AND device_id = ?",
            (iso_utc(utc_now()), user_id, req.device_id),
        )
        if cursor.rowcount == 0:
            raise HTTPException(status_code=404, detail="device not found")
    return {"success": True}


# Register CAD-100-specific optional modules after the core app, models and
# database helpers are fully initialized. The public multi-tool portal lives
# in its own repository and service.
import update_service  # noqa: E402,F401
import license_web_admin  # noqa: E402,F401
