#!/bin/sh
# Internal CA + registry server certificate (works with OpenSSL 1.1/3.x and macOS LibreSSL).
#   registry/mkcerts.sh <out-dir> <dns-name> [more dns names or IPs...]
# Produces:  <out>/ca.crt          public CA cert: distribute to the Mac keychain, buildkitd.toml, servers' certs.d
#            <out>/ca/ca.key       CA private key: move OFFLINE after issuing (never mounted into any container)
#            <out>/tls/registry.crt + registry.key   the only files the registry containers mount
# If your company has a PKI, skip this and drop a company-issued registry.crt/.key + the company ca.crt into <out-dir>.
# The CA is name-constrained to the given DNS names/IPs, so a leaked CA key cannot mint certs for other domains.
set -eu
OUT="${1:?usage: mkcerts.sh <out-dir> <dns-name> [dns-or-ip ...]}"; shift
[ $# -ge 1 ] || { echo "need at least one DNS name" >&2; exit 2; }
DAYS_CA="${DAYS_CA:-1825}"; DAYS_LEAF="${DAYS_LEAF:-397}"   # leaf <= 397 days (browser/CAB rule; keeps rotation habitual)
mkdir -p "$OUT/ca" "$OUT/tls"; cd "$OUT"
umask 077

san=""; nc=""
for n in "$@"; do
  case "$n" in
    *[!0-9.]*) san="${san:+$san,}DNS:$n"; nc="${nc:+$nc,}permitted;DNS:$n" ;;
    *)         san="${san:+$san,}IP:$n";  nc="${nc:+$nc,}permitted;IP:$n/255.255.255.255" ;;
  esac
done

cat > ca.cnf <<EOF
[req]
distinguished_name = dn
x509_extensions = v3_ca
prompt = no
[dn]
CN = img-registry internal CA
[v3_ca]
basicConstraints = critical,CA:TRUE,pathlen:0
keyUsage = critical,keyCertSign,cRLSign
subjectKeyIdentifier = hash
nameConstraints = critical,$nc
EOF
cat > leaf.cnf <<EOF
[req]
distinguished_name = dn
prompt = no
[dn]
CN = $1
[v3_leaf]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = $san
authorityKeyIdentifier = keyid
subjectKeyIdentifier = hash
EOF

if [ ! -f ca/ca.key ]; then
  openssl ecparam -name prime256v1 -genkey -noout -out ca/ca.key
  openssl req -new -x509 -key ca/ca.key -sha256 -days "$DAYS_CA" -config ca.cnf -out ca.crt
  echo "created CA: $OUT/ca.crt (name-constrained to: $*)"
else
  echo "reusing CA: $OUT/ca.crt (its name constraints must already cover: $*)"
fi
openssl ecparam -name prime256v1 -genkey -noout -out tls/registry.key
openssl req -new -key tls/registry.key -config leaf.cnf -out tls/registry.csr
openssl x509 -req -in tls/registry.csr -CA ca.crt -CAkey ca/ca.key -CAcreateserial -CAserial ca/ca.srl -sha256 \
  -days "$DAYS_LEAF" -extfile leaf.cnf -extensions v3_leaf -out tls/registry.crt 2>/dev/null
rm -f tls/registry.csr ca.cnf leaf.cnf
chmod 0644 ca.crt tls/registry.crt; chmod 0600 ca/ca.key
chmod 0750 tls; chmod 0640 tls/registry.key   # read by the registry via its group (compose user 0:$REGISTRY_FILES_GID, no DAC_OVERRIDE)
openssl verify -CAfile ca.crt tls/registry.crt
echo "leaf SANs: $san"
