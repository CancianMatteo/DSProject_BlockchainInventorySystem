from cryptography.hazmat.primitives.asymmetric import ed25519
import base64

# 1. Genera una nuova chiave privata Ed25519
private_key = ed25519.Ed25519PrivateKey.generate()
# 2. Estrai i byte "raw" della chiave (32 byte)
private_bytes = private_key.private_bytes_raw()
# 3. Codifica in Base64 per renderla una stringa leggibile nel file .env
encoded_key = base64.b64encode(private_bytes).decode('utf-8')
print(f"La tua SERVER_SIGN_PRIVATE_KEY è:{encoded_key}")

# Genera anche la chiave pubblica corrispondente (opzionale, per verifica)
public_key = private_key.public_key()
public_bytes = public_key.public_bytes_raw()
encoded_public_key = base64.b64encode(public_bytes).decode('utf-8')
print(f"La chiave pubblica corrispondente è: {encoded_public_key}")

# Genera un JWT
from datetime import datetime, timedelta
from jwt import encode
# Carica la chiave privata dal Base64
private_key_bytes = base64.b64decode(encoded_key)
private_key = ed25519.Ed25519PrivateKey.from_private_bytes(private_key_bytes)
# Crea un payload per il JWT
payload = {
    "sub": "server",
    "exp": datetime.utcnow() + timedelta(hours=1)
}
# Genera il token JWT
token = encode(payload, private_key, algorithm="EdDSA")
print(f"Il token JWT generato è: {token}")