---
name: browser-render-rust-map
generated-from: browser-render-rust:1acb4820a06a3a95deeea27e95b3b927dea3232e
paths: [src/, rust-scraper/]
description: Browser Render Rust (Go からの Rust 移植、ブラウザ自動化による Vehicle データ取得 + ETC 明細スクレイプ + Hono API 連携サービス) の構造ナビゲーション。API endpoint 一覧、ログ設定、Docker/Kagoya VPS 自動デプロイ、device credential provision、動画通知(Monitoring_DvrNotification2)解決記録などの詳細をまとめる。トリガー:「browser-render-rust」「vehicle data」「ETC scrape」「Kagoya VPS deploy」「device credential provision」「Monitoring_DvrNotification2」「dtakologs」等。
---

## Build & Run

```bash
# ビルド
cargo build                    # 開発
cargo build --release          # リリース
cargo build --features grpc    # gRPC機能付き

# 実行
cargo run -- --server http     # HTTPサーバー
cargo run -- --http-port 3000  # カスタムポート
cargo run -- --debug           # デバッグモード
```

## ログ設定

```bash
# JSON形式でファイル出力（本番環境推奨）
cargo run -- --log-format json --log-file app.log

# モジュール別ログレベル制御
RUST_LOG=browser_render::browser=debug,info cargo run
```

| CLI引数 | 環境変数 | デフォルト | 説明 |
|---------|----------|------------|------|
| `--log-format` | `LOG_FORMAT` | `text` | `text` / `json` |
| `--log-file` | `LOG_FILE` | (なし) | ファイル出力有効化 |
| `--log-dir` | `LOG_DIR` | `./logs` | ログディレクトリ |
| `--log-rotation` | `LOG_ROTATION` | `daily` | `daily` / `hourly` / `never` |
| - | `RUST_LOG` | (なし) | モジュール別レベル制御 |

## テスト

```bash
# 統合テスト（認証情報は.envから、順次実行必須）
cargo test --test browser_integration_test -- --ignored --nocapture --test-threads=1

# モックサーバー単体テスト
cargo test --test browser_integration_test test_mock_server_standalone -- --nocapture
```

## API Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/v1/vehicle/data` | GET | Vehicleデータ取得ジョブ作成 |
| `/v1/etc/scrape` | POST | ETC明細スクレイプ（即時実行） |
| `/v1/etc/scrape/queue` | POST | ETC明細スクレイプ（idle時実行） |
| `/v1/etc/scrape/batch` | POST | ETC明細スクレイプ（複数アカウント、即時実行） |
| `/v1/etc/scrape/batch/queue` | POST | ETC明細スクレイプ（複数アカウント、idle時実行） |
| `/v1/etc/scrape/batch/env` | POST | ETC明細スクレイプ（環境変数からアカウント取得、即時実行） |
| `/v1/etc/scrape/batch/env/queue` | POST | ETC明細スクレイプ（環境変数からアカウント取得、idle時実行） |
| `/v1/job/:id` | GET | ジョブステータス確認 |
| `/v1/jobs` | GET | 全ジョブ一覧 |
| `/v1/jobs/queue` | GET | キュー状態確認 |
| `/health` | GET | ヘルスチェック（環境変数設定状況も返す） |

### Health Response
```json
{
  "status": "healthy",
  "version": "1.0.0",
  "uptime": 118.78,
  "env": {
    "etc_accounts": true,
    "etc_download_path": "./downloads"
  }
}
```
- `etc_accounts`: `ETC_ACCOUNTS`が設定されているか（`true`/`false`）
- `etc_download_path`: `ETC_DOWNLOAD_PATH`の値（未設定時は`null`）

### ETC Scrape Request Body（単一アカウント）
```json
{
  "user_id": "xxx",
  "password": "xxx",
  "download_path": "./downloads",
  "headless": true
}
```

### ETC Batch Scrape Request Body（複数アカウント）
```json
{
  "accounts": [
    {"user_id": "user1", "password": "pass1"},
    {"user_id": "user2", "password": "pass2"}
  ],
  "download_path": "./downloads",
  "headless": true
}
```

### 環境変数でのアカウント設定

| 環境変数 | 説明 | 例 |
|----------|------|-----|
| `ETC_ACCOUNTS` | アカウント情報（JSON配列） | `[{"user_id":"u1","password":"p1"}]` |
| `ETC_DOWNLOAD_PATH` | ダウンロード先パス | `/data/downloads` |
| `VEHICLE_JOB_TIMEOUT` | Vehicleジョブ全体タイムアウト（デフォルト: 240s） | `240s` |

```bash
# .envファイル例（注意: シングルクォートは使わない）
ETC_ACCOUNTS=[{"user_id":"user1","password":"pass1"},{"user_id":"user2","password":"pass2"}]
ETC_DOWNLOAD_PATH=/data/etc-downloads
```

> **重要**: `ETC_ACCOUNTS`にシングルクォートを使うと、Dockerがクォートを値の一部として解釈し、JSONパースエラーになる。

### 環境変数バッチエンドポイント
リクエストボディはオプション（download_path/headlessの上書き用）：
```bash
# 環境変数のみで実行
curl -X POST http://localhost:8080/v1/etc/scrape/batch/env

# download_pathを上書き
curl -X POST http://localhost:8080/v1/etc/scrape/batch/env \
  -H "Content-Type: application/json" \
  -d '{"download_path": "/custom/path"}'
```

**バッチ処理の特徴：**
- 複数アカウントを1ジョブで順次処理
- セッションフォルダ（YYYYMMDD_HHMMSS形式）に全CSVを保存
- アカウントごとの進捗・ステータスを個別追跡
- 1つでも失敗→ジョブ全体はFailed（ただし成功分のCSVは保存済み）
- **自動クリーンアップ**: 古いセッションフォルダを自動削除（最新10個を保持）

## Architecture

- **axum**: HTTP framework
- **chromiumoxide**: Browser automation
- **sqlx**: Async SQLite
- **tokio**: Async runtime
- **tonic** (optional): gRPC (`--features grpc`)
- **scraper-service**: ETC明細スクレイパー（workspace member）

## Docker & Deploy

### 自動デプロイ (CI → Kagoya VPS)

`master` への merge (push) で `ci.yml` の `deploy` job が Docker image を build →
GHCR push → **Kagoya VPS** へ直接 SSH で deploy する (dtako-scraper と同じ VPS)。
deploy 後に VPS 上で `/health` を叩いて疎通確認し、失敗すれば loud fail する。

- build/push は deploy job、実 deploy (pull + restart + health check) ロジックは
  `scripts/deploy-remote.sh` に切り出して共有 (CI / 手動 fallback 両用)
- `deploy` job には `concurrency: deploy-kagoya-vps` (cancel-in-progress: false) を
  張り、連続 push で同じ VPS の同じコンテナ名を取り合うレースを防ぐ
- 必要な secret: `KAGOYA_VPS_SSH_KEY` / `KAGOYA_VPS_HOST` (ohishi-exp org secret、
  dtako-scraper と共有)。VPS 側 docker pull は job 限りの `GITHUB_TOKEN` を SSH 越しに
  渡して認証する (VPS の静的 `.env` GHCR_TOKEN は旧 namespace 用の fallback)

```bash
# 手動 fallback (要: 手元 docker + VPS への SSH 鍵)
KAGOYA_VPS_HOST="ubuntu@<vps-ip>" ./scripts/deploy.sh
```

### device credential の provision (dtakologs 送信の初期設定)

dtakologs (rust-alc-api `/api/dtako-logs/bulk`) 送信は Cloud Run IAM lockdown 下の
rust-alc-api に対し auth-worker の `/device-data-proxy` 経由で **device JWT** 認証する
(Refs rust-alc-api#434)。必要な env (`AUTH_WORKER_URL` / `DEVICE_ID` / `DEVICE_SECRET`) は
**Provision device credential** workflow (`.github/workflows/provision-device.yml`、
手動 `workflow_dispatch`) が VPS の `.env` に自動投入する。

- Actions → **Provision device credential** → Run workflow で `tenant_id` を入力して実行
- `INTERNAL_SHARED_SECRET` (ohishi-exp org secret、**CI にだけ置く。VPS には配らない**) で
  auth-worker `/device/pair-internal` を叩き、tenant + `device-dtako-ingest` role
  (= `/api/dtako-logs/bulk` だけ) にスコープした credential を発行 → `deploy-remote.sh`
  経由で `.env` に upsert + 最新 image で再起動
- device credential は VPS ではなく tenant に紐付くので、新 VPS / rotate 時にこの workflow を
  1 回叩けば済む (手動 curl/SSH 不要)。`device_secret` は生成直後に `::add-mask::` し、
  SSH env-var 前置き経路でのみ VPS に渡してログに出さない

### `.env` の扱い (host 境界の秘密は CI で触らない)

`deploy-remote.sh` の `upsert_env` は `AUTH_WORKER_URL` / `DEVICE_ID` / `DEVICE_SECRET` の
**3 行だけ**を差し替え、他の行は保持する (通常 deploy は値を渡さないので `.env` を触らない)。

- `ETC_ACCOUNTS` / `ETC_DOWNLOAD_PATH` / `SMTP_*` / `GHCR_TOKEN` / `VEHICLE_JOB_TIMEOUT` 等は
  **host 境界の秘密として VPS の `.env` に残す** (GitHub には置かない、dtako-scraper / smb-watch
  と同方針)
- **真っさらな新 VPS** ではこれらが存在しないので、`.env` を別途手動でセットアップする必要がある
  (provision workflow が面倒を見るのは device 認証の 3 つだけ)

### Docker設定
- `--network host`: ポート公開なし、localhost:8080でアクセス可能
- `--shm-size=2g`: Chromium用共有メモリ
- chromedp/headless-shellベースイメージ使用

### Cron設定（GCE上）

両方とも失敗時にメール通知するスクリプトを使用。

**Vehicleデータ取得（10分おき）:**
```bash
# /etc/cron.d/vehicle-fetch
*/10 * * * * root /opt/browser-render/scripts/vehicle-fetch.sh
```
- スクリプト: [scripts/vehicle-fetch.sh](scripts/vehicle-fetch.sh)（GCE上にコピー済み）
- ログ: `/opt/browser-render/logs/vehicle-cron.log`
- 失敗時: メール通知

**ETC明細バッチスクレイプ（UTC 21,22,23,0時 = JST 6,7,8,9時）:**
```bash
# /etc/cron.d/etc-scrape-batch-env
0 21,22,23,0 * * * root /opt/browser-render/scripts/etc-scrape-batch.sh
```
- スクリプト: [scripts/etc-scrape-batch.sh](scripts/etc-scrape-batch.sh)（GCE上にコピー済み）
- ログ: `/opt/browser-render/logs/etc-cron.log`
- 失敗時: メール通知
- 環境変数`ETC_ACCOUNTS`からアカウント情報を取得

### ヘルスチェック
```bash
gcloud compute ssh instance-20251207-115015 --zone=asia-northeast1-b --command="curl -sf http://localhost:8080/health"
```

## TODO

- [x] 実環境でのテスト
- [x] エラーハンドリングの改善
- [x] ログ出力の最適化
- [x] Docker + GCE自動デプロイ
- [x] ETC明細スクレイパー統合
- [x] ETC複数アカウントバッチ処理
- [x] 動画通知機能（Monitoring_DvrNotification2）の修正
- [x] ETC batch scrape cron失敗通知
- [ ] メトリクス追加

---

## 動画通知機能 - 解決済み (2026-01-25)

### 問題の原因
`Monitoring_DvrNotification2` の呼び出し引数が間違っていた。

**間違い:**
```javascript
VenusBridgeService.Monitoring_DvrNotification2(callback);  // 引数1つ
```

**正しい形式:**
```javascript
// sort引数形式: "fieldName,dir,pageIndex,pageSize"
const sort = ",," + "0" + "," + "100";
VenusBridgeService.Monitoring_DvrNotification2(sort, callback);  // 引数2つ
```

### 修正内容
- [rust-scraper/src/dtakolog/scraper.rs](rust-scraper/src/dtakolog/scraper.rs) L913-917
- sort引数を追加: `const sort = ",," + "0" + "," + "100";`

### テスト結果
- 修正前: 60秒タイムアウト、コールバック発火せず
- 修正後: 500msで結果受信、正常動作

### テスト用コード
小さなテストコードを作成済み:
```bash
# 素早いテスト実行
cargo run -p scraper-service --example dvr_test
```
- [rust-scraper/examples/dvr_test.rs](rust-scraper/examples/dvr_test.rs)

### 本番確認済み (2026-01-25 14:27 JST)
```
DVR API call status: initiated
DVR result received after 500ms
```
GCEデプロイ後、`/v1/vehicle/data`リクエストで動画通知機能が正常動作することを確認。

---

## 引き継ぎサマリー (2026-01-26)

### 完了した作業
1. **Monitoring_DvrNotification2の修正** - sort引数追加で解決
2. **dvr_test.rs作成** - 素早いテスト用exampleファイル
3. **GCEデプロイ・動作確認完了**
4. **ETC batch scrape cron失敗通知** - `etc-scrape-batch.sh`スクリプト追加
5. **`.env`のETC_ACCOUNTSシングルクォート問題修正**

### 現在の状態
- 動画通知機能: **正常動作**
- ETC batch scrape: **正常動作**（失敗時メール通知あり）
- 全ての主要機能が稼働中

### 残タスク
- [ ] メトリクス追加（TODO参照）
