# Blueprint: Backend for Blockchain Inventory System (BIS)

## 1. Objective and Scope

This backend is the controller and authoritative model layer for the BIS Flutter client.

Design goals:
- REST API over HTTP.
- Stateless request handling with signed session tokens.
- Deterministic blockchain validation and append-only chain persistence.
- Fast inventory reads through in-memory cache (rebuildable from chain).
- Dockerized deployment.
- Explicit error and exception handling on every endpoint.

Suggested stack:
- Python 3.12
- FastAPI + Uvicorn
- SQLite (single-node baseline) via SQLAlchemy
- Pydantic for request/response validation
- PyJWT for session tokens
- Passlib (argon2id) for password hashing
- cryptography (Ed25519) for block signatures

---

## 2. High-Level Architecture

Layers:
1. API layer (FastAPI routers)
2. Controller/services layer (auth, users, chain, inventory cache)
3. Model/repository layer (SQLite CRUD + transactions)
4. Security layer (JWT, password hash verification, request guards)

Runtime components:
- API process receives client requests.
- Auth service verifies credentials and session tokens.
- Chain service validates and appends new blocks.
- Sync service resolves client divergence and returns missing blocks.
- Inventory cache keeps current quantities in memory.

Data authority:
- Source of truth: `chain` table.
- Derived state: `inventory_cache` dictionary in memory, rebuilt at startup from chain.

---

## 3. API Contract (REST)

Base path: `/api/v1`

Transport notes:
- The client and backend communicate over unencrypted HTTP; credentials and API data are visible to network observers, so deployments should be restricted to trusted networks.
- Backend listens on the configured API port (default `8000`).

### 3.1 POST /auth/login

Purpose:
- Authenticate user and return session token.

Request:
```json
{
	"email": "user@example.com",
	"pwd": "plain_or_client_hashed_password"
}
```

Controller flow:
1. Validate payload fields.
2. Query `users` by email.
3. If user not found or disabled -> auth error.
4. Verify password hash against stored hash.
5. Generate JWT session token with claims (`sub`, `role`, `exp`, `jti`).
6. Return token + profile summary.

Response 200:
```json
{
	"ok": true,
	"session_token": "...",
	"user": {
		"name": "Mario",
		"surname": "Rossi",
		"email": "user@example.com",
		"role": "admin"
	}
}
```

Errors:
- 400 invalid payload
- 401 invalid credentials
- 403 disabled account
- 500 internal error

Note:
- Passwords are hashed server-side with argon2id. HTTP is unencrypted, so credentials are exposed to network observers.

### 3.1.1 POST /auth/forgot_pwd

Purpose:
- Start password reset by generating and emailing an OTP to a valid active user.

Request:
```json
{
	"email": "user@example.com"
}
```

Controller flow:
1. Validate `email` and ensure user exists and is active.
2. Enforce server-side cooldown: max one OTP email per user email every 60 seconds.
3. Generate OTP and store only hashed OTP server-side.
4. Set OTP expiration to 15 minutes.
5. Send OTP to the same user email.

Headers:
- Optional hardening: require `X-App-Token` and validate it server-side.

Response 200:
```json
{
	"ok": true,
	"message": "If the account exists, an OTP has been sent",
	"otp_valid_minutes": 15
}
```

Errors:
- 200 generic response is returned even when account does not exist, is inactive, or cooldown is active
- 502 email delivery failure

### 3.1.2 POST /auth/reset_login_with_otp

Purpose:
- Complete password reset using OTP, with strict anti-abuse limits.

Request:
```json
{
	"email": "user@example.com",
	"otp": "123456",
	"new_pwd": "new_strong_password"
}
```

Controller flow:
1. Validate `email`, `otp`, and `new_pwd`.
2. Ensure user exists and is active.
3. Validate that OTP exists and is not expired.
4. Allow max 3 failed OTP attempts for current OTP; at limit, regenerate OTP and send it by email.
5. Track invalid OTP attempts per user and day.
6. If invalid OTP attempts are more than 10 in one day:
	 - do not lock or disable the user,
	 - reject further attempts for that day,
	 - create in-app security notification for all admins,
	 - send alert email with details (time, involved user, executor IP, attempts) to `SECURITY_ALERT_EMAIL`.
7. On valid OTP, update password and invalidate OTP.

Response 200:
```json
{
	"ok": true,
	"message": "Password reset completed"
}
```

Errors:
- 400 OTP regenerated
- 401 invalid OTP or invalid reset request
- 429 too many reset attempts for the day

### 3.1.3 POST /notify

Purpose:
- Poll unread in-app notifications for the logged-in user.

Request:
```json
{
	"session_token": "..."
}
```

Response 200:
```json
{
	"ok": true,
	"notifications": [
		{
			"id": 12,
			"category": "security",
			"message": "User alice@example.com exceeded OTP reset attempts limit",
			"details": {
				"time_utc": "2026-03-18T12:10:11+00:00",
				"involved_user": "alice@example.com",
				"executor_ip": "203.0.113.42",
				"attempts_today": 11,
				"event": "EXCESSIVE_OTP_RESET_ATTEMPTS"
			},
			"created_at": "2026-03-18T12:10:11+00:00"
		}
	]
}
```

Notes:
- Endpoint is pull-based so clients can poll notifications.
- Returned notifications are marked as read.
- Endpoint requires a valid `session_token`; users receive only notifications addressed to their own account.

### 3.2 POST /users/signup_new_user

Purpose:
- Admin-only creation of a new user with generated temporary password.

Request:
```json
{
	"admin_token": "...",
	"new_name": "Giulia",
	"new_surname": "Bianchi",
	"new_email": "giulia@example.com",
	"new_role": "user"
}
```

Controller flow:
1. Verify `admin_token` (valid JWT, non-expired, role=admin).
2. Validate `new_name`, `new_surname`, `new_email` format and length.
3. Check uniqueness of `new_email`.
4. Generate secure 16-char password using `secrets` module.
5. Hash password with argon2id and store user record.
6. Send onboarding email to `new_email` including temporary password + first-login reset instructions.
7. Return success (never return password in API response).

Response 201:
```json
{
	"ok": true,
	"message": "User created and credentials sent by email at {new_email}"
}
```

Errors:
- 400 invalid input
- 401 invalid token
- 403 admin required
- 409 email already exists
- 500 server internal error
- 502 email delivery failure (option: mark user as pending)

### 3.3 POST /users/remove_user

Purpose:
- Remove/disable a user.

Policy:
- Prefer soft delete (`is_active=false`) for auditability and historical chain attribution. Maybe delete name, surname and pwd, but not email.

Request options:
1. Admin path:
```json
{
	"admin_token": "...",
	"email": "target@example.com"
}
```
2. Self path:
```json
{
	"email": "target@example.com",
	"pwd": "user_password"
}
```

Controller flow:
1. If `admin_token` provided -> validate admin.
2. Else validate `email+pwd` against same user.
3. Prevent deleting last admin (optional safety rule).
4. Soft-disable user (`is_active=false`, `disabled_at`).
5. Revoke active sessions for that user.

Response 200:
```json
{
	"ok": true,
	"message": "User disabled"
}
```

Errors:
- 400 invalid request
- 401 invalid credentials/token
- 403 forbidden
- 404 user not found
- 409 business rule conflict
- 500 internal error

### 3.4 POST /users/change_user_pwd

Purpose:
- Change user password.

Request:
```json
{
	"email": "user@example.com",
	"old_pwd": "old_password",
	"new_pwd": "new_password"
}
```

Controller flow:
1. Validate fields and password policy.
2. Find active user by email.
3. Verify old password.
4. Hash and update new password.
5. Rotate/revoke old sessions.

Response 200:
```json
{
	"ok": true,
	"message": "Password updated"
}
```

Errors:
- 400 invalid payload/policy
- 401 wrong old password
- 404 user not found
- 500 internal error

### 3.5 POST /chain/check_chain_sync

Purpose:
- Check if client chain tip is aligned with server chain.

Request:
```json
{
	"client_block_hash": "abc123..."
}
```

Controller flow:
1. Validate hash format.
2. Read server latest block hash.
3. If equals -> return synced.
4. Else walk backward from head (or query by hash index) until:
	 - hash found -> return all missing blocks after matched block
	 - not found -> return full chain (or from genesis)

Response 200 (already synced):
```json
{
	"ok": true,
	"synced": true,
	"missing_blocks": []
}
```

Response 200 (not synced):
```json
{
	"ok": true,
	"synced": false,
	"from_hash": "matched_hash_or_null",
	"missing_blocks": [
		{
			"n_block": 11,
			"prev_block_hash": "...",
			"block_hash": "...",
			"datetime": "2026-03-17T10:30:00Z",
			"changes": {"item_1": -2, "item_2": 4},
			"author_email": "admin@example.com",
			"author_sign": "...",
			"server_sign": "..."
		}
	]
}
```

Errors:
- 400 invalid hash
- 500 internal error

### 3.6 POST /chain/add_block

Purpose:
- Validate, certify, persist, and apply a proposed block.

Request:
```json
{
	"block": {
		"height": 42,
		"round": 0,
		"prev_block_hash": "...",
		"transactions": [],
		"block_hash": "..."
	},
	"votes": [
		{"height": 42, "round": 0, "block_hash": "...", "validator_id": "node_a", "signature": "..."},
		{"height": 42, "round": 0, "block_hash": "...", "validator_id": "node_b", "signature": "..."},
		{"height": 42, "round": 0, "block_hash": "...", "validator_id": "node_c", "signature": "..."}
	]
}
```

Controller validation:
1. Validate every transaction's Ed25519 signature and required fields.
2. Require `height` to equal the current chain height plus one and `prev_block_hash` to match the current tip.
3. Recompute `block_hash` as SHA-256 of canonical JSON containing `height`, `prev_block_hash`, and `transactions`.
4. Reject transaction IDs already present in the chain or duplicated in the proposal.
5. Verify at least three distinct configured validator signatures over the proposed block hash, height, and round.
6. Simulate the inventory transition; reject unknown outbound items and any negative resulting quantity.
7. Persist the block and validator votes in one database transaction, then update the inventory cache.

Response 201:
```json
{
	"ok": true,
	"block_hash": "...",
	"height": 42,
	"votes": []
}
```

Errors:
- 400 invalid proposal, hash, transaction, signature, or insufficient quorum
- 409 chain height or previous-hash mismatch
- 422 invalid inventory transition (negative quantity)
- 500 internal error

`POST /chain/submit_transaction` accepts `{"transaction": {...}}` and stores a
valid signed transaction in the mempool. A node requests a deterministic
candidate from `POST /chain/build_proposal` with `{"round": 0}`. The candidate
is not committed until `POST /chain/add_block` receives three or more distinct
valid configured validator votes for the same height, round, and hash. Legacy
requests containing only inventory deltas are rejected; they cannot bypass
validator certification.

---

## 4. Data Model (SQLite)

### 4.1 Table: users

Recommended columns:
- `id` INTEGER PK
- `name` TEXT NOT NULL
- `surname` TEXT NOT NULL
- `email` TEXT UNIQUE NOT NULL
- `pwd_hash` TEXT NOT NULL
- `role` TEXT NOT NULL CHECK(role IN ('admin','user'))
- `is_active` INTEGER NOT NULL DEFAULT 1
- `created_at` TEXT NOT NULL
- `updated_at` TEXT
- `disabled_at` TEXT

Indexes:
- unique index on `email`
- index on `is_active`

### 4.2 Table: chain

One block per row.

Recommended columns:
- `id` INTEGER PK
- `n_block` INTEGER UNIQUE NOT NULL
- `prev_block_hash` TEXT
- `block_hash` TEXT UNIQUE NOT NULL
- `datetime` TEXT NOT NULL
- `changes_json` TEXT NOT NULL
- `author_email` TEXT NOT NULL
- `author_sign` TEXT
- `server_sign` TEXT NOT NULL

Indexes:
- unique index on `n_block`
- unique index on `block_hash`
- index on `prev_block_hash`
- index on `author_email`

### 4.3 Tables: pending_transactions and block_votes

- `pending_transactions` stores canonical, client-signed transactions until finalization.
- `block_votes` stores validator signatures, uniquely keyed by block height, round, and validator.
- A committed block records its transactions alongside derived inventory changes and catalog metadata.

Optional table for token revocation:
- `revoked_tokens(jti TEXT PRIMARY KEY, revoked_at TEXT NOT NULL)`

---

## 5. Inventory Cache Strategy (Model Runtime State)

In-memory structure:
```python
inventory_cache: dict[str, int] = {}
latest_block_hash: str
latest_block_number: int
```

Startup:
1. Load all chain blocks ordered by `n_block`.
2. Replay `changes_json` into `inventory_cache`.
3. Set `latest_block_hash` and `latest_block_number`.

On successful `add_block`:
1. Persist block in DB transaction.
2. Apply changes to cache only after DB commit.
3. Update head hash/number.

Recovery:
- If process restarts, cache is rebuilt from chain.
- Optional periodic snapshot table can reduce warm-up time.

---

## 6. Security and Token Design

Session token (JWT):
- Header: `alg=HS256` (or RS256 if key pair available)
- Claims:
	- `sub`: user email
	- `role`: admin/user
	- `jti`: unique token id
	- `iat`, `exp`

Recommended settings:
- Token TTL: 8-12 hours
- Secret from env var (`JWT_SECRET`)
- Password policy: min length, complexity, breached-password check if possible
- All REST endpoints use HTTP.

Block signatures:
- Clients sign canonical transaction JSON with Ed25519.
- Validators sign canonical JSON of `{height, round, block_hash, validator_id}`.
- Validator public keys are configured in `VALIDATOR_PUBLIC_KEYS`; blocks without three distinct valid votes are rejected.

---

## 7. Error and Exception Handling

Global handlers:
- Validation errors -> 400 with field-level detail
- Auth errors -> 401/403
- Not found -> 404
- Business rule conflicts -> 409/422
- Unexpected exceptions -> 500 with trace id (no sensitive leak)

Standard error response:
```json
{
	"ok": false,
	"error": {
		"code": "CHAIN_HEAD_MISMATCH",
		"message": "Client chain is stale",
		"details": {}
	}
}
```

Operational safeguards:
- Structured logging (JSON) with request id.
- Timeouts for DB and SMTP.
- Retries for transient email failures.
- Rate limiting for login endpoint.

---

## 8. Docker Deployment Blueprint

Container behavior:
- Single service exposing the plain HTTP API on port `8000` (host port `2900` by default).
- SQLite DB persisted through mounted volume.
- Environment-driven configuration.

Environment variables:
- `APP_ENV=production`
- `API_HOST=0.0.0.0`
- `API_PORT=8000`
- `JWT_SECRET=...`
- `SERVER_SIGN_PRIVATE_KEY=...`
- `NODE_ID=...`
- `VALIDATOR_PRIVATE_KEY=...`
- `VALIDATOR_PUBLIC_KEYS=...`
- `DB_PATH=/data/bis.db`
- `SMTP_HOST`, `SMTP_PORT`, `SMTP_USER`, `SMTP_PASS`, `SMTP_FROM`
- `SECURITY_ALERT_EMAIL`

Runtime command:
- `uvicorn app.main:app --host 0.0.0.0 --port 8000`

Health endpoints:
- `GET /health/live`
- `GET /health/ready` (checks DB access and key material)

Production notes:
- Use non-root user in container.
- Mount `/data` volume for SQLite persistence.
- The API does not configure transport certificates or protocol redirects.

---

## 9. Suggested Project Layout

```text
Auth&Blockchain server/
	app/
		main.py
		api/
			routes_auth.py
			routes_users.py
			routes_chain.py
			routes_health.py
		core/
			config.py
			security.py
			exceptions.py
			logging.py
		services/
			auth_service.py
			user_service.py
			chain_service.py
			distributed_service.py
			sync_service.py
			email_service.py
			cache_service.py
		db/
			models.py
			repositories.py
			session.py
			migrations/
	tests/
		test_auth.py
		test_users.py
		test_chain.py
	requirements.txt
	Dockerfile
	backend_blueprint.md
```

---

## 10. Frontend Integration Notes (Flutter BIS)

Alignment with app blueprint:
- Auth screens call `/auth/login`.
- Password recovery flow calls `/auth/forgot_pwd` then `/auth/reset_login_with_otp`.
- Admin workflows call `/users/signup_new_user` and `/users/remove_user`.
- Inventory apply action calls `/chain/add_block`.
- Chain log screen uses `/chain/check_chain_sync` to fetch missing blocks.
- Clients poll `/notify` to receive new in-app notifications.

API conventions for client consistency:
- All responses include `ok` boolean.
- Datetime format: ISO8601 UTC.
- Block payload uses stable `changes` map (`itemID -> signed int`).

---

## 11. Open Decisions

1. User removal policy:
	 - Recommended: soft disable (audit-safe).
2. Blockchain scale strategy:
	 - SQLite is fine for first version.
	 - For multi-instance/high write throughput, move to PostgreSQL.
4. Email reliability:
	 - For production, queue email jobs to avoid blocking API.

---

## 12. Minimal Endpoint Checklist

- [ ] `POST /api/v1/auth/login`
- [ ] `POST /api/v1/auth/forgot_pwd`
- [ ] `POST /api/v1/auth/reset_login_with_otp`
- [ ] `POST /api/v1/notify`
- [ ] `POST /api/v1/users/signup_new_user`
- [ ] `POST /api/v1/users/remove_user`
- [ ] `POST /api/v1/users/change_user_pwd`
- [ ] `POST /api/v1/chain/check_chain_sync`
- [ ] `POST /api/v1/chain/add_block`
- [ ] `GET /api/v1/health/live`
- [ ] `GET /api/v1/health/ready`

This blueprint is implementation-ready and consistent with the existing Flutter app navigation and flows.
