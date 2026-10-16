import base64
import hashlib
import hmac
import os
import sqlite3
import time
from collections import defaultdict, deque
from datetime import timedelta
from typing import Deque, Dict

from fastapi import HTTPException, Request
from fastapi.responses import HTMLResponse, JSONResponse, RedirectResponse
from pydantic import BaseModel, Field

from license_server import ADMIN_TOKEN, app, db, hash_code, iso_utc, normalize_name, utc_now
from update_service import publish_update_bytes, read_manifest

WEB_ADMIN_PASSWORD = os.getenv("CAD100_WEB_ADMIN_PASSWORD", "")
WEB_SESSION_TTL_HOURS = int(os.getenv("CAD100_WEB_SESSION_TTL_HOURS", "8"))
COOKIE_NAME = "cad100_manage_session"
LOGIN_WINDOW_SECONDS = 15 * 60
LOGIN_MAX_FAILURES = 8
_login_failures: Dict[str, Deque[float]] = defaultdict(deque)


class WebLoginRequest(BaseModel):
    password: str = Field(min_length=1, max_length=200)


class WebCreateUserRequest(BaseModel):
    name: str = Field(min_length=1, max_length=100)
    code: str = Field(min_length=1, max_length=100)
    max_devices: int = Field(default=2, ge=1, le=20)


def _session_secret() -> bytes:
    seed = os.getenv("CAD100_WEB_SESSION_SECRET", "") or ADMIN_TOKEN
    if not seed:
        raise HTTPException(status_code=503, detail="web session secret is not configured")
    return hashlib.sha256(("cad100-web-admin:" + seed).encode("utf-8")).digest()


def _make_session() -> str:
    expires = int(time.time()) + WEB_SESSION_TTL_HOURS * 3600
    message = str(expires).encode("ascii")
    signature = hmac.new(_session_secret(), message, hashlib.sha256).hexdigest()
    return f"{expires}.{signature}"


def _valid_session(request: Request) -> bool:
    value = request.cookies.get(COOKIE_NAME, "")
    try:
        expires_text, signature = value.split(".", 1)
        expires = int(expires_text)
    except (ValueError, TypeError):
        return False
    if expires < int(time.time()):
        return False
    expected = hmac.new(_session_secret(), expires_text.encode("ascii"), hashlib.sha256).hexdigest()
    return hmac.compare_digest(signature, expected)


def _require_web_admin(request: Request) -> None:
    if not _valid_session(request):
        raise HTTPException(status_code=401, detail="login required")


def _client_ip(request: Request) -> str:
    forwarded = request.headers.get("x-forwarded-for", "")
    if forwarded:
        return forwarded.split(",", 1)[0].strip()
    return request.client.host if request.client else "unknown"


def _prune_failures(ip: str) -> Deque[float]:
    now = time.time()
    failures = _login_failures[ip]
    while failures and now - failures[0] > LOGIN_WINDOW_SECONDS:
        failures.popleft()
    return failures


def _safe_device_id(value: str) -> str:
    if not value:
        return "—"
    if len(value) <= 20:
        return value
    return value[:10] + "…" + value[-8:]


def _overview_payload() -> dict:
    recent_cutoff = iso_utc(utc_now() - timedelta(hours=24))
    with db() as conn:
        totals = conn.execute(
            "SELECT COUNT(*) AS total_users, SUM(CASE WHEN active=1 THEN 1 ELSE 0 END) AS active_users FROM users"
        ).fetchone()
        device_totals = conn.execute(
            "SELECT SUM(CASE WHEN active=1 THEN 1 ELSE 0 END) AS bound_devices, "
            "SUM(CASE WHEN active=1 AND last_seen_at>=? THEN 1 ELSE 0 END) AS recent_devices FROM devices",
            (recent_cutoff,),
        ).fetchone()
        users = conn.execute(
            """SELECT u.id,u.name,u.max_devices,u.active,u.created_at,
                      SUM(CASE WHEN d.active=1 THEN 1 ELSE 0 END) AS devices_used
               FROM users u
               LEFT JOIN devices d ON d.user_id=u.id
               GROUP BY u.id
               ORDER BY u.id DESC"""
        ).fetchall()

        rows = []
        for user in users:
            devices = conn.execute(
                """SELECT device_id,device_name,active,first_bound_at,last_seen_at,app_version
                   FROM devices WHERE user_id=?
                   ORDER BY active DESC,last_seen_at DESC""",
                (user["id"],),
            ).fetchall()
            rows.append({
                "id": user["id"],
                "name": user["name"],
                "active": bool(user["active"]),
                "max_devices": user["max_devices"],
                "devices_used": user["devices_used"] or 0,
                "created_at": user["created_at"],
                "devices": [{
                    "device_id": _safe_device_id(d["device_id"]),
                    "device_name": d["device_name"] or "未命名电脑",
                    "active": bool(d["active"]),
                    "first_bound_at": d["first_bound_at"],
                    "last_seen_at": d["last_seen_at"],
                    "app_version": d["app_version"] or "—",
                } for d in devices],
            })

    return {
        "success": True,
        "generated_at": iso_utc(utc_now()),
        "stats": {
            "total_users": (totals["total_users"] or 0) if totals else 0,
            "active_users": (totals["active_users"] or 0) if totals else 0,
            "bound_devices": (device_totals["bound_devices"] or 0) if device_totals else 0,
            "recent_devices": (device_totals["recent_devices"] or 0) if device_totals else 0,
        },
        "users": rows,
        "release": read_manifest(),
    }


LOGIN_HTML = r'''<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>CAD-100 授权管理</title><style>
*{box-sizing:border-box}body{margin:0;background:#f5f5f7;color:#111;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI","PingFang SC","Microsoft YaHei",sans-serif}.wrap{min-height:100vh;display:flex;align-items:center;justify-content:center;padding:24px}.card{width:min(420px,100%);background:#fff;border:1px solid #e5e5e7;border-radius:24px;padding:34px;box-shadow:0 18px 60px rgba(0,0,0,.08)}.brand{font-size:13px;font-weight:700;letter-spacing:.12em;color:#777}.title{font-size:30px;font-weight:700;margin:10px 0 8px}.sub{font-size:14px;color:#777;line-height:1.7;margin-bottom:26px}input{width:100%;height:48px;border:1px solid #d7d7db;border-radius:12px;padding:0 14px;font-size:16px;outline:none}button{width:100%;height:48px;border:0;border-radius:12px;background:#111;color:#fff;font-size:15px;font-weight:650;margin-top:12px;cursor:pointer}.err{min-height:22px;margin-top:12px;color:#c62828;font-size:13px}.foot{margin-top:20px;font-size:12px;color:#999;text-align:center}</style></head>
<body><div class="wrap"><div class="card"><div class="brand">CAD-100</div><div class="title">授权管理后台</div><div class="sub">管理授权用户、设备绑定和软件版本发布。</div><form id="loginForm"><input id="password" type="password" placeholder="管理密码" autofocus><button id="loginBtn" type="submit">进入后台</button><div id="loginError" class="err"></div></form><div class="foot">HTTPS · 授权与版本管理</div></div></div>
<script>
const $=id=>document.getElementById(id);
$('loginForm').addEventListener('submit',async e=>{e.preventDefault();$('loginError').textContent='';$('loginBtn').disabled=true;try{const r=await fetch('/manage/login',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({password:$('password').value})});const j=await r.json().catch(()=>({}));if(!r.ok)throw new Error(j.detail||'登录失败');location.href='/manage/';}catch(x){$('loginError').textContent=x.message||'登录失败';}finally{$('loginBtn').disabled=false;}});
</script></body></html>'''


DASHBOARD_HTML = r'''<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>CAD-100 管理后台</title>
<style>
*{box-sizing:border-box}body{margin:0;background:#f5f5f7;color:#111;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI","PingFang SC","Microsoft YaHei",sans-serif}.shell{max-width:1280px;margin:auto;padding:32px 22px 70px}.top{display:flex;justify-content:space-between;align-items:flex-end;gap:16px;margin-bottom:24px}.brand{font-size:12px;font-weight:800;letter-spacing:.14em;color:#777}.title{font-size:32px;font-weight:750;margin-top:5px}.actions{display:flex;gap:9px;align-items:center}.btn,.primary{border:1px solid #d7d7da;background:#fff;border-radius:10px;height:40px;padding:0 14px;cursor:pointer}.primary{background:#111;color:#fff;border:0;font-weight:650}.muted{font-size:12px;color:#888}.stats{display:grid;grid-template-columns:repeat(4,1fr);gap:13px;margin-bottom:22px}.card,.stat,.user{background:#fff;border:1px solid #e5e5e7;border-radius:18px}.stat{padding:19px}.stat .n{font-size:31px;font-weight:750}.stat .l{font-size:12px;color:#777;margin-top:6px}.card{padding:20px;margin-bottom:20px}.cardtitle{font-size:17px;font-weight:700}.cardsub{font-size:12px;color:#888;margin:5px 0 16px}.grid{display:grid;grid-template-columns:1.3fr 1.3fr .65fr auto;gap:11px;align-items:end}.releasegrid{display:grid;grid-template-columns:.7fr 1fr 1.6fr;gap:11px}.field label{display:block;font-size:12px;color:#777;margin-bottom:6px}.field input,.field textarea{width:100%;border:1px solid #d7d7db;border-radius:10px;padding:0 11px;font:inherit;background:#fff}.field input{height:42px}.field textarea{height:82px;padding-top:10px;resize:vertical}.check{display:flex;gap:7px;align-items:center;font-size:12px;color:#666;margin-top:10px}.check input{width:auto;height:auto}.msg{min-height:19px;font-size:12px;margin-top:9px}.ok{color:#237a36}.bad{color:#b42318}.errorbox{display:none;background:#fff1f0;color:#a8071a;border:1px solid #ffccc7;border-radius:12px;padding:12px 14px;margin-bottom:16px;font-size:13px}.section{font-size:18px;font-weight:700;margin:27px 0 11px}.user{overflow:hidden;margin-bottom:12px}.userhead{display:flex;justify-content:space-between;align-items:center;padding:17px 19px;border-bottom:1px solid #eee}.username{font-size:19px;font-weight:750}.meta{font-size:12px;color:#888;margin-top:5px}.chip{display:inline-block;border-radius:999px;padding:5px 9px;font-size:11px;background:#edf8ef;color:#237a36}.off{background:#f1f1f2;color:#777}.tablewrap{overflow:auto}.devices{width:100%;border-collapse:collapse;min-width:900px}.devices th,.devices td{text-align:left;padding:11px 14px;border-bottom:1px solid #f0f0f0;font-size:12px;white-space:nowrap}.devices th{background:#fafafa;color:#888;font-size:11px}.empty{padding:16px;color:#999;font-size:12px}.releaseNow{padding:13px;border-radius:12px;background:#f7f7f8;font-size:13px;margin-bottom:14px;line-height:1.6}@media(max-width:900px){.stats{grid-template-columns:1fr 1fr}.grid,.releasegrid{grid-template-columns:1fr 1fr}.top{align-items:flex-start;flex-direction:column}}@media(max-width:560px){.grid,.releasegrid{grid-template-columns:1fr}.shell{padding:22px 13px 50px}}
</style></head><body><div class="shell">
<div class="top"><div><div class="brand">CAD-100</div><div class="title">管理后台</div></div><div class="actions"><span id="updated" class="muted"></span><button id="refreshBtn" class="btn">刷新</button><button id="logoutBtn" class="btn">退出</button></div></div>
<div id="pageError" class="errorbox"></div>
<div class="stats"><div class="stat"><div id="totalUsers" class="n">—</div><div class="l">总用户</div></div><div class="stat"><div id="activeUsers" class="n">—</div><div class="l">启用用户</div></div><div class="stat"><div id="boundDevices" class="n">—</div><div class="l">当前绑定设备</div></div><div class="stat"><div id="recentDevices" class="n">—</div><div class="l">近 24 小时在线</div></div></div>
<div class="card"><div class="cardtitle">新增授权用户</div><div class="cardsub">默认用户名 = 激活码，每人最多绑定 2 台电脑。</div><form id="createForm"><div class="grid"><div class="field"><label>用户名 / 姓名</label><input id="newName" required></div><div class="field"><label>激活码</label><input id="newCode" placeholder="默认与姓名相同" disabled><div class="check"><input id="sameCode" type="checkbox" checked><label for="sameCode">与姓名相同</label></div></div><div class="field"><label>设备上限</label><input id="newLimit" type="number" min="1" max="20" value="2"></div><button id="createBtn" class="primary" type="submit">新增授权</button></div><div id="createMsg" class="msg"></div></form></div>
<div class="card"><div class="cardtitle">版本管理 / 发布更新</div><div class="cardsub">上传 GitHub 构建出的完整 ZIP。客户端启动后会自动检查版本并允许一键更新。</div><div id="releaseNow" class="releaseNow">当前尚未发布自动更新版本。</div><form id="releaseForm"><div class="releasegrid"><div class="field"><label>版本号</label><input id="releaseVersion" placeholder="例如 2.1.0" required></div><div class="field"><label>完整更新 ZIP</label><input id="releaseFile" type="file" accept=".zip,application/zip" required></div><div class="field"><label>更新说明</label><textarea id="releaseNotes" placeholder="本次更新内容"></textarea></div></div><div class="check"><input id="releaseRequired" type="checkbox"><label for="releaseRequired">强制更新（用户不能选择稍后更新）</label></div><button id="releaseBtn" class="primary" type="submit">发布新版本</button><div id="releaseMsg" class="msg"></div></form></div>
<div class="section">授权用户与设备</div><div id="users"></div></div>
<script>
const $=id=>document.getElementById(id);
const esc=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const dt=v=>{if(!v)return'—';const d=new Date(v);return Number.isNaN(d.getTime())?esc(v):d.toLocaleString('zh-CN',{hour12:false});};
function showPageError(message){$('pageError').textContent=message||'读取后台数据失败。';$('pageError').style.display='block';}
function clearPageError(){$('pageError').style.display='none';$('pageError').textContent='';}
function renderUser(u){const rows=(u.devices||[]).map(d=>`<tr><td><b>${esc(u.name)}</b></td><td>${esc(d.device_name)}</td><td>${esc(d.device_id)}</td><td>${esc(d.app_version)}</td><td>${dt(d.last_seen_at)}</td><td>${d.active?'<span class="chip">绑定中</span>':'<span class="chip off">已解绑</span>'}</td></tr>`).join('');return `<div class="user"><div class="userhead"><div><div class="username">${esc(u.name)}</div><div class="meta">用户 #${u.id} · 已绑定 ${u.devices_used}/${u.max_devices} 台 · 创建于 ${dt(u.created_at)}</div></div>${u.active?'<span class="chip">已启用</span>':'<span class="chip off">已停用</span>'}</div>${rows?`<div class="tablewrap"><table class="devices"><thead><tr><th>授权用户名</th><th>设备名</th><th>设备 ID</th><th>版本</th><th>最后在线</th><th>状态</th></tr></thead><tbody>${rows}</tbody></table></div>`:'<div class="empty">尚未绑定设备</div>'}</div>`;}
async function loadData(){clearPageError();try{const r=await fetch('/manage/api/overview',{cache:'no-store'});if(r.status===401){location.href='/manage/';return;}const j=await r.json().catch(()=>({}));if(!r.ok||!j.stats)throw new Error(j.detail||'后台数据接口返回异常。');$('totalUsers').textContent=j.stats.total_users;$('activeUsers').textContent=j.stats.active_users;$('boundDevices').textContent=j.stats.bound_devices;$('recentDevices').textContent=j.stats.recent_devices;$('updated').textContent='更新 '+dt(j.generated_at);$('users').innerHTML=(j.users||[]).map(renderUser).join('')||'<div class="empty">暂无用户</div>';const q=j.release;$('releaseNow').innerHTML=q?`当前正式版 <b>${esc(q.version)}</b> · ${q.required?'强制更新':'普通更新'} · ${Math.round((q.size||0)/1024/1024*10)/10} MB<br>${esc(q.notes||'无更新说明')}<br><span class="muted">发布于 ${dt(q.published_at)}</span>`:'当前尚未发布自动更新版本。';}catch(x){showPageError(x.message||'读取后台数据失败。');}}
$('refreshBtn').addEventListener('click',loadData);
$('logoutBtn').addEventListener('click',async()=>{await fetch('/manage/logout',{method:'POST'});location.href='/manage/';});
$('sameCode').addEventListener('change',()=>{$('newCode').disabled=$('sameCode').checked;if(!$('sameCode').checked)$('newCode').focus();});
$('createForm').addEventListener('submit',async e=>{e.preventDefault();$('createBtn').disabled=true;$('createMsg').textContent='';const name=$('newName').value.trim();const code=$('sameCode').checked?name:$('newCode').value.trim();try{const r=await fetch('/manage/api/users',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({name,code,max_devices:Number($('newLimit').value)})});const j=await r.json().catch(()=>({}));if(!r.ok)throw new Error(j.detail||'新增失败');$('createMsg').className='msg ok';$('createMsg').textContent='已新增 '+j.name;$('newName').value='';$('newCode').value='';$('newLimit').value='2';await loadData();}catch(x){$('createMsg').className='msg bad';$('createMsg').textContent=x.message||'新增失败';}finally{$('createBtn').disabled=false;}});
$('releaseForm').addEventListener('submit',async e=>{e.preventDefault();const file=$('releaseFile').files[0];if(!file)return;$('releaseBtn').disabled=true;$('releaseMsg').className='msg';$('releaseMsg').textContent='正在上传并发布，请不要关闭页面…';try{const notesBytes=new TextEncoder().encode($('releaseNotes').value);let binary='';notesBytes.forEach(b=>binary+=String.fromCharCode(b));const notes64=btoa(binary);const r=await fetch('/manage/api/update/publish',{method:'POST',headers:{'X-CAD100-Version':$('releaseVersion').value.trim(),'X-CAD100-Required':$('releaseRequired').checked?'1':'0','X-CAD100-Notes-B64':notes64,'Content-Type':'application/zip'},body:file});const j=await r.json().catch(()=>({}));if(!r.ok)throw new Error(j.detail||'发布失败');$('releaseMsg').className='msg ok';$('releaseMsg').textContent='版本 '+j.version+' 发布成功。';$('releaseFile').value='';await loadData();}catch(x){$('releaseMsg').className='msg bad';$('releaseMsg').textContent=x.message||'发布失败';}finally{$('releaseBtn').disabled=false;}});
loadData();setInterval(loadData,30000);
</script></body></html>'''


@app.get("/manage")
def manage_redirect():
    return RedirectResponse(url="/manage/", status_code=307)


@app.get("/manage/", response_class=HTMLResponse)
def manage_home(request: Request):
    if not _valid_session(request):
        return HTMLResponse(LOGIN_HTML, headers={"Cache-Control": "no-store"})
    return HTMLResponse(DASHBOARD_HTML, headers={"Cache-Control": "no-store"})


@app.post("/manage/login")
def manage_login(req: WebLoginRequest, request: Request):
    if not WEB_ADMIN_PASSWORD:
        raise HTTPException(status_code=503, detail="后台管理密码尚未配置。")
    ip = _client_ip(request)
    failures = _prune_failures(ip)
    if len(failures) >= LOGIN_MAX_FAILURES:
        raise HTTPException(status_code=429, detail="尝试次数过多，请稍后再试。")
    if not hmac.compare_digest(req.password, WEB_ADMIN_PASSWORD):
        failures.append(time.time())
        raise HTTPException(status_code=401, detail="密码不正确。")
    failures.clear()
    response = JSONResponse({"success": True})
    response.set_cookie(
        COOKIE_NAME,
        _make_session(),
        max_age=WEB_SESSION_TTL_HOURS * 3600,
        httponly=True,
        secure=True,
        samesite="strict",
        path="/manage",
    )
    return response


@app.post("/manage/logout")
def manage_logout():
    response = JSONResponse({"success": True})
    response.delete_cookie(COOKIE_NAME, path="/manage")
    return response


@app.get("/manage/api/overview")
def manage_overview(request: Request):
    _require_web_admin(request)
    response = JSONResponse(_overview_payload())
    response.headers["Cache-Control"] = "no-store"
    return response


@app.post("/manage/api/users")
def manage_create_user(req: WebCreateUserRequest, request: Request):
    _require_web_admin(request)
    name = normalize_name(req.name)
    code = req.code.strip()
    if not name:
        raise HTTPException(status_code=400, detail="用户名不能为空。")
    if not code:
        raise HTTPException(status_code=400, detail="激活码不能为空。")
    salt, code_hash = hash_code(code)
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
        raise HTTPException(status_code=409, detail="该用户名已经存在。")
    return {"success": True, "id": user_id, "name": name, "max_devices": req.max_devices}


@app.post("/manage/api/update/publish")
async def manage_publish_update(request: Request):
    _require_web_admin(request)
    version = (request.headers.get("x-cad100-version") or "").strip()
    required = (request.headers.get("x-cad100-required") or "0").strip() == "1"
    notes_b64 = (request.headers.get("x-cad100-notes-b64") or "").strip()
    try:
        notes = base64.b64decode(notes_b64).decode("utf-8") if notes_b64 else ""
    except Exception:
        raise HTTPException(status_code=400, detail="更新说明编码错误。")
    content = await request.body()
    manifest = publish_update_bytes(version, notes, required, content)
    result = dict(manifest)
    result["success"] = True
    return result
