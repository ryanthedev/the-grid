#!/bin/bash
# Create a self-signed code signing certificate for development
# This certificate gives stable signatures so TCC remembers accessibility permissions

set -e

CERT_NAME="thegrid-dev"
KEYCHAIN="login.keychain-db"

# Check if certificate already exists
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
    echo "✓ Certificate '$CERT_NAME' already exists:"
    security find-identity -v -p codesigning | grep "$CERT_NAME"
    exit 0
fi

echo "Creating self-signed code signing certificate '$CERT_NAME'..."

# Create a temporary directory for the certificate files
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

# Generate a self-signed certificate using openssl
openssl req -x509 -newkey rsa:2048 -keyout "$TMPDIR/key.pem" -out "$TMPDIR/cert.pem" -days 3650 -nodes \
    -subj "/CN=$CERT_NAME" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=codeSigning" \
    2>/dev/null

# Convert to p12 format for import (use legacy format for macOS compatibility)
openssl pkcs12 -export -legacy -out "$TMPDIR/cert.p12" -inkey "$TMPDIR/key.pem" -in "$TMPDIR/cert.pem" -passout pass:thegrid 2>/dev/null

# Import into keychain
security import "$TMPDIR/cert.p12" -k "$KEYCHAIN" -P "thegrid" -T /usr/bin/codesign -T /usr/bin/security

# Trust the certificate for code signing
security add-trusted-cert -d -r trustRoot -k "$KEYCHAIN" "$TMPDIR/cert.pem" 2>/dev/null || true

echo ""
echo "✓ Certificate '$CERT_NAME' created successfully!"
echo ""
security find-identity -v -p codesigning | grep "$CERT_NAME" || echo "Note: Certificate created but may need keychain unlock to appear"
echo ""
echo "You can now run: make dev"
