# Disposable KVM VM lab in a container: QEMU + a private bridge, all inside the container's own network namespace.
# Nothing is installed on the host: the container only gets /dev/kvm, /dev/net/tun and CAP_NET_ADMIN (its own netns).
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update -q && apt-get install -y -q --no-install-recommends \
      qemu-system-x86 qemu-utils cloud-image-utils genisoimage openssh-client iproute2 nftables dnsmasq-base \
      ca-certificates curl socat procps iputils-ping python3-minimal \
 && rm -rf /var/lib/apt/lists/*
COPY vmlab.sh /usr/local/bin/vmlab
ENTRYPOINT ["/usr/local/bin/vmlab"]
CMD ["serve"]
