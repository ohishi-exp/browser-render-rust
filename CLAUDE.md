# CLAUDE.md

## Project Overview

Browser Render Rust - GoプロジェクトからのRust移植版。ブラウザ自動化によるVehicleデータ取得とHono API連携サービス。

## Build & Run

```bash
cargo build --release          # リリースビルド
cargo run -- --server http     # HTTPサーバー起動
```

## 運用上の注意 (禁止・必須事項)

- `.env` の `ETC_ACCOUNTS` にシングルクォートを使わないこと。Dockerがクォートを値の一部として
  解釈し、JSONパースエラーになる。
- `deploy` job の `concurrency: deploy-kagoya-vps` (cancel-in-progress: false) は外さないこと。
  連続 push で同じ VPS の同じコンテナ名を取り合うレースを防いでいる。
- `INTERNAL_SHARED_SECRET` (ohishi-exp org secret) は **CI にだけ置き、VPS には配らない**こと。
- `ETC_ACCOUNTS` / `ETC_DOWNLOAD_PATH` / `SMTP_*` / `GHCR_TOKEN` / `VEHICLE_JOB_TIMEOUT` 等は
  **host 境界の秘密として VPS の `.env` に残す** (GitHub には置かない)。真っさらな新 VPS では
  これらが存在しないため `.env` を別途手動でセットアップする必要がある。

詳細 (API endpoint 一覧・ログ設定・テスト・Docker/Kagoya VPS デプロイ手順・
device credential provision・動画通知トラブルシュート記録等) は
`browser-render-rust-map` skill を参照。
