# BIS App

## HTTPS and build-time flavors

The app uses HTTPS by default and blocks cleartext HTTP except for local hosts
(`localhost`, `127.0.0.1`, `10.0.2.2`).

You can switch endpoints at build time using flavors:

- `APP_FLAVOR=prod` (default) -> `API_BASE_URL_PROD`
- `APP_FLAVOR=dev` -> `API_BASE_URL_DEV`

### Examples

Run with the dev endpoint:

```
flutter run --dart-define=APP_FLAVOR=dev
```

Override the dev/prod defaults:

```
flutter run --dart-define=APP_FLAVOR=dev --dart-define=API_BASE_URL_DEV=https://bis-dev.samuel-daros.it
```

Force a specific base URL (takes precedence over flavor defaults):

```
flutter run --dart-define=API_BASE_URL=https://bis.samuel-daros.it
```

Allow a self-signed TLS cert in debug (only for the configured host):

```
flutter run --dart-define=ALLOW_SELF_SIGNED_TLS=true
```
