#!/usr/bin/env bash
set -Eeuo pipefail

SERVER_IP="${1:-10.110.23.90}"
CERT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/certs"
CERT_NAME="fullchain.pem"
KEY_NAME="privkey.pem"
OPENSSL_CNF_NAME="openssl-san.cnf"
CERT_FILE="$CERT_DIR/$CERT_NAME"
KEY_FILE="$CERT_DIR/$KEY_NAME"
OPENSSL_CNF="$CERT_DIR/$OPENSSL_CNF_NAME"
DAYS="${CERT_DAYS:-825}"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

validate_ip() {
  local ip="$1"
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || fail "Invalid IPv4 address: $ip"

  local IFS=.
  local octets
  read -r -a octets <<<"$ip"
  for octet in "${octets[@]}"; do
    (( octet >= 0 && octet <= 255 )) || fail "Invalid IPv4 address: $ip"
  done
}

openssl_cmd() {
  if command -v openssl >/dev/null 2>&1; then
    (cd "$CERT_DIR" && openssl "$@")
  else
    docker run --rm \
      -v "$CERT_DIR:/certs" \
      -w /certs \
      alpine:3.20 \
      sh -c 'apk add --no-cache openssl >/dev/null && openssl "$@"' \
      openssl "$@"
  fi
}

certificate_is_suitable() {
  [[ -s "$CERT_FILE" && -s "$KEY_FILE" ]] || return 1
  openssl_cmd x509 -in "$CERT_NAME" -noout -checkend 2592000 >/dev/null 2>&1 || return 1
  openssl_cmd x509 -in "$CERT_NAME" -noout -ext subjectAltName 2>/dev/null | grep -Fq "IP Address:${SERVER_IP}" || return 1
  openssl_cmd x509 -in "$CERT_NAME" -pubkey -noout >"$CERT_DIR/.cert.pub" || return 1
  openssl_cmd pkey -in "$KEY_NAME" -pubout >"$CERT_DIR/.key.pub" || return 1
  local match=0
  cmp -s "$CERT_DIR/.cert.pub" "$CERT_DIR/.key.pub" || match=1
  rm -f "$CERT_DIR/.cert.pub" "$CERT_DIR/.key.pub"
  return "$match"
}

validate_ip "$SERVER_IP"
mkdir -p "$CERT_DIR"

if certificate_is_suitable; then
  echo "Existing certificate is suitable for IP SAN ${SERVER_IP}: $CERT_FILE"
  exit 0
fi

cat >"$OPENSSL_CNF" <<EOF
[req]
default_bits = 2048
prompt = no
default_md = sha256
distinguished_name = dn
x509_extensions = v3_req

[dn]
CN = ${SERVER_IP}

[v3_req]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
IP.1 = ${SERVER_IP}
EOF

echo "Generating self-signed certificate for IP SAN ${SERVER_IP}"
openssl_cmd req \
  -x509 \
  -nodes \
  -newkey rsa:2048 \
  -days "$DAYS" \
  -keyout "$KEY_NAME" \
  -out "$CERT_NAME" \
  -config "$OPENSSL_CNF_NAME"

chmod 644 "$CERT_FILE"
chmod 600 "$KEY_FILE"

echo "Certificate: $CERT_FILE"
echo "Private key: $KEY_FILE"
openssl_cmd x509 -in "$CERT_NAME" -noout -subject -issuer -dates -ext subjectAltName
