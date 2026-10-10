#!/usr/bin/env python3
"""Keep a private local signing certificate across builds, without changing trust."""
import os
from pathlib import Path
import re
import secrets
import subprocess
import sys


def main():
    if len(sys.argv) != 2:
        raise SystemExit("Usage: sign.py <app bundle>")
    os.umask(0o077)
    root = Path.home() / "Library/Application Support/Audio Button Signing"
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    root.chmod(0o700)
    password_file = root / "keychain-password"
    key = root / "signing-key.pem"
    certificate = root / "signing-certificate.pem"
    keychain = root / "signing.keychain-db"
    if keychain.exists() and not all(p.exists() for p in [password_file, key, certificate]):
        raise SystemExit("Signing files are incomplete. Restore the original Audio Button Signing folder.")
    if key.exists() != certificate.exists():
        raise SystemExit("Signing certificate/key is missing. Restore it; do not replace the app identity.")
    if not password_file.exists():
        password_file.write_text(secrets.token_hex(32))
    password_file.chmod(0o600)
    password = password_file.read_text().strip()

    def run(arguments):
        result = subprocess.run(arguments, text=True, capture_output=True)
        if result.returncode:
            detail = result.stderr.strip().replace(password, "[redacted]")
            raise RuntimeError(f"{arguments[0]} {arguments[1]} failed: {detail}")
        return result.stdout

    if not certificate.exists():
        config = root / "certificate.cnf"
        config.write_text("""[req]
prompt = no
distinguished_name = subject
x509_extensions = signing
[subject]
CN = Audio Button Local Signing
O = Audio Button
[signing]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always
""")
        run(["openssl", "req", "-new", "-newkey", "rsa:3072", "-x509", "-sha256",
             "-days", "3650", "-nodes", "-config", str(config), "-keyout", str(key),
             "-out", str(certificate)])
    key.chmod(0o600)
    certificate.chmod(0o600)
    run(["openssl", "x509", "-in", str(certificate), "-checkend", "0", "-noout"])
    if not keychain.exists():
        run(["security", "create-keychain", "-p", password, str(keychain)])
        run(["security", "set-keychain-settings", "-lut", "21600", str(keychain)])
        identity_file = root / "signing-identity.p12"
        run(["openssl", "pkcs12", "-export", "-inkey", str(key), "-in", str(certificate),
             "-name", "Audio Button Local Signing", "-out", str(identity_file),
             "-passout", "file:" + str(password_file)])
        run(["security", "unlock-keychain", "-p", password, str(keychain)])
        run(["security", "import", str(identity_file), "-k", str(keychain),
             "-P", password, "-T", "/usr/bin/codesign"])
        run(["security", "set-key-partition-list", "-S", "apple-tool:,apple:,codesign:",
             "-s", "-k", password, str(keychain)])
    keychain.chmod(0o600)
    run(["security", "unlock-keychain", "-p", password, str(keychain)])
    fingerprint = run(["openssl", "x509", "-in", str(certificate), "-noout", "-fingerprint", "-sha1"])
    identity = fingerprint.strip().split("=")[-1].replace(":", "")
    if not re.fullmatch(r"[0-9A-Fa-f]{40}", identity):
        raise RuntimeError("Could not identify the signing certificate.")

    def search_list():
        return re.findall(r'"([^"]+)"', run(["security", "list-keychains", "-d", "user"]))

    # codesign needs the certificate chain in its search list even with --keychain.
    # Add only our keystore temporarily; preserve other concurrent list changes.
    current = search_list()
    added = str(keychain) not in current
    try:
        if added:
            run(["security", "list-keychains", "-d", "user", "-s", *current, str(keychain)])
        run(["codesign", "--force", "--sign", identity, "--keychain", str(keychain),
             "--identifier", "local.pasha.AudioButton", "--timestamp=none", sys.argv[1]])
    finally:
        if added:
            remaining = [p for p in search_list() if p != str(keychain)]
            run(["security", "list-keychains", "-d", "user", "-s", *remaining])
    run(["codesign", "--verify", "--deep", "--strict", sys.argv[1]])
    print("Signed with the persistent local Audio Button certificate.")


if __name__ == "__main__":
    try:
        main()
    except RuntimeError as error:
        raise SystemExit(str(error))
