#!/usr/bin/env bash
# lab.sh — a disposable "real Linux server" lab on ONE Linux box, with nothing installed on the host.
# Real KVM guests (Ubuntu 24.04 + Docker Engine 29 from download.docker.com) run inside one container (QEMU, private
# bridge, NAT, dnsmasq, nftables — all in the container's own network namespace). Needs: Docker, /dev/kvm usable by
# dockerd (it is root), ~7 GB RAM free, internet for the first boot.
#
#   lab/lab.sh up                    build the lab image, boot srv-classic / srv-cstore / srv-offline, wait for Docker
#   source lab/.host/env             lab ssh wrapper + isolated DOCKER_CONFIG for THIS shell (no global changes)
#   lab/lab.sh trust <profile>       copy the profile's CA + rendered install-trust.sh into every VM and run it (sudo, VM)
#   lab/lab.sh daemon-json <profile> <vm>   apply the rendered server/daemon.json in a VM and restart its dockerd
#   lab/lab.sh login <profile> <user> <vm>  docker login on the VM (deploy user) with a robot from build/<p>/secrets
#   lab/lab.sh net <vm> internet|lan-only|airgap   egress policy of a VM
#   lab/lab.sh ls | down | destroy
#
# Lab names: VMs srv-classic (classic overlay2 store), srv-cstore (containerd store), srv-offline; users ops (sudo) and
# deploy (docker group only = the kit's deploy user). SSH reaches them through 127.0.0.1:22011-22013 only.
set -euo pipefail
LAB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIT="${KIT:-$( { [ -d "$LAB/../kit" ] && cd "$LAB/../kit"; } || cd "$LAB/../templates"; pwd)}"
H="$LAB/.host"; NETNAME="img-vmlab"; C="img-vmlab"
die() { echo "lab: $*" >&2; exit 1; }
vssh() { env -u DOCKER_HOST -u DOCKER_CONTEXT ssh -F "$H/ssh_config" "$@"; }
put() { vssh "$2" "cat > '$3'" < "$1"; }
VMS="srv-classic:11:2048:2:classic srv-cstore:12:3072:4:containerd srv-offline:13:2048:2:containerd"

write_host_files() {
  mkdir -p "$H/bin" "$H/docker-config" "${TMPDIR:-/tmp}/img-lab-cm"; chmod 700 "$H" "$H/docker-config" "${TMPDIR:-/tmp}/img-lab-cm"
  docker exec "$C" cat /state/lab_ed25519 > "$H/lab_ed25519"; chmod 600 "$H/lab_ed25519"
  { echo "# lab-only ssh config (used via $H/bin/ssh; never merged into ~/.ssh/config)"
    for v in $VMS; do IFS=: read -r n o _ <<<"$v"; printf 'Host %s\n  HostName 127.0.0.1\n  Port 220%s\n' "$n" "$o"; done
    printf 'Host srv-*\n  IdentityFile %s\n  IdentitiesOnly yes\n  UserKnownHostsFile %s\n  StrictHostKeyChecking accept-new\n' "$H/lab_ed25519" "$H/known_hosts"
    printf '  ControlMaster auto\n  ControlPath %s/%%C\n  ControlPersist 10m\n  ServerAliveInterval 30\n' "${TMPDIR:-/tmp}/img-lab-cm"; } > "$H/ssh_config"
  # docker's ssh:// transport and img call plain `ssh`: the wrapper pins the lab config and never lets DOCKER_HOST or
  # DOCKER_CONTEXT leak into anything ssh starts (the Mac lab's fork-bomb lesson)
  printf '#!/bin/sh\nexec env -u DOCKER_HOST -u DOCKER_CONTEXT /usr/bin/ssh -F %s "$@"\n' "$H/ssh_config" > "$H/bin/ssh"; chmod +x "$H/bin/ssh"
  cat > "$H/env" <<EOF
# source me: lab wiring for this shell only
export PATH="$H/bin:\$PATH"
export DOCKER_CONFIG="$H/docker-config"     # lab registry logins never touch ~/.docker
unset DOCKER_HOST DOCKER_CONTEXT
EOF
}

cmd_up() {
  [ -r /dev/kvm ] || echo "lab: note: /dev/kvm not readable by you; dockerd (root) passes it to the lab container anyway" >&2
  [ -e /dev/kvm ] || die "/dev/kvm missing: enable virtualization (KVM) on this host"
  docker network inspect "$NETNAME" >/dev/null 2>&1 || docker network create --label img-lab=1 "$NETNAME" >/dev/null
  mkdir -p "$LAB/.state/cache"
  local img="$LAB/.state/cache/noble-server-cloudimg-amd64.img"
  if [ ! -f "$img" ]; then
    echo "lab: downloading the Ubuntu 24.04 cloud image (~600 MB)"
    curl -fsSL -o "$img.part" https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img
    sum="$(curl -fsSL https://cloud-images.ubuntu.com/noble/current/SHA256SUMS | awk '/noble-server-cloudimg-amd64.img$/{print $1}')"
    echo "$sum  $img.part" | sha256sum -c - >/dev/null || die "cloud image checksum mismatch"; mv "$img.part" "$img"
  fi
  docker compose --progress quiet -f "$LAB/compose.yaml" up -d --build
  for _ in $(seq 1 30); do docker logs "$C" 2>&1 | grep -q 'vmlab ready' && break; sleep 1; done
  for v in $VMS; do IFS=: read -r n o m c s <<<"$v"
    if docker exec "$C" vmlab ls 2>/dev/null | grep -q "^$n .* running"; then echo "lab: $n already running"; else docker exec "$C" vmlab up "$n" "$o" "$m" "$c" "$s"; fi
  done
  write_host_files
  for v in $VMS; do IFS=: read -r n _ <<<"$v"; printf 'lab: waiting for Docker Engine in %s ' "$n"
    for _ in $(seq 1 120); do vssh -o ConnectTimeout=3 -o BatchMode=yes "ops@$n" 'test -f /var/lib/lab-docker-ready' 2>/dev/null && break; printf .; sleep 5; done
    vssh "ops@$n" 'test -f /var/lib/lab-docker-ready' || die "$n: Docker not installed (see /var/log/cloud-init-output.log in the VM)"
    echo " $(vssh "deploy@$n" 'docker version --format "Engine {{.Server.Version}}"; docker info --format "{{.Driver}}"' | tr '\n' ' ')"
  done
  echo "lab: up. Next:  source $H/env"
}

cmd_trust() { local p="${1:?profile}" b="$KIT/build/$1"; [ -f "$b/certs/ca.crt" ] || die "no $b/certs/ca.crt (run registry/mkcerts.sh first)"
  for v in $VMS; do IFS=: read -r n _ <<<"$v"
    put "$b/certs/ca.crt" "ops@$n" "/tmp/ca-$p.crt"; put "$b/server/install-trust.sh" "ops@$n" "/tmp/install-trust-$p.sh"
    echo "== $n: sudo sh install-trust.sh ca.crt   (rendered for $p)"; vssh "ops@$n" "sudo sh /tmp/install-trust-$p.sh /tmp/ca-$p.crt 2>&1 | grep -v rehash:"
  done; }
cmd_daemon_json() { local p="${1:?profile}" n="${2:?vm}"; put "$KIT/build/$p/server/daemon.json" "ops@$n" /tmp/daemon.json
  vssh "ops@$n" 'sudo install -m 0644 /tmp/daemon.json /etc/docker/daemon.json && sudo systemctl restart docker && sudo docker info --format "store={{.Driver}} mirrors={{json .RegistryConfig.Mirrors}}"'; }
cmd_login() { local p="${1:?profile}" u="${2:?user}" n="${3:?vm}" reg; reg="$(python3 "$KIT/bin/render.py" --get "$p" REGISTRY)"
  awk -v u="$u" '$1==u{print $2}' "$KIT/build/$p/secrets/registry-passwords" | vssh "deploy@$n" "docker login -u $u --password-stdin $reg 2>&1 | grep -E 'Succeeded|rror'"; }
cmd_net() { docker exec "$C" vmlab net "$@"; }
cmd_ls() { docker exec "$C" vmlab ls; }
cmd_down() { for v in $VMS; do IFS=: read -r n _ <<<"$v"; docker exec "$C" vmlab down "$n" 2>/dev/null || true; done; sleep 20; docker compose -f "$LAB/compose.yaml" stop; }
cmd_destroy() {
  docker exec "$C" sh -c 'for d in /state/vms/*/; do n=$(basename "$d"); vmlab rm "$n"; done; rm -rf /state/vms /state/media /state/lab_ed25519* /state/dnsmasq.log /state/regnet' 2>/dev/null || true
  docker compose -f "$LAB/compose.yaml" down --rmi all 2>/dev/null || true
  docker network rm "$NETNAME" >/dev/null 2>&1 || true; rm -rf "$H"; echo "lab: destroyed (cloud image cache kept in $LAB/.state/cache)"; }

c="${1:-}"; shift || true
case "$c" in up|trust|login|net|ls|down|destroy) "cmd_$c" "$@";; daemon-json) cmd_daemon_json "$@";; *) sed -n '2,17p' "$0"; exit 2;; esac
