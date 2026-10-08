# BIS App

## HTTP and build-time flavors

The app communicates with the backend over plain HTTP, which does not encrypt
credentials (priv_key never exchanged in the network) or inventory data in transit.

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
flutter run --dart-define=APP_FLAVOR=dev --dart-define=API_BASE_URL_DEV=http://bis-dev.samuel-daros.it
```

Force a specific base URL (takes precedence over flavor defaults):

```
flutter run --dart-define=API_BASE_URL=http://bis.samuel-daros.it
```
