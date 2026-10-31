# Blueprint: Backend for Blockchain Inventory System (BIS)

## 1. Objective and Scope

This backend is the controller and authoritative model layer for the BIS Flutter client.

Design goals:
- REST API over HTTP for the demo deployment.
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
- HTTP is used directly by the demo deployment; HTTPS is a future hardening step.
- Each node's Python backend listens on container port `8000` and serves
  BOTH external clients (`/api/v1/auth|users|chain|...`) AND the co-located
  Elixir engine (`POST /api/v1/python_call`) on that single socket: FastAPI
  routes by URL path, so no second port is needed. The 2-VPS `deploy.sh`
  publishes it as host ports 8001..8004 (nodes a/b/c/d).
- The Elixir side never binds 8000: it listens on 4000 (cluster gossip) and
  on the internal-only 6000 HTTP bridge. Neither Elixir port is published by
  the local Compose deployment.

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
- For strong security, prefer sending plaintext over TLS and hashing server-side with argon2id.
- If client must send pre-hashed password, store and compare a server-controlled hash of that value.

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

### 3.5 POST /chain/blockchain_sync

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
			"proposer_id": "node_b",
			"proposer_signature": "...",
			"validator_signatures": {
				"commit": {
					"node_a": "...",
					"node_b": "...",
					"node_c": "..."
				}
			}
		}
	]
}
```

Errors:
- 400 invalid hash
- 500 internal error

### 3.6 POST /chain/add_transaction

Purpose:
- Authenticate and add one signed inventory transaction to this node's mempool.
- The transaction remains pending until a quorum-confirmed block is written.

Request:
```json
{
	"session_token": "...",
	"transaction": {
		"client_ID": "user@example.com",
		"quantity": 2,
		"item_id": "item_1",
		"location": "warehouse-1",
		"timestamp": "2026-10-25T11:00:00Z",
		"trans_id": "uuid",
		"client_public_key": "base64-ed25519-public-key",
		"signature": "base64-ed25519-signature",
		"item_catalog": {
			"item_1": {
				"itemName": "Example",
				"brand": "Example brand",
				"category": "General"
			}
		}
	}
}
```

Controller validation:
1. Validate the session token and require `client_ID` to match its subject.
2. Verify the Ed25519 signature over canonical JSON excluding `signature`, using
   `client_public_key`.
3. Validate quantity, inventory transition, item metadata, and transaction ID.
4. Insert the transaction into `pending_transactions` with status `pending`.
5. Forward the accepted transaction to the local Elixir messenger.

Response 202:
```json
{
	"ok": true,
	"trans_id": "uuid",
	"status": "pending",
	"duplicate": false,
	"confirm_pending_trans": true
}
```

Python requests a proposal when the configured threshold is reached or when
the configured idle interval elapses while pending transactions exist. Python
signals the local Elixir consensus engine; Elixir relays a trigger when the
local node is not the deterministic proposer. The Elixir round timeout is for
consensus progress and is not itself a block-creation policy.

### 3.6.1 POST /chain/transaction_status

Purpose:
- Confirm whether an accepted transaction is still pending or has been included
  in a quorum-confirmed block.

Request:
```json
{
	"session_token": "...",
	"trans_id": "uuid"
}
```

Response 200:
```json
{
	"ok": true,
	"trans_id": "uuid",
	"status": "finalized",
	"confirm_block_creation_for_trans": true
}
```

The client polls this endpoint after `add_transaction`. A `pending` status
means the transaction is in the mempool; `finalized` means its block has been
written. Unknown transaction IDs are returned with status `unknown`.

### 3.5.1 POST /chain/blockchain_sync

This is the canonical client synchronization endpoint. It accepts and returns
the synchronization payload described above.

### 3.7 GET /chain/history

Purpose:
- Serve the chain log in bounded pages without loading the full chain into the client.

Query parameters:
- `limit`: page size from 1 to 100 (default 50).
- `before_n_block`: optional exclusive cursor; fetches blocks with a lower block number.

Blocks are returned newest-first. When `has_more` is true, use
`next_before_n_block` as the `before_n_block` value on the next request.

Response 200:
```json
{
  "ok": true,
  "blocks": [],
  "has_more": true,
  "next_before_n_block": 51
}
```

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
- `author_sign` TEXT (legacy alias for the proposer signature)
- `server_sign` TEXT NOT NULL (legacy storage column; current responses expose
  proposer and validator signatures instead)
- `changes_json` stores `proposer_id`, `proposer_signature`,
  `validator_signatures.commit`, transactions, changes, and item catalog

Indexes:
- unique index on `n_block`
- unique index on `block_hash`
- index on `prev_block_hash`
- index on `author_email`

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

On successful quorum-confirmed block:
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
- All endpoints are currently served over HTTP in the demo.

Block signatures:
- Use Ed25519 private key stored in container secret.
- Server signs canonical JSON of block content.

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
- Single service exposing API on port `8000` (both client traffic and the
  co-located Elixir engine share this socket; FastAPI routes by path).
- SQLite DB persisted through mounted volume.
- Environment-driven configuration.

Environment variables:
- `APP_ENV=production`
- `API_HOST=0.0.0.0`
- `API_PORT=8000`
- `JWT_SECRET=...`
- `SERVER_SIGN_PRIVATE_KEY=...`
- `DB_PATH=/data/bis.db`
- `SMTP_HOST`, `SMTP_PORT`, `SMTP_USER`, `SMTP_PASS`, `SMTP_FROM`
- `SECURITY_ALERT_EMAIL`
- `ELIXIR_HOST=...` (container/network alias of the co-located Elixir node)
- `ELIXIR_HTTP_PORT=6000` per node (internal Elixir HTTP listener, no host
  port exposure; communication uses Docker internal networking)

Runtime command:
- `python -m app.run_server` (uvicorn on `$API_HOST:$API_PORT`, i.e. `0.0.0.0:8000`)

Health endpoints:
- `GET /health/live`
- `GET /health/ready` (checks DB access and key material)

Production notes:
- Use non-root user in container.
- Mount `/data` volume for SQLite persistence.

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
- Inventory apply action calls `/chain/add_transaction` once per changed item.
- Chain log screen uses paginated `GET /chain/history`; chain synchronization
  continues to use `/chain/blockchain_sync`.
- Inventory notifications are derived locally from confirmed chain data.

API conventions for client consistency:
- All responses include `ok` boolean.
- Datetime format: ISO8601 UTC.
- Block payload uses stable `changes` map (`itemID -> signed int`).

---

## 11. Open Decisions

1. Password transport mode:
	 - Recommended for production: TLS plus server-side hashing.
	 - Alternative: client-hash + server-side secondary hash.
2. User removal policy:
	 - Recommended: soft disable (audit-safe).
3. Blockchain scale strategy:
	 - SQLite is fine for first version.
	 - For multi-instance/high write throughput, move to PostgreSQL.
4. Email reliability:
	 - For production, queue email jobs to avoid blocking API.

---

## 12. Minimal Endpoint Checklist

- [ ] `POST /api/v1/auth/login`
- [ ] `POST /api/v1/auth/forgot_pwd`
- [ ] `POST /api/v1/auth/reset_login_with_otp`
- [ ] `POST /api/v1/users/signup_new_user`
- [ ] `POST /api/v1/users/remove_user`
- [ ] `POST /api/v1/users/change_user_pwd`
- [ ] `POST /api/v1/chain/blockchain_sync`
- [ ] `GET /api/v1/chain/history`
- [ ] `POST /api/v1/chain/add_transaction`
- [ ] `GET /api/v1/health/live`
- [ ] `GET /api/v1/health/ready`

This blueprint is implementation-ready and consistent with the existing Flutter app navigation and flows.
