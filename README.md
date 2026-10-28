# Blockchain Inventory System

## Requirements

- Docker with the Compose plugin
- Python 3 and OpenSSL (only for the first setup)

## Setup and start

From the project folder, run:

```bash
python3 setup_env.py
docker compose up -d --build
```

The script asks for the admin email and password (at least 12 characters),
then creates the root `.env` with static validator keys and
`Server_Python/.env` with app settings. The backend creates this admin on its
first start. The script does not overwrite existing files. Keep the password
and both `.env` files private.

Check the services and API:

```bash
docker compose ps
curl http://localhost:8001/api/v1/health/ready
```

## Stop

```bash
docker compose down
```

Do not add `-v` if you want to keep the databases.
