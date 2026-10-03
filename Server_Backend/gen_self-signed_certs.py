from datetime import datetime, timedelta, timezone
from ipaddress import ip_address
from pathlib import Path
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import NameOID, ExtendedKeyUsageOID

out = Path("certs")
out.mkdir(parents=True, exist_ok=True)

key = rsa.generate_private_key(public_exponent=65537, key_size=2048)

subject = issuer = x509.Name([
    x509.NameAttribute(NameOID.COUNTRY_NAME, "IT"),
    x509.NameAttribute(NameOID.ORGANIZATION_NAME, "BIS Local Dev"),
    x509.NameAttribute(NameOID.COMMON_NAME, "localhost"),
])

san = x509.SubjectAlternativeName([
    x509.DNSName("localhost"),
    x509.DNSName("127.0.0.1"),
    x509.IPAddress(ip_address("127.0.0.1")),
])

cert = (
x509.CertificateBuilder()
    .subject_name(subject)
    .issuer_name(issuer)
    .public_key(key.public_key())
    .serial_number(x509.random_serial_number())
    .not_valid_before(datetime.now(timezone.utc) - timedelta(minutes=5))
    .not_valid_after(datetime.now(timezone.utc) + timedelta(days=365))
    .add_extension(san, critical=False)
    .add_extension(x509.BasicConstraints(ca=False, path_length=None), critical=True)
    .add_extension(
        x509.KeyUsage(
            digital_signature=True,
            key_encipherment=True,
            content_commitment=False,
            data_encipherment=False,
            key_agreement=False,
            key_cert_sign=False,
            crl_sign=False,
            encipher_only=False,
            decipher_only=False,
        ),
        critical=True,
    )
    .add_extension(
        x509.ExtendedKeyUsage([ExtendedKeyUsageOID.SERVER_AUTH]),
        critical=False,
    )
    .sign(private_key=key, algorithm=hashes.SHA256())
)

(out / "privkey.pem").write_bytes(
    key.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.TraditionalOpenSSL,
        encryption_algorithm=serialization.NoEncryption(),
    )
)
(out / "fullchain.pem").write_bytes(cert.public_bytes(serialization.Encoding.PEM))

print("Creati:")
print(out / "privkey.pem")
print(out / "fullchain.pem")