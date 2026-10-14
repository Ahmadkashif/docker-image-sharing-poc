#!/bin/sh
# Registry garbage collection.
#   registry/gc.sh <compose-env-file> [--dry-run]
# Zot: GC + retention run online (storage.gc / storage.retention in zot-config.json) — nothing to do here.
# Distribution: GC is stop-the-world. Uploads during GC can corrupt images, so the registry is stopped first.
set -eu
ENVF="${1:?usage: gc.sh <compose-env-file> [--dry-run]}"; DRY="${2:-}"
HERE="$(cd "$(dirname "$0")" && pwd)"
dc() { docker compose --env-file "$ENVF" -f "$HERE/compose.yaml" "$@"; }
case "$(grep '^COMPOSE_PROFILES=' "$ENVF" | cut -d= -f2)" in
  *zot*) echo "zot: GC/retention are online (see zot-config.json storage.gc / storage.retention)"; exit 0 ;;
esac
dc stop distribution
dc run --rm --no-deps --entrypoint registry distribution garbage-collect ${DRY:+--dry-run} --delete-untagged /etc/distribution/config.yml
dc start distribution
