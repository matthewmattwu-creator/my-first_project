# CAD-100 License System v2

This branch adds a device-bound online license layer without moving DWG processing to the server.

## What is protected

- WPF startup requires a valid cached license or first-time activation.
- Activation uses `name + activation code`.
- The server enforces a per-user device limit (default: 2).
- A device is identified by a SHA-256 fingerprint derived from Windows MachineGuid and machine name.
- Cached licenses are encrypted with Windows DPAPI (`CurrentUser`).
- Server tokens are RSA-SHA256 signed and bound to the device id.
- Online validation refreshes the license and offline window.
- If the server is unreachable, a previously validated device can continue within the configured offline window (default: 7 days).
- `ScanAsync` and `ApplyAsync` receive a second authorization check at build time, so bypassing only the WPF login does not directly unlock the normal Core workflow.

## Server setup (Tencent Cloud / Ubuntu)

```bash
cd server
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
python generate_keys.py
```

Keep `server/keys/private_key.pem` only on the server. Never commit it.

Set an admin token and start the service:

```bash
export CAD100_ADMIN_TOKEN='replace-with-a-long-random-secret'
export CAD100_PRIVATE_KEY="$PWD/keys/private_key.pem"
export CAD100_LICENSE_DB="$PWD/license.db"
uvicorn license_server:app --host 127.0.0.1 --port 8000
```

Put Nginx in front of the service and expose HTTPS only. A recommended public origin is:

```text
https://auth.example.com
```

Health check:

```bash
curl https://auth.example.com/health
```

## Create a user

The admin API requires `X-Admin-Token`.

```bash
curl -X POST https://auth.example.com/admin/users \
  -H 'Content-Type: application/json' \
  -H 'X-Admin-Token: YOUR_ADMIN_TOKEN' \
  -d '{"name":"张三","code":"583921","max_devices":2}'
```

List users and bound devices:

```bash
curl https://auth.example.com/admin/users \
  -H 'X-Admin-Token: YOUR_ADMIN_TOKEN'
```

Disable a user:

```bash
curl -X POST https://auth.example.com/admin/users/1/status \
  -H 'Content-Type: application/json' \
  -H 'X-Admin-Token: YOUR_ADMIN_TOKEN' \
  -d '{"active":false}'
```

Unbind a device:

```bash
curl -X POST https://auth.example.com/admin/users/1/unbind \
  -H 'Content-Type: application/json' \
  -H 'X-Admin-Token: YOUR_ADMIN_TOKEN' \
  -d '{"device_id":"DEVICE_SHA256"}'
```

## Build the licensed Windows application

Copy only `public_key.xml` from the server to the Windows build machine. It is not secret.

```powershell
.\build.ps1 `
  -LicenseApiBaseUrl "https://auth.example.com" `
  -LicensePublicKeyPath "C:\secure-build\public_key.xml"
```

The public key is embedded into `CadProcessingCore.dll` during compilation. The private key is never included in the application.

The application output remains under:

```text
dist/CAD-100/
```

## API contract

### POST /api/v1/activate

Request:

```json
{
  "name": "张三",
  "code": "583921",
  "device_id": "...",
  "device_name": "DESKTOP-A",
  "app_version": "2.0.0"
}
```

The server verifies the user and activation code, checks the active device count, binds the device if capacity remains, and returns a signed device token.

### POST /api/v1/check

The client sends the signed token and current device id. The server verifies that both the user and device remain active, updates `last_seen_at`, and returns a refreshed signed token.

## Security boundaries

This raises the cost of casual copying and simple UI bypasses, but no fully local CAD application can be made impossible to reverse engineer. For stronger protection, progressively migrate sensitive processing rules out of plaintext `.ps1` / `.lsp` assets and into compiled code, and consider issuing short-lived job tickets for the most valuable processing operations.
