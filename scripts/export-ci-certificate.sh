#!/bin/bash
#
# Generate a self-signed code signing certificate for CI use.
# This creates a certificate that can be stored as GitHub secrets.
#
# Usage:
#   ./scripts/export-ci-certificate.sh [password]
#
# If no password is provided, a random one will be generated.
#
# Output:
#   - thegrid-ci.p12 - The certificate in PKCS12 format
#   - thegrid-ci.p12.base64 - Base64 encoded for GitHub secrets
#
# After running, add these GitHub secrets:
#   CODESIGN_CERT_BASE64 = contents of thegrid-ci.p12.base64
#   CODESIGN_CERT_PASSWORD = the password shown in output
#

set -e

CERT_NAME="thegrid-ci"
P12_PASSWORD="${1:-$(openssl rand -base64 24)}"
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

echo "Creating CI certificate '$CERT_NAME'..."
echo ""

# Generate self-signed certificate for code signing
openssl req -x509 -newkey rsa:2048 \
    -keyout "$TMPDIR/key.pem" \
    -out "$TMPDIR/cert.pem" \
    -days 3650 \
    -nodes \
    -subj "/CN=$CERT_NAME" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=codeSigning" \
    2>/dev/null

# Export to PKCS12 format (use -legacy for macOS compatibility)
openssl pkcs12 -export -legacy \
    -out "thegrid-ci.p12" \
    -inkey "$TMPDIR/key.pem" \
    -in "$TMPDIR/cert.pem" \
    -passout pass:"$P12_PASSWORD"

# Convert to base64 for GitHub secrets
base64 -i thegrid-ci.p12 > thegrid-ci.p12.base64

echo "Certificate created successfully!"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "P12 Password: $P12_PASSWORD"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Add these GitHub secrets (Settings > Secrets and variables > Actions):"
echo ""
echo "  CODESIGN_CERT_BASE64"
echo "    Value: $(cat thegrid-ci.p12.base64)"
echo ""
echo "  CODESIGN_CERT_PASSWORD"
echo "    Value: $P12_PASSWORD"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "IMPORTANT: Delete thegrid-ci.p12 and thegrid-ci.p12.base64 after adding secrets!"
echo "  rm thegrid-ci.p12 thegrid-ci.p12.base64"
echo ""
