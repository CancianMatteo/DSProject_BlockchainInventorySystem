# BIS App

## HTTP and build-time configuration

The app communicates with the backend over plain HTTP for this demo project.

The default backend endpoint is `http://100.67.33.52:8002`. To configure it through
an environment file, copy `.env.example` to `.env` and pass it to Flutter:

```
cp .env.example .env
flutter run --dart-define-from-file=.env
```

You can also switch endpoints at build time using flavors:

- `APP_FLAVOR=prod` (default) -> `API_BASE_URL_PROD`
- `APP_FLAVOR=dev` -> `API_BASE_URL_DEV`

### Examples

Run with the dev endpoint:

```
flutter run --dart-define=APP_FLAVOR=dev --dart-define-from-file=.env
```

Override the dev/prod defaults:

```
flutter run --dart-define=APP_FLAVOR=dev --dart-define=API_BASE_URL_DEV=http://100.67.33.52:8002
```

Force a specific base URL (takes precedence over flavor defaults):

```
flutter run --dart-define=API_BASE_URL=http://100.67.33.52:8002
```
