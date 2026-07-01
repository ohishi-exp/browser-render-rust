# Browser Render Rust

Rust implementation of browser automation service for vehicle data extraction.

## Features

- **HTTP API**: RESTful endpoints for job management and data retrieval
- **gRPC API**: Optional Protocol Buffers-based API (requires `protoc`)
- **Browser Automation**: Headless Chrome/Chromium via chromiumoxide
- **SQLite Storage**: Session, cookie, and cache management
- **Job Queue**: Asynchronous background job processing

## Project Structure

```
src/
├── main.rs           # Entry point, CLI, server startup
├── config.rs         # Environment-based configuration
├── browser/
│   └── renderer.rs   # Browser automation (login, data extraction)
├── jobs/
│   └── manager.rs    # Async job queue management
├── server/
│   ├── http.rs       # Axum HTTP server
│   └── grpc.rs       # Tonic gRPC server (optional)
└── storage/
    └── sqlite.rs     # SQLite database operations
```

## Requirements

- Rust 1.70+
- Chrome/Chromium browser
- SQLite
- (Optional) protoc for gRPC support

## Build

```bash
# HTTP only (default)
cargo build --release

# With gRPC support (requires protoc)
cargo build --release --features grpc
```

## Configuration

Environment variables (or `.env` file):

| Variable | Default | Description |
|----------|---------|-------------|
| `HTTP_PORT` | 8080 | HTTP server port |
| `GRPC_PORT` | 50051 | gRPC server port |
| `USER_NAME` | - | Login username |
| `COMP_ID` | - | Company ID |
| `USER_PASS` | - | Login password |
| `BROWSER_HEADLESS` | true | Run browser headless |
| `BROWSER_DEBUG` | false | Enable debug logging |
| `SQLITE_PATH` | ./data/browser_render.db | Database path |
| `SESSION_TTL` | 10m | Session timeout |
| `COOKIE_TTL` | 24h | Cookie expiration |

### dtakologs 送信 (rust-alc-api、device JWT 経由)

Vehicle-fetch cron が取得したデータを rust-alc-api の `/api/dtako-logs/bulk` に送る際の設定。
rust-alc-api は Cloud Run IAM lockdown 下にあるため、auth-worker の `/device-data-proxy`
経由で **device JWT** で認証する (Refs rust-alc-api#434)。tenant は device pairing 時に
確定するのでここでは指定しない (X-Tenant-ID 詐称防止)。

| Variable | Default | Description |
|----------|---------|-------------|
| `AUTH_WORKER_URL` | - | auth-worker の URL (例: `https://auth.ippoan.org`)。未設定なら dtakologs 送信をスキップ |
| `DEVICE_ID` | - | device pairing で発行した device 識別子 |
| `DEVICE_SECRET` | - | device pairing で発行した secret (`/device/token` で短命 JWT に交換) |
| `REST_SEND_TIMEOUT` | 30s | dtakologs 送信の HTTP タイムアウト |

この 3 つ (`AUTH_WORKER_URL` / `DEVICE_ID` / `DEVICE_SECRET`) は **Provision device credential**
workflow が VPS の `.env` に自動投入する ([Deploy](#docker--deploy) 参照)。

## Usage

```bash
# Start HTTP server (default)
./browser-render

# With custom port
./browser-render --http-port 3000

# HTTP only
./browser-render --server http

# Both HTTP and gRPC (requires grpc feature)
./browser-render --server both
```

## API Endpoints

### HTTP

| Method | Path | Description |
|--------|------|-------------|
| GET | `/v1/vehicle/data` | Create data fetch job |
| GET | `/v1/job/{id}` | Get job status |
| GET | `/v1/jobs` | List all jobs |
| GET | `/v1/session/check?session_id=X` | Check session validity |
| DELETE | `/v1/session/clear?session_id=X` | Clear session |
| GET | `/health` | Health check |
| GET | `/metrics` | Server metrics |

### Example

```bash
# Create a job
curl http://localhost:8080/v1/vehicle/data
# Response: {"job_id":"uuid","status":"pending","message":"..."}

# Check job status
curl http://localhost:8080/v1/job/{job_id}

# Health check
curl http://localhost:8080/health
```

## Docker & Deploy

`main`(master) への merge で CI (`.github/workflows/ci.yml` の `deploy` job) が
Docker image を build → GHCR push → **Kagoya VPS** へ SSH で deploy する
(dtako-scraper と同じ VPS)。deploy 後に VPS 上で `/health` を叩いて確認する。

```bash
# 手動 fallback (要: 手元 docker + VPS への SSH 鍵)
KAGOYA_VPS_HOST="ubuntu@<vps-ip>" ./scripts/deploy.sh
```

### device credential の provision (dtakologs 送信の初期設定)

dtakologs 送信に必要な `AUTH_WORKER_URL` / `DEVICE_ID` / `DEVICE_SECRET` は、
**Provision device credential** workflow (`.github/workflows/provision-device.yml`、
手動 `workflow_dispatch`) が VPS の `/opt/browser-render/.env` に自動投入する。

- Actions → **Provision device credential** → Run workflow で `tenant_id` を入力して実行
- `INTERNAL_SHARED_SECRET` (ohishi-exp org secret、CI にだけ置く) で auth-worker
  `/device/pair-internal` を叩き、`device-dtako-ingest` role の credential を発行 →
  `.env` に upsert + 最新 image で再起動
- device credential は VPS ではなく tenant に紐付くので、新 VPS を立てた時や rotate 時に
  この workflow を 1 回叩けば済む (手動 curl/SSH 不要)
- **`.env` の他の変数 (`ETC_ACCOUNTS` / `SMTP_*` / `GHCR_TOKEN` 等) は触らない** —
  これらは host 境界の秘密として VPS の `.env` に残す (GitHub には置かない)。真っさらな
  新 VPS ではこれらを別途手動で `.env` に入れる必要がある

詳細は [CLAUDE.md](CLAUDE.md) を参照。

## License

MIT
