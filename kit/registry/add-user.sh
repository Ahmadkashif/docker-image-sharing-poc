#!/bin/sh
# Add/replace a registry robot or human account (bcrypt htpasswd — the only format Distribution and Zot accept).
#   registry/add-user.sh <auth-dir> <user> [password]     (password: arg, $REG_PASSWORD, or a random one is printed once)
# Distribution: every authenticated user can push AND pull everything (no RBAC).
# Zot: rights come from accessControl in zot-config.json (rendered from REGISTRY_PUSH/PULL/ADMIN_USERS).
set -eu
DIR="${1:?usage: add-user.sh <auth-dir> <user> [password]}"; U="${2:?user}"; P="${3:-${REG_PASSWORD:-}}"
HTPASSWD_IMAGE="${HTPASSWD_IMAGE:-httpd:2.4-alpine}"
if [ -z "$P" ]; then P="$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-28)"; echo "generated password for $U: $P"; fi
mkdir -p "$DIR"; umask 077; touch "$DIR/htpasswd"
if command -v htpasswd >/dev/null 2>&1; then
  line="$(htpasswd -nbB -C 12 "$U" "$P")"
else
  line="$(docker run --rm --entrypoint htpasswd "$HTPASSWD_IMAGE" -nbB -C 12 "$U" "$P")"
fi
line="$(printf '%s\n' "$line" | head -n1)"
grep -v "^$U:" "$DIR/htpasswd" > "$DIR/htpasswd.tmp" || true
printf '%s\n' "$line" >> "$DIR/htpasswd.tmp"; mv "$DIR/htpasswd.tmp" "$DIR/htpasswd"
chmod 0640 "$DIR/htpasswd"   # group-readable: the registry reads it as 0:$REGISTRY_FILES_GID without CAP_DAC_OVERRIDE
echo "htpasswd: $U set in $DIR/htpasswd (restart not needed for Zot; Distribution re-reads on change)"
