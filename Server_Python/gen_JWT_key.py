from cryptography.hazmat.primitives.asymmetric import ed25519
import base64

# 1. Generate a new Ed25519 private key.
private_key = ed25519.Ed25519PrivateKey.generate()
# 2. Extract the key's raw bytes (32 bytes).
private_bytes = private_key.private_bytes_raw()
# 3. Encode as Base64 so it can be stored as a string in the .env file.
encoded_key = base64.b64encode(private_bytes).decode('utf-8')
print(f"Your SERVER_SIGN_PRIVATE_KEY is: {encoded_key}")

# Also generate the corresponding public key (optional, for verification).
public_key = private_key.public_key()
public_bytes = public_key.public_bytes_raw()
encoded_public_key = base64.b64encode(public_bytes).decode('utf-8')
print(f"The corresponding public key is: {encoded_public_key}")

# Generate a JWT.
from datetime import datetime, timedelta
from jwt import encode
# Load the private key from Base64.
private_key_bytes = base64.b64decode(encoded_key)
private_key = ed25519.Ed25519PrivateKey.from_private_bytes(private_key_bytes)
# Create the JWT payload.
payload = {
    "sub": "server",
    "exp": datetime.utcnow() + timedelta(hours=1)
}
# Generate the JWT.
token = encode(payload, private_key, algorithm="EdDSA")
print(f"Generated JWT: {token}")