from pathlib import Path
import base64

from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.primitives import serialization

root = Path(__file__).resolve().parent / "keys"
root.mkdir(parents=True, exist_ok=True)
private_path = root / "private_key.pem"
public_xml_path = root / "public_key.xml"

if private_path.exists() or public_xml_path.exists():
    raise SystemExit("Refusing to overwrite existing keys. Remove server/keys first if rotation is intended.")

key = rsa.generate_private_key(public_exponent=65537, key_size=3072)
private_path.write_bytes(
    key.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption(),
    )
)

numbers = key.public_key().public_numbers()
modulus = numbers.n.to_bytes((numbers.n.bit_length() + 7) // 8, "big")
exponent = numbers.e.to_bytes((numbers.e.bit_length() + 7) // 8, "big")
xml = (
    "<RSAKeyValue>"
    f"<Modulus>{base64.b64encode(modulus).decode('ascii')}</Modulus>"
    f"<Exponent>{base64.b64encode(exponent).decode('ascii')}</Exponent>"
    "</RSAKeyValue>"
)
public_xml_path.write_text(xml, encoding="utf-8")
print(f"Created private key: {private_path}")
print(f"Created client public key: {public_xml_path}")
print("Keep private_key.pem only on the server. public_key.xml is used only at build time.")
