//! device JWT を発行し、auth-worker `/device-data-proxy` 経由で rust-alc-api
//! (Cloud Run IAM lockdown 後) にアクセスするための helper。
//!
//! browser-render-rust はブラウザセッションを持たない無人 cron のため、
//! auth-worker の device-token 基盤 (ohishi-exp/smb-watch#1 Phase 2、
//! ippoan/auth-worker#333) を使う: `device_id`/`device_secret` (pairing 時に
//! 1 回発行、tenant に紐付け済み) を `POST /device/token` に渡し、短命
//! device JWT を得る。tenant は device record 由来で client からは
//! 指定できない (`X-Tenant-ID` の詐称防止、rust-alc-api#434 followup)。

use serde::Deserialize;

use crate::config::Config;

#[derive(Deserialize)]
struct DeviceTokenResponse {
    access_token: String,
}

/// `device_id` + `device_secret` を device JWT に交換する。
/// 呼び出し側 (dtakologs 送信等) が毎回 fresh に mint する想定 (TTL 1h、
/// 送信頻度は10分に1回程度なのでキャッシュしない)。
pub async fn mint_device_token(config: &Config) -> Result<String, String> {
    if config.auth_worker_url.is_empty() {
        return Err("AUTH_WORKER_URL not configured".to_string());
    }
    if config.device_id.is_empty() || config.device_secret.is_empty() {
        return Err("DEVICE_ID / DEVICE_SECRET not configured".to_string());
    }

    let url = format!(
        "{}/device/token",
        config.auth_worker_url.trim_end_matches('/')
    );

    let client = reqwest::Client::builder()
        .timeout(config.rest_send_timeout)
        .build()
        .map_err(|e| format!("Failed to build HTTP client: {}", e))?;

    let resp = client
        .post(&url)
        .json(&serde_json::json!({
            "device_id": config.device_id,
            "device_secret": config.device_secret,
        }))
        .send()
        .await
        .map_err(|e| format!("device/token request failed: {}", e))?;

    let status = resp.status();
    let text = resp
        .text()
        .await
        .map_err(|e| format!("Failed to read device/token response: {}", e))?;

    if !status.is_success() {
        return Err(format!("device/token returned {}: {}", status, text));
    }

    let body: DeviceTokenResponse = serde_json::from_str(&text)
        .map_err(|e| format!("Failed to parse device/token response: {} body={}", e, text))?;

    Ok(body.access_token)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;
    use wiremock::matchers::{body_json, method, path};
    use wiremock::{Mock, MockServer, ResponseTemplate};

    fn test_config(auth_worker_url: String) -> Config {
        Config {
            grpc_port: "50051".to_string(),
            http_port: "8080".to_string(),
            user_name: String::new(),
            comp_id: String::new(),
            user_pass: String::new(),
            browser_headless: true,
            browser_timeout: Duration::from_secs(60),
            browser_debug: false,
            vehicle_job_timeout: Duration::from_secs(240),
            sqlite_path: "./data/browser_render.db".to_string(),
            session_ttl: Duration::from_secs(600),
            cookie_ttl: Duration::from_secs(86400),
            rust_logi_url: String::new(),
            rust_logi_organization_id: String::new(),
            grpc_send_timeout: Duration::from_secs(30),
            auth_worker_url,
            device_id: "device-1".to_string(),
            device_secret: "secret-1".to_string(),
            rest_send_timeout: Duration::from_secs(5),
            log_format: crate::config::LogFormat::Text,
            log_file: None,
            log_dir: "./logs".to_string(),
            log_rotation: crate::config::LogRotation::Daily,
        }
    }

    #[tokio::test]
    async fn errors_when_auth_worker_url_unset() {
        let cfg = test_config(String::new());
        let err = mint_device_token(&cfg).await.unwrap_err();
        assert!(err.contains("AUTH_WORKER_URL"));
    }

    #[tokio::test]
    async fn errors_when_device_credentials_unset() {
        let mut cfg = test_config("https://auth.example".to_string());
        cfg.device_id = String::new();
        let err = mint_device_token(&cfg).await.unwrap_err();
        assert!(err.contains("DEVICE_ID"));
    }

    #[tokio::test]
    async fn mints_a_token_on_success() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/device/token"))
            .and(body_json(serde_json::json!({
                "device_id": "device-1",
                "device_secret": "secret-1",
            })))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "access_token": "fake.jwt.token",
                "token_type": "Bearer",
                "expires_in": 3600,
                "tenant_id": "tenant-1",
            })))
            .expect(1)
            .mount(&server)
            .await;

        let cfg = test_config(server.uri());
        let token = mint_device_token(&cfg).await.unwrap();
        assert_eq!(token, "fake.jwt.token");
    }

    #[tokio::test]
    async fn propagates_4xx_as_error() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/device/token"))
            .respond_with(ResponseTemplate::new(401).set_body_json(serde_json::json!({
                "error": "invalid_credential",
            })))
            .mount(&server)
            .await;

        let cfg = test_config(server.uri());
        let err = mint_device_token(&cfg).await.unwrap_err();
        assert!(err.contains("401"));
    }

    #[tokio::test]
    async fn errors_on_malformed_response_body() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/device/token"))
            .respond_with(ResponseTemplate::new(200).set_body_string("not json"))
            .mount(&server)
            .await;

        let cfg = test_config(server.uri());
        let err = mint_device_token(&cfg).await.unwrap_err();
        assert!(err.contains("Failed to parse"));
    }

    #[tokio::test]
    async fn errors_when_endpoint_unreachable() {
        // 未起動ポートに向けて接続エラーを起こす。
        let cfg = test_config("http://127.0.0.1:1".to_string());
        let err = mint_device_token(&cfg).await.unwrap_err();
        assert!(err.contains("request failed"));
    }
}
