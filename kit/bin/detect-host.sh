#!/usr/bin/env bash
# Report what this machine can do for building / receiving images, on macOS (Docker Desktop, colima, OrbStack) or Linux.
# Self-contained (no other files needed), so it can be piped to a server:  ssh server bash -s -- --facts < detect-host.sh
#
#   detect-host.sh                           -> human-readable facts + warnings
#   detect-host.sh --facts                   -> KEY=VALUE only
#   detect-host.sh --registry host[:port]    -> also probe https://<registry>/v2/ (CA from /etc/docker/certs.d or --ca)
#   detect-host.sh --ca <ca.crt>             -> CA to use for the registry probe
#   detect-host.sh --check <profile.env|-> [--role client|server]
#                                            -> compare with the profile's minimums; exit 0 ok, 3 not met
# bash 3.2 compatible (macOS /bin/bash).
set -uo pipefail
MODE=table; REG=""; CA=""; PROFILE=""; ROLE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --facts) MODE=facts;;
    --registry) REG="${2:?}"; shift;;
    --ca) CA="${2:?}"; shift;;
    --check) MODE=check; PROFILE="${2:?profile.env}"; shift;;
    --role) ROLE="${2:?client|server}"; shift;;
    -h|--help) sed -n '2,13p' "$0" 2>/dev/null || true; exit 0;;
    *) echo "unknown arg $1" >&2; exit 2;;
  esac; shift
done
if [ -n "$PROFILE" ]; then
  # "--check -" = the profile's KEY=VALUE lines were prepended to this script (how `img doctor` runs it over SSH)
  # shellcheck disable=SC1090
  [ "$PROFILE" != - ] && . "$PROFILE"
  [ -z "$REG" ] && REG="${REGISTRY:-}"
  if [ -z "$CA" ] && [ -n "${REGISTRY_CA_FILE:-}" ]; then
    case "$REGISTRY_CA_FILE" in /*) CA="$REGISTRY_CA_FILE";; *) CA="${PROFILE_DIR:-.}/$REGISTRY_CA_FILE";; esac
    [ -f "$CA" ] || CA=""   # not on this machine (e.g. running on the server): fall back to /etc/docker/certs.d
  fi
fi

norm_arch() { case "$1" in x86_64|amd64) echo amd64;; aarch64|arm64) echo arm64;; armv7l|armhf) echo arm/v7;; *) echo "$1";; esac; }
have() { command -v "$1" >/dev/null 2>&1; }

OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH="$(norm_arch "$(uname -m)")"
if [ "$OS" = darwin ]; then
  DISTRO="macos-$(sw_vers -productVersion 2>/dev/null || echo '?')"
  CPUS="$(sysctl -n hw.ncpu)"; RAM_GB="$(awk -v b="$(sysctl -n hw.memsize)" 'BEGIN{printf "%.0f", b/1073741824}')"
else
  DISTRO="$( (. /etc/os-release 2>/dev/null && echo "${ID:-linux}-${VERSION_ID:-?}") || echo linux)"
  CPUS="$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN)"; RAM_GB="$(awk '/MemTotal/{printf "%.0f", $2/1048576}' /proc/meminfo)"
fi
[ -z "$ROLE" ] && { [ "$OS" = darwin ] && ROLE=client || ROLE=server; }

DOCKER_CLIENT=absent; DOCKER_SERVER=absent; D_ARCH=""; D_OS=""; STORAGE=""; CSTORE=no; ROOTLESS=no; INSECURE=""; MIRRORS=""; ROOTDIR=""
if have docker; then
  DOCKER_CLIENT="$(docker version --format '{{.Client.Version}}' 2>/dev/null || echo '?')"
  if info="$(docker info --format '{{.ServerVersion}}|{{.Architecture}}|{{.OperatingSystem}}|{{.Driver}}|{{json .DriverStatus}}|{{json .SecurityOptions}}|{{json .RegistryConfig.IndexConfigs}}|{{json .RegistryConfig.Mirrors}}|{{.DockerRootDir}}' 2>/dev/null)"; then
    IFS='|' read -r DOCKER_SERVER D_ARCH D_OS STORAGE DSTAT SECOPT IDX MIRRORS ROOTDIR <<EOF
$info
EOF
    D_ARCH="$(norm_arch "$D_ARCH")"
    case "$DSTAT" in *io.containerd.snapshotter*) CSTORE=yes;; esac
    case "$STORAGE" in overlayfs|stargz|zfs-snapshotter) CSTORE=yes;; esac
    case "$SECOPT" in *rootless*) ROOTLESS=yes;; esac
    # insecure registries (exclude the loopback defaults and Docker Desktop's internal hub proxy)
    INSECURE="$(printf '%s' "$IDX" | tr '{' '\n' | awk -F'"' '/"Secure":false/{print $4}' | grep -v -E '^(127\.|localhost|::1|hubproxy\.docker\.internal)' | tr '\n' ' ' | sed 's/ $//')"
    MIRRORS="$(printf '%s' "$MIRRORS" | tr -d '[]"' )"
  else
    DOCKER_SERVER=unreachable
  fi
fi
BUILDX=absent; BUILDER_PLATFORMS=""; EMU_AMD64=no; EMU_ARM64=no
if [ "$DOCKER_CLIENT" != absent ] && docker buildx version >/dev/null 2>&1; then
  BUILDX="$(docker buildx version | awk '{print $2}' | sed 's/^v//')"
  BUILDER_PLATFORMS="$(docker buildx inspect 2>/dev/null | awk -F': *' '/^Platforms:/{print $2; exit}' | tr -d ' ')"
  case ",$BUILDER_PLATFORMS," in *,linux/amd64,*|*,linux/amd64\**) EMU_AMD64=yes;; esac
  case ",$BUILDER_PLATFORMS," in *,linux/arm64,*|*,linux/arm64\**) EMU_ARM64=yes;; esac
fi
ROSETTA=n/a
if [ "$OS" = darwin ]; then
  f="$HOME/Library/Group Containers/group.com.docker/settings-store.json"
  if [ -f "$f" ]; then grep -q '"UseVirtualizationFrameworkRosetta": *true' "$f" && ROSETTA=on || ROSETTA=off; fi
fi
DISK_FREE_GB=""
if [ "$OS" = linux ] && [ -n "$ROOTDIR" ] && [ -d "$ROOTDIR" ]; then DISK_FREE_GB="$(df -Pk "$ROOTDIR" 2>/dev/null | awk 'NR==2{printf "%.0f", $4/1048576}')"; fi
[ -z "$DISK_FREE_GB" ] && DISK_FREE_GB="$(df -Pk "$HOME" 2>/dev/null | awk 'NR==2{printf "%.0f", $4/1048576}')"
SSH=no; have ssh && SSH=yes
ZSTD=no; have zstd && ZSTD=yes

probe() { # url [cafile] -> http code (000 = unreachable / TLS failure)
  if have curl; then
    if [ -n "${2:-}" ]; then curl -s -o /dev/null -m 8 -w '%{http_code}' --cacert "$2" "$1" 2>/dev/null || true
    else curl -s -o /dev/null -m 8 -w '%{http_code}' "$1" 2>/dev/null || true; fi
  elif have wget; then
    wget -q -T 8 -O /dev/null ${2:+--ca-certificate="$2"} "$1" 2>&1 | grep -q '401' && echo 401 || echo "?"
  else echo "?"; fi
}
REG_HTTP=""; REG_TLS=""
if [ -n "$REG" ]; then
  cafile="$CA"; [ -z "$cafile" ] && [ -f "/etc/docker/certs.d/$REG/ca.crt" ] && cafile="/etc/docker/certs.d/$REG/ca.crt"
  REG_HTTP="$(probe "https://$REG/v2/" "$cafile")"
  REG_TLS=verified; [ "$REG_HTTP" = 000 ] && REG_TLS="failed-or-unreachable"
fi
HUB_HTTP="$(probe https://registry-1.docker.io/v2/)"

facts() {
  cat <<EOF
ROLE=$ROLE
HOST_OS=$OS
HOST_ARCH=$ARCH
DISTRO=$DISTRO
CPUS=$CPUS
RAM_GB=$RAM_GB
DOCKER_CLIENT=$DOCKER_CLIENT
DOCKER_SERVER=$DOCKER_SERVER
DOCKER_SERVER_OS=$D_OS
DOCKER_SERVER_ARCH=$D_ARCH
STORAGE_DRIVER=$STORAGE
CONTAINERD_IMAGE_STORE=$CSTORE
ROOTLESS=$ROOTLESS
INSECURE_REGISTRIES=$INSECURE
REGISTRY_MIRRORS=$MIRRORS
BUILDX=$BUILDX
BUILDER_PLATFORMS=$BUILDER_PLATFORMS
CAN_BUILD_AMD64=$EMU_AMD64
CAN_BUILD_ARM64=$EMU_ARM64
ROSETTA=$ROSETTA
DISK_FREE_GB=$DISK_FREE_GB
SSH_CLIENT=$SSH
ZSTD=$ZSTD
REGISTRY=$REG
REGISTRY_HTTP=$REG_HTTP
REGISTRY_TLS=$REG_TLS
DOCKERHUB_HTTP=$HUB_HTTP
EOF
}

vge() { # version >= min  (numeric dotted compare)
  awk -v a="$1" -v b="$2" 'BEGIN{n=split(a,x,".");m=split(b,y,".");for(i=1;i<=(n>m?n:m);i++){p=x[i]+0;q=y[i]+0;if(p>q)exit 0;if(p<q)exit 1}exit 0}'
}
WARN=""; FAIL=""
warn() { WARN="$WARN
  WARN  $*"; }
fail() { FAIL="$FAIL
  FAIL  $*"; }
evaluate() {
  [ "$DOCKER_SERVER" = absent ] || [ "$DOCKER_SERVER" = unreachable ] && fail "docker daemon $DOCKER_SERVER"
  [ -n "$INSECURE" ] && warn "insecure-registries configured: $INSECURE (use an internal CA instead)"
  [ "$REG_HTTP" = 200 ] && warn "registry $REG answers /v2/ with 200 without credentials: auth is OFF"
  if [ -n "$REG" ]; then case "$REG_HTTP" in 401|200) ;; *) fail "registry $REG not reachable over verified TLS (HTTP $REG_HTTP)";; esac; fi
  [ "$ROLE" = server ] && [ "$ROOTLESS" = no ] && warn "rootful docker: members of the docker group are root-equivalent"
  if [ -n "$PROFILE" ]; then
    local sa="${SERVER_ARCH:-}"
    if [ "$ROLE" = client ]; then
      vge "${DOCKER_CLIENT%%-*}" "${MIN_CLIENT_DOCKER:-0}" || fail "docker client $DOCKER_CLIENT < ${MIN_CLIENT_DOCKER}"
      [ "$BUILDX" = absent ] && fail "docker buildx missing" || { vge "$BUILDX" "${MIN_BUILDX:-0}" || fail "buildx $BUILDX < $MIN_BUILDX"; }
      case ",${BUILD_PLATFORMS:-}," in
        *linux/amd64*) [ "$D_ARCH" != amd64 ] && [ "$EMU_AMD64" = no ] && [ "${BUILDER_MODE:-local}" = local ] && fail "cannot build linux/amd64 here (no emulation): use BUILDER_MODE=remote|multinode";;
      esac
      case ",${BUILD_PLATFORMS:-}," in
        *linux/arm64*) [ "$D_ARCH" != arm64 ] && [ "$EMU_ARM64" = no ] && [ "${BUILDER_MODE:-local}" = local ] && warn "no arm64 emulation here: linux/arm64 builds only work if the Dockerfile's TARGET stage has no RUN (cross-compile + COPY onto distroless/scratch); else use BUILDER_MODE=multinode with an arm64 node";;
      esac
      [ "$D_ARCH" = arm64 ] && [ "$sa" = amd64 ] && [ "${BUILDER_MODE:-local}" = local ] && warn "amd64 builds run under emulation here (QEMU${ROSETTA:+/rosetta=$ROSETTA}); cross-compile in the Dockerfile or use BUILDER_MODE=multinode for speed"
      [ "$CSTORE" = no ] && warn "classic image store: multi-platform --load is impossible; img uses a docker-container builder + registry/OCI output"
    else
      vge "${DOCKER_SERVER%%-*}" "${MIN_SERVER_DOCKER:-0}" || fail "docker engine $DOCKER_SERVER < ${MIN_SERVER_DOCKER}"
      [ -n "$sa" ] && [ "$D_ARCH" != "$sa" ] && fail "daemon arch $D_ARCH != profile SERVER_PLATFORM $SERVER_PLATFORM"
      [ "${REQUIRE_SERVER_CONTAINERD_STORE:-no}" = yes ] && [ "$CSTORE" = no ] && fail "containerd image store required (server/daemon.json)"
      [ "$CSTORE" = no ] && warn "classic image store: docker load keeps only one platform of a multi-arch archive; fine for running"
      [ -n "$DISK_FREE_GB" ] && [ "${MIN_SERVER_DISK_GB:-0}" -gt "${DISK_FREE_GB:-0}" ] 2>/dev/null && fail "free disk ${DISK_FREE_GB}GB < ${MIN_SERVER_DISK_GB}GB"
      [ "${SERVER_INTERNET:-}" = yes ] && [ "$HUB_HTTP" != 401 ] && warn "profile says the server has internet but Docker Hub is not reachable (HTTP $HUB_HTTP)"
      [ "${SERVER_INTERNET:-}" = no ] && [ "$HUB_HTTP" = 401 ] && warn "profile says no internet but Docker Hub IS reachable"
    fi
  fi
}

case "$MODE" in
  facts) facts ;;
  table|check)
    evaluate
    if [ "$MODE" = table ]; then
      facts | sed 's/^/  /'
    fi
    printf '%s\n' "role=$ROLE arch=$ARCH docker=$DOCKER_SERVER($D_ARCH, containerd-store=$CSTORE) buildx=$BUILDX${REG:+ registry=$REG:$REG_HTTP}"
    [ -n "$WARN" ] && printf '%s\n' "$WARN"
    if [ -n "$FAIL" ]; then printf '%s\n' "$FAIL"; echo "RESULT=NOT-MET"; [ "$MODE" = check ] && exit 3; exit 0; fi
    echo "RESULT=OK" ;;
esac
