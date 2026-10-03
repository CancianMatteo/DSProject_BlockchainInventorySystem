from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    app_env: str = "production"
    api_host: str = "0.0.0.0"
    api_port: int = 8000
    api_prefix: str = "/api/v1"
    tls_required: bool = True
    tls_certfile: str | None = "/certs/fullchain.pem"
    tls_keyfile: str | None = "/certs/privkey.pem"
    tls_ca_certs: str | None = None
    proxy_headers: bool = True
    forwarded_allow_ips: str | None = "127.0.0.1"

    db_path: str = "/data/bis.db"
    jwt_secret: str = "change-me-in-production"
    jwt_algorithm: str = "HS256"
    jwt_ttl_hours: int = 10

    server_sign_private_key: str | None = None
    server_sign_public_key: str | None = None

    smtp_host: str | None = None
    smtp_port: int = 465
    smtp_security: str = "auto"
    smtp_user: str | None = None
    smtp_pass: str | None = None
    smtp_from: str | None = None

    initial_admin_name: str = "System"
    initial_admin_surname: str = "Admin"
    initial_admin_email: str | None = None
    initial_admin_password: str | None = None
    security_alert_email: str = "security@example.com"
    password_reset_email_cooldown_seconds: int = 60
    password_reset_max_attempts_per_day: int = 10
    app_client_token: str | None = None

    log_level: str = "INFO"

    model_config = SettingsConfigDict(env_file=".env", env_file_encoding="utf-8", case_sensitive=False)


settings = Settings()
