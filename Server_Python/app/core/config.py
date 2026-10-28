from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    app_env: str = "production"
    api_host: str = "0.0.0.0"
    api_port: int = 8000
    api_prefix: str = "/api/v1"

    db_path: str = "/data/bis.db"
    jwt_secret: str = "change-me-in-production"
    jwt_algorithm: str = "HS256"
    jwt_ttl_hours: int = 10

    server_sign_private_key: str | None = None
    server_sign_public_key: str | None = None
    node_id: str = "node_a"
    validator_private_key: str | None = None
    validator_public_keys: str = "{}"

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

    # Co-located Elixir consensus engine (simbehaviour forwarding target).
    elixir_host: str | None = None
    elixir_http_port: int = 4001
    block_transaction_threshold: int = 3
    block_trigger_interval_seconds: int = 10

    log_level: str = "INFO"

    model_config = SettingsConfigDict(env_file=".env", env_file_encoding="utf-8", case_sensitive=False)


settings = Settings()
