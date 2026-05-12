"""Generate self-signed SSL certificate for HTTPS with SAN extensions"""

import os
import datetime
import ipaddress
from cryptography import x509
from cryptography.x509.oid import NameOID
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.primitives import serialization


def generate_ca(ca_cert_path, ca_key_path, days_valid=3650):
    """Generate a self-signed CA certificate.

    Args:
        ca_cert_path: Path to write the CA certificate (PEM format).
        ca_key_path: Path to write the CA private key (PEM format).
        days_valid: CA certificate validity in days (default: 10 years).
    """
    key = rsa.generate_private_key(
        public_exponent=65537,
        key_size=4096,
    )

    subject = issuer = x509.Name([
        x509.NameAttribute(NameOID.COUNTRY_NAME, "US"),
        x509.NameAttribute(NameOID.STATE_OR_PROVINCE_NAME, "Remote"),
        x509.NameAttribute(NameOID.LOCALITY_NAME, "Local"),
        x509.NameAttribute(NameOID.ORGANIZATION_NAME, "Dune Dashboard CA"),
        x509.NameAttribute(NameOID.COMMON_NAME, "Dune Dashboard Local CA"),
    ])

    cert = (
        x509.CertificateBuilder()
        .subject_name(subject)
        .issuer_name(issuer)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(datetime.datetime.utcnow())
        .not_valid_after(datetime.datetime.utcnow() + datetime.timedelta(days=days_valid))
        .add_extension(
            x509.BasicConstraints(ca=True, path_length=None),
            critical=True,
        )
        .add_extension(
            x509.KeyUsage(
                digital_signature=False,
                content_commitment=False,
                key_encipherment=False,
                data_encipherment=False,
                key_agreement=False,
                key_cert_sign=True,
                crl_sign=True,
                encipher_only=False,
                decipher_only=False,
            ),
            critical=True,
        )
        .add_extension(
            x509.SubjectKeyIdentifier.from_public_key(key.public_key()),
            critical=False,
        )
        .sign(key, hashes.SHA256())
    )

    with open(ca_cert_path, "wb") as f:
        f.write(cert.public_bytes(serialization.Encoding.PEM))

    with open(ca_key_path, "wb") as f:
        f.write(
            key.private_bytes(
                encoding=serialization.Encoding.PEM,
                format=serialization.PrivateFormat.TraditionalOpenSSL,
                encryption_algorithm=serialization.NoEncryption(),
            )
        )

    print(f"CA certificate generated: {ca_cert_path}")
    print(f"CA key generated: {ca_key_path}")


def generate_cert(cert_path, key_path, ca_cert_path=None, ca_key_path=None,
                  common_name="localhost", san_ips=None, san_dns=None, days_valid=365):
    """Generate a server certificate, optionally signed by a CA.

    Args:
        cert_path: Path to write the server certificate (PEM format).
        key_path: Path to write the server private key (PEM format).
        ca_cert_path: Path to CA certificate. If None, self-signed.
        ca_key_path: Path to CA private key. If None, self-signed.
        common_name: CN for the certificate subject (default: localhost).
        san_ips: List of IP addresses to include in SAN extension.
        san_dns: List of DNS names to include in SAN extension.
        days_valid: Certificate validity in days (default: 365).
    """
    key = rsa.generate_private_key(
        public_exponent=65537,
        key_size=2048,
    )

    subject = x509.Name([
        x509.NameAttribute(NameOID.COUNTRY_NAME, "US"),
        x509.NameAttribute(NameOID.STATE_OR_PROVINCE_NAME, "Remote"),
        x509.NameAttribute(NameOID.LOCALITY_NAME, "Local"),
        x509.NameAttribute(NameOID.ORGANIZATION_NAME, "Dune Dashboard"),
        x509.NameAttribute(NameOID.COMMON_NAME, common_name),
    ])

    # Build SAN entries
    san_entries = [x509.DNSName(common_name)]
    if san_ips:
        for ip in san_ips:
            try:
                san_entries.append(x509.IPAddress(ipaddress.ip_address(ip)))
            except ValueError:
                pass
    if san_dns:
        for dns in san_dns:
            san_entries.append(x509.DNSName(dns))

    # Deduplicate SAN entries
    san_entries = list(dict.fromkeys(san_entries))

    builder = (
        x509.CertificateBuilder()
        .subject_name(subject)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(datetime.datetime.utcnow())
        .not_valid_after(datetime.datetime.utcnow() + datetime.timedelta(days=days_valid))
        .add_extension(
            x509.SubjectAlternativeName(san_entries),
            critical=False,
        )
    )

    if ca_cert_path and ca_key_path and os.path.exists(ca_cert_path) and os.path.exists(ca_key_path):
        # Sign with CA
        with open(ca_cert_path, "rb") as f:
            ca_cert = x509.load_pem_x509_certificate(f.read())
        with open(ca_key_path, "rb") as f:
            ca_key = serialization.load_pem_private_key(f.read(), password=None)

        builder = (
            builder
            .issuer_name(ca_cert.subject)
            .add_extension(
                x509.AuthorityKeyIdentifier.from_issuer_public_key(ca_key.public_key()),
                critical=False,
            )
        )
        cert = builder.sign(ca_key, hashes.SHA256())
        sign_type = "CA-signed"
    else:
        # Self-signed
        builder = builder.issuer_name(subject)
        cert = builder.sign(key, hashes.SHA256())
        sign_type = "self-signed"

    with open(cert_path, "wb") as f:
        f.write(cert.public_bytes(serialization.Encoding.PEM))

    with open(key_path, "wb") as f:
        f.write(
            key.private_bytes(
                encoding=serialization.Encoding.PEM,
                format=serialization.PrivateFormat.TraditionalOpenSSL,
                encryption_algorithm=serialization.NoEncryption(),
            )
        )

    san_info = ", ".join(str(e) for e in san_entries)
    print(f"SSL certificate generated ({sign_type}): {cert_path} (CN={common_name}, SAN=[{san_info}])")
    print(f"SSL key generated: {key_path}")
    print(f"Valid for {days_valid} days")


def check_cert_expiry(cert_path, warning_days=30):
    """Check if a certificate is expiring soon.

    Args:
        cert_path: Path to the certificate file.
        warning_days: Days before expiry to trigger warning.

    Returns:
        Tuple of (is_expiring: bool, days_remaining: int or None, message: str).
    """
    if not os.path.exists(cert_path):
        return False, None, "Certificate file not found"

    try:
        with open(cert_path, "rb") as f:
            cert = x509.load_pem_x509_certificate(f.read())

        now = datetime.datetime.utcnow()
        # not_valid_after_utc was added in cryptography 42.0.0
        # Fall back to not_valid_after for older versions
        expiry_attr = getattr(cert, 'not_valid_after_utc', None)
        if expiry_attr is not None:
            expiry = expiry_attr.replace(tzinfo=None)
        else:
            expiry = cert.not_valid_after
        days_remaining = (expiry - now).days

        if days_remaining <= 0:
            return True, days_remaining, f"EXPIRED: Certificate expired {abs(days_remaining)} days ago"
        elif days_remaining <= warning_days:
            return True, days_remaining, f"WARNING: Certificate expires in {days_remaining} days"
        else:
            return False, days_remaining, f"OK: Certificate valid for {days_remaining} days"
    except Exception as e:
        return False, None, f"Error checking certificate: {e}"


if __name__ == "__main__":
    base_dir = os.path.dirname(os.path.abspath(__file__))
    cert_path = os.path.join(base_dir, "cert.pem")
    key_path = os.path.join(base_dir, "key.pem")
    generate_cert(cert_path, key_path)
