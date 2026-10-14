#!/usr/bin/env bash
# Validate the templates without touching any registry or server:
#   - every profile renders (into a temp dir) and its outputs parse (JSON, TOML-ish, compose config)
#   - shell scripts pass `bash -n` and shellcheck (koalaman/shellcheck image)
#   - mkcerts.sh produces a chain that verifies, name constraints included
#   - detect-host.sh runs on this machine AND inside a plain Linux container (no docker there)
#   - no host-specific values leaked into the templates (render.py --check-agnostic)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT" || exit 1
OUT="$(mktemp -d "${TMPDIR:-/tmp}/img-validate.XXXXXX")"; trap 'rm -rf "$OUT"' EXIT
fail=0; ok() { echo "  ok   $*"; }; bad() { echo "  FAIL $*"; fail=$((fail+1)); }
SHELLCHECK_IMAGE="${SHELLCHECK_IMAGE:-koalaman/shellcheck:v0.11.0}"

echo "render all profiles"
if IMG_BUILD_DIR="$OUT/build" python3 bin/render.py --all >/dev/null; then ok "render --all"; else bad "render --all"; fi
for d in "$OUT"/build/*/; do
  p="$(basename "$d")"
  python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$d/server/daemon.json" && ok "$p daemon.json" || bad "$p daemon.json"
  grep -q insecure "$d/server/daemon.json" && bad "$p daemon.json contains insecure-registries"
  sh -n "$d/server/install-trust.sh" && ok "$p install-trust.sh syntax" || bad "$p install-trust.sh"
  ( set -a; . "$d/profile.env" ) && ok "$p profile.env sources" || bad "$p profile.env"
  if [ -f "$d/registry/.env" ]; then
    python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$d/registry/zot-config.json" && ok "$p zot-config.json" || bad "$p zot-config.json"
    mkdir -p "$d/certs/tls" "$d/auth"; : > "$d/auth/htpasswd"
    if docker compose --env-file "$d/registry/.env" -f registry/compose.yaml config -q 2>"$OUT/err"; then ok "$p compose config"; else bad "$p compose config: $(head -1 "$OUT/err")"; fi
  fi
done

echo "negative profile checks (must be rejected)"
neg() { # name "KEY=VALUE lines" "KEY|KEY regex to drop from the base profile"
  { grep -v -E "^($3)=" profiles/p1-selfhosted-registry.env; printf '%s\n' "$2"; } > "$OUT/$1.env"
  if IMG_BUILD_DIR="$OUT/neg" python3 bin/render.py "$OUT/$1.env" >/dev/null 2>"$OUT/err"; then bad "$1 accepted"; else ok "$1 rejected: $(tail -1 "$OUT/err" | cut -c1-90)"; fi; }
neg bind-all "REGISTRY_BIND=0.0.0.0" REGISTRY_BIND
neg bad-platform "SERVER_PLATFORM=linux/sparc" SERVER_PLATFORM
neg server-not-built $'SERVER_PLATFORM=linux/arm64\nBUILD_PLATFORMS=linux/amd64' 'SERVER_PLATFORM|BUILD_PLATFORMS'
neg offline-mirror $'SERVER_INTERNET=no\nMIRROR_ENABLED=yes' 'SERVER_INTERNET|MIRROR_ENABLED'

echo "shell scripts"
for f in bin/img bin/detect-host.sh registry/*.sh tests/validate.sh; do bash -n "$f" && ok "bash -n $f" || bad "bash -n $f"; done
if docker image inspect "$SHELLCHECK_IMAGE" >/dev/null 2>&1 || docker pull -q "$SHELLCHECK_IMAGE" >/dev/null 2>&1; then
  if docker run --rm -v "$ROOT:/t:ro" -w /t "$SHELLCHECK_IMAGE" -S warning -e SC2046 bin/img bin/detect-host.sh registry/mkcerts.sh registry/add-user.sh registry/gc.sh tests/validate.sh >"$OUT/sc" 2>&1
  then ok "shellcheck (severity warning; SC2046 excluded: intentional optional flag)"; else bad "shellcheck: $(head -3 "$OUT/sc")"; fi
else echo "  skip shellcheck (image unavailable)"; fi

echo "certificates"
if registry/mkcerts.sh "$OUT/certs" registry.example.internal mirror.example.internal 10.0.0.10 >/dev/null 2>&1 \
   && openssl verify -CAfile "$OUT/certs/ca.crt" "$OUT/certs/tls/registry.crt" >/dev/null 2>&1; then ok "mkcerts chain verifies"; else bad "mkcerts"; fi
[ -f "$OUT/certs/ca/ca.key" ] && [ ! -f "$OUT/certs/tls/ca.key" ] && ok "CA key kept out of the mounted tls/ dir" || bad "CA key placement"
openssl x509 -in "$OUT/certs/ca.crt" -noout -text | grep -q "Name Constraints" && ok "CA is name-constrained" || bad "CA name constraints"
mode() { python3 -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777)[2:])' "$1"; }
[ "$(mode "$OUT/certs/tls/registry.key")" = 640 ] && [ "$(mode "$OUT/certs/ca/ca.key")" = 600 ] \
  && ok "registry.key 0640 (group-readable for the cap-dropped registry), ca.key 0600" || bad "key modes: $(mode "$OUT/certs/tls/registry.key") / $(mode "$OUT/certs/ca/ca.key")"
REG_PASSWORD=x registry/add-user.sh "$OUT/auth" probe >/dev/null 2>&1 && [ "$(mode "$OUT/auth/htpasswd")" = 640 ] && ok "htpasswd 0640" || bad "htpasswd mode"

echo "detect-host.sh"
bin/detect-host.sh --facts >"$OUT/f" 2>&1 && grep -q '^HOST_ARCH=' "$OUT/f" && ok "this machine: $(grep -E '^(HOST_OS|HOST_ARCH|DOCKER_SERVER)=' "$OUT/f" | tr '\n' ' ')" || bad "detect-host here"
if docker run --rm -v "$ROOT/bin:/b:ro" "${LINUX_TEST_IMAGE:-debian:13-slim}" bash /b/detect-host.sh --facts >"$OUT/l" 2>&1 && grep -q '^HOST_OS=linux' "$OUT/l"
then ok "linux container: $(grep -E '^(HOST_OS|HOST_ARCH|DISTRO|DOCKER_CLIENT)=' "$OUT/l" | tr '\n' ' ')"; else bad "detect-host in linux: $(head -2 "$OUT/l")"; fi

echo "host-agnostic templates"
python3 bin/render.py --check-agnostic >"$OUT/a" 2>&1 && ok "$(cat "$OUT/a")" || { bad "check-agnostic"; cat "$OUT/a"; }

echo; [ "$fail" = 0 ] && echo "validate: ALL OK" || echo "validate: $fail FAILURE(S)"; exit "$fail"
