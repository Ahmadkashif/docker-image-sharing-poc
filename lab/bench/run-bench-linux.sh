#!/usr/bin/env bash
# Build-time benchmark on Linux. Method of the earlier Mac bench:
# fresh docker-container builder, base images primed once, each measured run --no-cache with output discarded,
# median of REPS. Usage: run-bench-linux.sh <docker-context> <label> <case>...   cases: native-amd64 cross-arm64
#   cross-both emu-arm64 emu-both gzip
set -uo pipefail
CTXN="$1"; LABEL="$2"; shift 2; D="$(cd "$(dirname "$0")" && pwd)"; APP="${APP:?path to the Go app}"; REPS="${REPS:-3}"; B="img-bench-$LABEL"
dk() { docker --context "$CTXN" "$@"; }
now() { python3 -c 'import time; print(time.time())'; }
docker buildx inspect "$B" >/dev/null 2>&1 || docker buildx create --name "$B" --driver docker-container --driver-opt image=moby/buildkit:v0.33.1 --bootstrap "$CTXN" >/dev/null 2>&1
echo "# $(date -u +%FT%TZ) [$LABEL] context=$CTXN cpu: $(dk run --rm busybox:1.37.0 sh -c 'grep -m1 "model name" /proc/cpuinfo | cut -d: -f2; nproc' | tr '\n' ' ') builder platforms: $(docker buildx inspect "$B" | awk -F': *' '/^Platforms:/{print $2; exit}')"
for f in emulated cross cross-norun; do for p in linux/amd64 linux/arm64; do docker buildx build --builder "$B" -f "$D/Dockerfile.$f" --platform $p --output type=cacheonly "$APP" >/dev/null 2>&1; done; done
run() { # label dockerfile platforms
  local t=()
  for _ in $(seq 1 "$REPS"); do s=$(now); docker buildx build --builder "$B" --no-cache -f "$D/Dockerfile.$2" --platform "$3" --output type=cacheonly "$APP" >/dev/null 2>&1 || echo "  FAILED $1"; e=$(now); t+=("$(python3 -c "print(round($e-$s,1))")"); done
  printf '%-62s %s  median=%ss\n' "[$LABEL] $1" "${t[*]}" "$(printf '%s\n' "${t[@]}" | sort -n | awk '{a[NR]=$1} END{print a[int((NR+1)/2)]}')"
}
for c in "$@"; do case "$c" in
  native-amd64) run "go build, native amd64 (Dockerfile.emulated, amd64)" emulated linux/amd64 ;;
  cross-arm64)  run "go build, cross-compiled arm64 (Dockerfile.cross-norun)" cross-norun linux/arm64 ;;
  cross-both)   run "both platforms, cross-compiled (Dockerfile.cross-norun)" cross-norun linux/amd64,linux/arm64 ;;
  emu-arm64)    run "go build, EMULATED arm64 under QEMU (Dockerfile.emulated)" emulated linux/arm64 ;;
  emu-both)     run "both platforms, emulated arm64 compile (Dockerfile.emulated)" emulated linux/amd64,linux/arm64 ;;
  gzip) for p in linux/amd64 linux/arm64; do t=(); for _ in $(seq 1 "$REPS"); do r=$(dk run --rm --platform $p alpine:3.24 sh -c 'head -c 268435456 /dev/urandom > /tmp/r; time -p gzip -6 -c /tmp/r >/dev/null' 2>&1 >/dev/null | awk '/^real/{print $2}'); t+=("$r"); done; printf '%-62s %s\n' "[$LABEL] gzip -6 256MiB, $p (s, in-container time)" "${t[*]}"; done ;;
esac; done
docker buildx rm "$B" >/dev/null 2>&1; echo "# builder $B removed"
