# Flutter client blueprint

## 1. Scope

The Flutter application is a client of the Python validator API. It does not
participate in proposer selection or consensus. It authenticates users,
submits signed inventory transactions, displays committed inventory, and
shows a local pending overlay for the requesting user.

The demo transport is HTTP. The default API endpoint is configured at build
time with `API_BASE_URL` or the selected app flavor. HTTPS and certificate
validation are deployment hardening work, not part of the current demo.

## 2. Authentication and routing

- Login returns a JWT session token and the authenticated user profile.
- Authenticated routes are protected by `go_router`.
- Password reset uses the backend OTP endpoints.
- Every API request includes `X-App-Token`; authenticated chain operations
  also include the session token in their JSON payload.

## 3. Screens and routes

| Screen | Route | Responsibility |
|---|---|---|
| Inventario | `/` | Committed inventory plus the local pending overlay |
| Transazioni | `/transactions` | The current user's transactions and status |
| Blockchain | `/blockchain` | Committed block history |
| Block detail | `/blockchain/<block>` | Block changes, proposer, and signatures |
| Profilo | `/profile` | User data, statistics, and administration |
| Notifiche | `/notifications` | Internal notification screen, not a bottom-nav item |

The bottom navigation labels are **Inventario**, **Transazioni**,
**Blockchain**, and **Profilo**. The Blockchain tab uses a chain/link icon.

## 4. Transaction flow

The inventory screen creates a transaction with:

```json
{
  "item_id": "...",
  "quantity": 2,
  "location": "...",
  "client_ID": "...",
  "client_public_key": "...",
  "trans_id": "...",
  "timestamp": "...",
  "item_catalog": {},
  "signature": "..."
}
```

Positive quantity adds stock; negative quantity removes stock. The client
signs the canonical transaction payload. The transport `flag` is excluded
from the signature.

`POST /api/v1/chain/add_transaction` returns a pending confirmation and a
forwarding status. The app polls `/transaction_status` while waiting for the
transaction to become `finalized`.

## 5. Pending-state reconciliation

`PendingTransactionCache` is an in-memory cache of locally submitted
transactions. It is not authoritative. On every Inventory and Transactions
refresh, the client calls `/user_transactions` and:

1. matches rows by `trans_id`;
2. removes cached entries whose server status is `finalized` or `rejected`;
3. updates any remaining cached status;
4. applies the pending quantity overlay only after reconciliation.

This ordering is required: otherwise a committed quantity can be added a
second time by a stale local overlay.

## 6. Blockchain display

The block detail screen displays:

- proposer node (`node-A`, `node-B`, `node-C`, or `node-D`);
- block date and changes;
- proposer signature over the block hash;
- the validator COMMIT signature certificate;
- current and previous block hashes.

PREPARE signatures are internal consensus messages and are not displayed or
persisted in the public block representation.

## 7. Backend integration

Important endpoints:

- `POST /api/v1/auth/login`
- `POST /api/v1/chain/add_transaction`
- `POST /api/v1/chain/transaction_status`
- `POST /api/v1/chain/user_transactions`
- `POST /api/v1/chain/blockchain_sync`
- `GET /api/v1/chain/history`

The client must use `blockchain_sync`; `check_chain_sync` is obsolete.

## 8. Validation

From `Client/`:

```bash
dart format --output=none lib
dart analyze
flutter test
```

Hot reload/restart requires an active Flutter debug application connected to
the Dart Tooling Daemon.
