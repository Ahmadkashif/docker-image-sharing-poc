#!/usr/bin/env bash
# Q10 smoke test: Forgejo's built-in OCI registry vs the kit's needs (read-only pull credential, cosign 3 signatures /
# referrers API, multi-arch index). Throwaway container on the lab network only (no host port), TLS from mkcerts.sh.
set -uo pipefail
KIT="$(cd "$(dirname "$0")/../kit" 2>/dev/null || cd "$(dirname "$0")/../templates" || exit; pwd)"; cd "$KIT" || exit 1
FJ_IMAGE=codeberg.org/forgejo/forgejo:15.0.10; N=img-vmlab; S=build/forgejo-smoke; REG=forgejo.vmlab:3000
SRC="${SRC:?export SRC=<signed ref@digest in the lab Zot, e.g. from build/verify-linux-vm-lab/last/<app>.ref>}"
mkdir -p $S/secrets && chmod 700 $S/secrets
[ -f $S/certs/ca.crt ] || registry/mkcerts.sh $S/certs forgejo.vmlab >/dev/null
docker rm -f img-forgejo-smoke >/dev/null 2>&1
docker run -d --name img-forgejo-smoke --network $N --network-alias forgejo.vmlab -v "$PWD/$S/certs/tls:/certs:ro" \
  -e FORGEJO__database__DB_TYPE=sqlite3 -e FORGEJO__security__INSTALL_LOCK=true -e FORGEJO__server__DOMAIN=forgejo.vmlab \
  -e FORGEJO__server__ROOT_URL=https://$REG/ -e FORGEJO__server__HTTP_PORT=3000 -e FORGEJO__server__PROTOCOL=https \
  -e FORGEJO__server__CERT_FILE=/certs/registry.crt -e FORGEJO__server__KEY_FILE=/certs/registry.key \
  -e FORGEJO__service__DISABLE_REGISTRATION=true $FJ_IMAGE >/dev/null
for _ in $(seq 1 60); do docker exec img-forgejo-smoke sh -c 'wget -q --no-check-certificate -O /dev/null https://localhost:3000/api/healthz' 2>/dev/null && break; sleep 2; done
echo "forgejo: $(docker exec img-forgejo-smoke forgejo --version 2>/dev/null | head -1)"
ADMPW=$(openssl rand -hex 12); echo "lab-admin $ADMPW" > $S/secrets/passwords
docker exec -u git img-forgejo-smoke forgejo admin user create --admin --username lab-admin --password "$ADMPW" --email admin@example.invalid --must-change-password=false >/dev/null
WT=$(docker exec -u git img-forgejo-smoke forgejo admin user generate-access-token --username lab-admin --token-name ci-push --scopes write:package --raw)
RT=$(docker exec -u git img-forgejo-smoke forgejo admin user generate-access-token --username lab-admin --token-name server-pull --scopes read:package --raw)
echo "tokens: ci-push (write:package), server-pull (read:package) — values redacted"
# tool auth: zot ci-push (source) + forgejo token (dest); CA for both registries
T=$(mktemp -d); chmod 700 "$T"; mkdir -p "$T/certs.d/$REG" "$T/certs.d/zot.vmlab:5443"
cp $S/certs/ca.crt "$T/certs.d/$REG/ca.crt"; cp build/verify-linux-vm-lab/certs/ca.crt "$T/certs.d/zot.vmlab:5443/ca.crt"; cat $S/certs/ca.crt build/verify-linux-vm-lab/certs/ca.crt > "$T/ca-bundle.crt"
mkcfg() { python3 - "$1" "$2" "$3" "$4" <<'PY'
import base64, json, sys
out, reg, user, tok = sys.argv[1:]
src = json.load(open(__import__("os").environ["DOCKER_CONFIG"] + "/config.json"))["auths"]["zot.vmlab:5443"]
json.dump({"auths": {"zot.vmlab:5443": src, reg: {"auth": base64.b64encode(f"{user}:{tok}".encode()).decode()}}}, open(out, "w"))
PY
}
mkdir -p "$T/w" "$T/r"; mkcfg "$T/w/config.json" $REG lab-admin "$WT"; mkcfg "$T/r/config.json" $REG lab-admin "$RT"
regctl() { local c="$1"; shift; docker run --rm --network $N --user "$(id -u):$(id -g)" -e HOME=/tmp -v "$T/$c:/tmp/.docker:ro" -v "$T/certs.d:/etc/docker/certs.d:ro" ghcr.io/regclient/regctl:v0.11.6 "$@"; }
cosign() { local c="$1"; shift; docker run --rm -i --network $N --user "$(id -u):$(id -g)" -e HOME=/tmp -e DOCKER_CONFIG=/auth -e COSIGN_PASSWORD -e SSL_CERT_FILE=/ca.crt -v "$T/$c:/auth:ro" -v "$T/ca-bundle.crt:/ca.crt:ro" -v "$PWD/build/verify-linux-vm-lab/keys:/keys:ro" ghcr.io/sigstore/cosign/cosign:v3.1.3 "$@"; }
DST=$REG/lab-admin/pingboard:1.0.1
echo "== 1. push the multi-arch index + its referrers (regctl image copy --referrers) with the write:package token"
out=$(regctl w image copy --referrers --digest-tags --force-recursive "$SRC" "$DST" 2>&1); rc=$?; echo "$out" | tail -2; echo "  rc=$rc"
regctl w manifest get --format '{{.MediaType}} {{len .Manifests}} entries' "$DST" 2>&1
D=$(regctl w image digest "$DST" 2>/dev/null); echo "digest at forgejo: $D (source: ${SRC##*@})"
echo "== 2. OCI 1.1 referrers API: GET /v2/lab-admin/pingboard/referrers/<digest>"
code=$(curl -s -o "$T/ref.json" -w '%{http_code}' --cacert $S/certs/ca.crt --resolve "$REG:$(docker inspect -f '{{(index .NetworkSettings.Networks "img-vmlab").IPAddress}}' img-forgejo-smoke)" -u "lab-admin:$RT" "https://$REG/v2/lab-admin/pingboard/referrers/$D" 2>&1 || true)
echo "  http=$code body=$(head -c 200 "$T/ref.json")"
echo "  tags (cosign falls back to sha256-<digest> tags when there is no referrers API): $(regctl r tag ls $REG/lab-admin/pingboard 2>&1 | tr '\n' ' ')"
echo "== 3. cosign 3 sign + verify AT forgejo (key-based, no tlog)"
export COSIGN_PASSWORD; COSIGN_PASSWORD=$(cat build/verify-linux-vm-lab/secrets/cosign-password)
cosign w sign --yes --key /keys/cosign.key --tlog-upload=false --use-signing-config=false "$REG/lab-admin/pingboard@$D" 2>&1 | grep -v -i deprecated | tail -2
cosign r verify --key /keys/cosign.pub --insecure-ignore-tlog=true "$REG/lab-admin/pingboard@$D" >/dev/null 2>"$T/v.err" && echo "  verify (read:package token): OK" || echo "  verify FAILED: $(tail -1 "$T/v.err")"
echo "  tags after signing: $(regctl r tag ls $REG/lab-admin/pingboard 2>&1 | tr '\n' ' ')"
echo "== 4. read-only credential: push with the read:package token must be refused"
out=$(regctl r image copy "$SRC" $REG/lab-admin/robot-test:1 2>&1); rc=$?; echo "$out" | tail -1; echo "  push_with_read_token rc=$rc"
rm -rf "$T"
docker rm -f img-forgejo-smoke >/dev/null 2>&1; echo "smoke container removed"
