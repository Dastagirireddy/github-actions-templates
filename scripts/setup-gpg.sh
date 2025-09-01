#!/bin/bash
set -e

# Default values
KEY_NAME="${1:-GitHub Actions}"
KEY_EMAIL="${2:-actions@github.com}"
KEY_PASSPHRASE="${3:-}"
GNUPG_HOME="${4:-$HOME/.gnupg}"

# Create GnuPG directory
mkdir -p "$GNUPG_HOME"
chmod 700 "$GNUPG_HOME"

# Configure GnuPG
cat > "$GNUPG_HOME/gpg.conf" << EOF
use-agent
pinentry-mode loopback
default-key "$KEY_EMAIL"
keyring "$GNUPG_HOME/pubring.kbx"
trustdb-name "$GNUPG_HOME/trustdb.gpg"
personal-digest-preferences SHA512
cert-digest-algo SHA512
default-preference-list SHA512 SHA384 SHA256 SHA224 AES256 AES192 AES CAST5 ZLIB BZIP2 ZIP Uncompressed
personal-cipher-preferences TWOFISH CAMELLIA256 AES 3DES
