#!/usr/bin/env python3
"""
STEP 2: Generate JWKS (JSON Web Key Set) from the Kubernetes Service Account
        certificate at /var/lib/kubernetes/service-account.crt.

        The public key is extracted from the X.509 certificate automatically.
        You can also pass a raw PEM public key file (.pub) — both formats work.

Run this ON THE MASTER NODE after configuring the API server in step 1.

Output: keys.json  — upload this to S3 as described in step 3.

Usage:
    python3 02-generate-jwks.py                                         # default: /var/lib/kubernetes/service-account.crt
    python3 02-generate-jwks.py /var/lib/kubernetes/service-account.crt  # explicit .crt
    python3 02-generate-jwks.py /path/to/sa.pub                         # raw PEM public key

Requirements:
    pip3 install cryptography
"""

import base64
import hashlib
import json
import sys

try:
    from cryptography.hazmat.primitives.asymmetric.rsa import RSAPublicKey
    from cryptography.hazmat.primitives.serialization import (
        Encoding,
        PublicFormat,
        load_pem_public_key,
    )
    from cryptography.x509 import load_pem_x509_certificate
except ImportError:
    print(
        "ERROR: 'cryptography' library is missing.\n"
        "Install it with:  pip3 install cryptography",
        file=sys.stderr,
    )
    sys.exit(1)


def base64url_uint(n: int) -> str:
    """Encode a positive integer as base64url with no padding."""
    length = (n.bit_length() + 7) // 8
    return base64.urlsafe_b64encode(n.to_bytes(length, "big")).rstrip(b"=").decode()


def generate_kid(der: bytes) -> str:
    """
    Key ID = base64url(SHA-256(DER-encoded SubjectPublicKeyInfo)).
    This matches how kube-apiserver derives the kid for bound tokens.
    """
    return base64.urlsafe_b64encode(hashlib.sha256(der).digest()).rstrip(b"=").decode()


def load_public_key(file_path: str):
    """
    Load a public key from either:
      - An X.509 certificate (.crt / .pem containing CERTIFICATE)
      - A raw PEM public key (.pub / .pem containing PUBLIC KEY)
    """
    with open(file_path, "rb") as fh:
        data = fh.read()

    # Detect whether this is an X.509 certificate or a raw public key
    if b"BEGIN CERTIFICATE" in data:
        print(f"[INFO] Detected X.509 certificate format, extracting public key...",
              file=sys.stderr)
        cert = load_pem_x509_certificate(data)
        return cert.public_key()
    elif b"BEGIN PUBLIC KEY" in data:
        print(f"[INFO] Detected raw PEM public key format.", file=sys.stderr)
        return load_pem_public_key(data)
    else:
        print(
            "ERROR: File does not contain a PEM certificate or public key.\n"
            f"       File: {file_path}",
            file=sys.stderr,
        )
        sys.exit(1)


def main() -> None:
    # Default path for Kubernetes the Hard Way
    key_file = "/var/lib/kubernetes/service-account.crt"
    if len(sys.argv) > 1:
        key_file = sys.argv[1]

    try:
        pub_key = load_public_key(key_file)
    except FileNotFoundError:
        print(f"ERROR: File not found: {key_file}", file=sys.stderr)
        sys.exit(1)

    if not isinstance(pub_key, RSAPublicKey):
        print("ERROR: Only RSA keys are supported.", file=sys.stderr)
        sys.exit(1)

    nums = pub_key.public_numbers()
    der = pub_key.public_bytes(encoding=Encoding.DER, format=PublicFormat.SubjectPublicKeyInfo)
    kid = generate_kid(der)

    jwk = {
        "kty": "RSA",
        "alg": "RS256",
        "use": "sig",
        "kid": kid,
        "n": base64url_uint(nums.n),
        "e": base64url_uint(nums.e),
    }
    jwks = {"keys": [jwk]}

    output = json.dumps(jwks, indent=2)
    print(output)

    # Also write to file for easy upload
    with open("keys.json", "w") as fh:
        fh.write(output + "\n")

    print(
        "\n[INFO] Written to: keys.json\n"
        "[INFO] Next step: run  bash 03-setup-oidc-s3.sh  to upload to S3.",
        file=sys.stderr,
    )


if __name__ == "__main__":
    main()
