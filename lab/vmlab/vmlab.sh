#!/bin/bash
# vmlab — disposable Ubuntu 24.04 + Docker Engine KVM VMs inside one container (own netns: bridge, NAT, nftables).
#   serve                                    bridge br0 10.77.0.1/24, dnsmasq (-> docker DNS), NAT, ssh port forwards
#   up <name> <octet> <mem-MB> <cpus> <classic|containerd>   create + boot a VM (cloud-init installs Docker Engine 29)
#   net <name> <internet|lan-only|airgap>    per-VM egress policy (nftables in this container's netns only)
#   media <name> <file.iso>                  hot-plug an ISO as a USB-stick stand-in (sneakernet)
#   down <name> | rm <name> | ls
# State: /state (VM disks, keys, logs). Base image: /state/cache/noble-server-cloudimg-amd64.img
set -euo pipefail
S=/state; BASE="$S/cache/noble-server-cloudimg-amd64.img"; NET=10.77.0
mkdir -p "$S/vms"
vmdir() { echo "$S/vms/$1"; }
octet() { cat "$(vmdir "$1")/octet"; }
mac() { printf '52:54:00:77:00:%02x' "$1"; }

nft_base() {
  local regnet; regnet="$(ip -4 route show dev eth0 scope link | awk '{print $1; exit}')"
  # never "flush ruleset": Docker's embedded-DNS DNAT rules for 127.0.0.11 live in this netns too
  nft delete table ip labnat 2>/dev/null || true; nft delete table inet lab 2>/dev/null || true; nft delete table bridge labbr 2>/dev/null || true
  nft -f - <<EOF
table ip labnat {
  chain post {
    type nat hook postrouting priority 100; policy accept;
    oifname "eth0" ip saddr $NET.0/24 masquerade
  }
}
table inet lab {
  set lanonly { type ipv4_addr; }
  set airgap  { type ipv4_addr; }
  chain lab_forward { type filter hook forward priority 0; policy accept;
    ip saddr @airgap drop
    ip daddr @airgap drop
    ct state established,related accept
    ip saddr @lanonly ip daddr $regnet tcp dport { 5443, 5444 } accept
    ip saddr @lanonly counter drop
  }
  chain lab_input { type filter hook input priority 0; policy accept;
    ip saddr @airgap ct state established,related accept
    ip saddr @airgap counter drop
  }
}
table bridge labbr {
  set airgapmac { type ether_addr; }
  chain lab_forward { type filter hook forward priority 0; policy accept;
    ether saddr @airgapmac counter drop
    ether daddr @airgapmac counter drop
  }
}
EOF
  echo "$regnet" > "$S/regnet"
}

cmd_serve() {
  ip link add br0 type bridge 2>/dev/null || true
  ip addr add "$NET.1/24" dev br0 2>/dev/null || true
  ip link set br0 up
  nft_base
  dnsmasq --interface=br0 --bind-interfaces --except-interface=lo --no-resolv --server=127.0.0.11 --no-hosts \
    --domain-needed --log-facility=/state/dnsmasq.log --pid-file=/run/dnsmasq.pid
  for i in 11 12 13 14; do socat "TCP-LISTEN:220$i,fork,reuseaddr" "TCP:$NET.$i:22" & done
  echo "vmlab ready: br0 $NET.1/24, egress via eth0 $(cat "$S/regnet")"
  # restart VMs that were running (container restart)
  exec sleep infinity
}

cmd_up() {
  local n="${1:?name}" o="${2:?octet}" mem="${3:-2048}" cpus="${4:-2}" store="${5:-containerd}" d; d="$(vmdir "$n")"
  mkdir -p "$d"; echo "$o" > "$d/octet"
  [ -f "$S/lab_ed25519" ] || ssh-keygen -q -t ed25519 -N '' -C vmlab -f "$S/lab_ed25519"
  local pub; pub="$(cat "$S/lab_ed25519.pub")"
  if [ ! -f "$d/disk.qcow2" ]; then
    qemu-img create -q -f qcow2 -F qcow2 -b "$BASE" "$d/disk.qcow2" 25G
    local daemon=""; [ "$store" = classic ] && daemon='mkdir -p /etc/docker && printf "%s\n" "{\"features\":{\"containerd-snapshotter\":false}}" > /etc/docker/daemon.json'
    cat > "$d/user-data" <<EOF
#cloud-config
hostname: $n
manage_etc_hosts: true
ssh_pwauth: false
users:
  - name: ops
    groups: [sudo]
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    shell: /bin/bash
    ssh_authorized_keys: ["$pub"]
  - name: deploy
    shell: /bin/bash
    ssh_authorized_keys: ["$pub"]
write_files:
  - path: /usr/local/sbin/lab-install-docker
    permissions: "0755"
    content: |
      #!/bin/sh
      set -eux
      $daemon
      install -m 0755 -d /etc/apt/keyrings
      curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
      echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu noble stable" > /etc/apt/sources.list.d/docker.list
      apt-get update -q
      v=\$(apt-cache madison docker-ce | awk '\$3 ~ /^5:29\\./ {print \$3; exit}')
      DEBIAN_FRONTEND=noninteractive apt-get install -y -q docker-ce=\$v docker-ce-cli=\$v containerd.io docker-buildx-plugin zstd
      groupadd -f docker; usermod -aG docker deploy
      systemctl enable --now docker
      touch /var/lib/lab-docker-ready
runcmd:
  - [/usr/local/sbin/lab-install-docker]
EOF
    cat > "$d/network-config" <<EOF
version: 2
ethernets:
  id0:
    match: { macaddress: "$(mac "$o")" }
    addresses: [$NET.$o/24]
    routes: [{ to: default, via: $NET.1 }]
    nameservers: { addresses: [$NET.1] }
EOF
    printf 'instance-id: %s\nlocal-hostname: %s\n' "$n-$(date +%s)" "$n" > "$d/meta-data"
    cloud-localds -N "$d/network-config" "$d/seed.iso" "$d/user-data" "$d/meta-data"
  fi
  ip tuntap add "tap-$n" mode tap 2>/dev/null || true
  ip link set "tap-$n" master br0 up
  qemu-system-x86_64 -name "$n" -machine q35,accel=kvm -cpu host -m "$mem" -smp "$cpus" \
    -drive "file=$d/disk.qcow2,if=virtio,cache=unsafe,discard=unmap" -drive "file=$d/seed.iso,if=virtio,media=cdrom,readonly=on" \
    -netdev "tap,id=n0,ifname=tap-$n,script=no,downscript=no" -device "virtio-net-pci,netdev=n0,mac=$(mac "$o")" \
    -device qemu-xhci,id=xhci -display none -serial "file:$d/console.log" \
    -monitor "unix:$d/monitor.sock,server,nowait" -pidfile "$d/qemu.pid" -daemonize
  echo "$n up: $NET.$o (ssh port 220$o on the container), store=$store"
}

cmd_net() {
  local n="${1:?name}" mode="${2:?internet|lan-only|airgap}" ip; ip="$NET.$(octet "$n")"
  local m; m="$(mac "$(octet "$n")")"
  nft delete element inet lab lanonly "{ $ip }" 2>/dev/null || true
  nft delete element inet lab airgap "{ $ip }" 2>/dev/null || true
  nft delete element bridge labbr airgapmac "{ $m }" 2>/dev/null || true
  case "$mode" in
    internet) ;;
    lan-only) nft add element inet lab lanonly "{ $ip }" ;;
    airgap)   nft add element inet lab airgap "{ $ip }"; nft add element bridge labbr airgapmac "{ $m }" ;;
  esac
  echo "$n ($ip) egress policy: $mode"
}

cmd_media() {
  local n="${1:?name}" iso="${2:?iso}" sock; sock="$(vmdir "$n")/monitor.sock"
  id="m$(basename "$iso" .iso)"; printf "drive_add 0 if=none,id=%s,file=%s,media=cdrom,readonly=on\ndevice_add usb-storage,bus=xhci.0,drive=%s,id=%s-dev\n" "$id" "$iso" "$id" "$id" \
    | socat - "UNIX-CONNECT:$sock" >/dev/null
  echo "$n: attached $iso as a USB mass-storage device"
}

cmd_down() { local d; d="$(vmdir "${1:?}")"; [ -S "$d/monitor.sock" ] && echo system_powerdown | socat - "UNIX-CONNECT:$d/monitor.sock" >/dev/null || true; }
cmd_rm() { local d; d="$(vmdir "${1:?}")"; [ -f "$d/qemu.pid" ] && kill "$(cat "$d/qemu.pid")" 2>/dev/null || true; rm -rf "$d"; ip link del "tap-$1" 2>/dev/null || true; }
cmd_ls() { for d in "$S"/vms/*/; do n="$(basename "$d")"; p="$(cat "$d/qemu.pid" 2>/dev/null || true)"; printf '%-14s %s.%s %s\n' "$n" "$NET" "$(cat "$d/octet")" "$([ -n "$p" ] && kill -0 "$p" 2>/dev/null && echo running || echo stopped)"; done; }

c="${1:-serve}"; shift || true
case "$c" in serve|up|net|media|down|rm|ls) "cmd_$c" "$@";; *) exec "$c" "$@";; esac
