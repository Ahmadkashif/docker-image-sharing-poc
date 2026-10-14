# docker-image-sharing-poc

Build container images on one machine (an Apple Silicon Mac, a Linux workstation or CI) and get them onto an
on-prem Linux server **safely**: multi-arch build (cross-compiled, SBOM + SLSA provenance) → push **by digest** to a
TLS + auth registry → **Grype** scan gate → **cosign** sign (key-based, no public transparency log) → the server
verifies the signature and pulls **its own architecture by digest**. Fallbacks for servers without a registry path:
`docker save --platform | ssh | docker load`, and OCI archives with sha256 + cosign bundle for air-gaps.

This repo is a working proof of concept: the profile-driven kit, a small new app to ship with it, a one-box KVM lab
that stands in for "the server", and the evidence from running all of it.

```
kit/        the kit: bin/img (build|scan|sign|deploy|ship-ssh|bundle|import|export|...), bin/render.py (profile ->
            config), bin/detect-host.sh, registry/ (Zot or Distribution + Docker Hub mirror, internal CA, robots),
            profiles/ (p1-company-registry, p1-selfhosted-registry, p2-lan-only, p3-airgapped, p4-arm64-server,
            verify-* lab profiles), tests/validate.sh. Its own README: kit/README.md
app/pingboard/   a tiny Go HTTP service; its Dockerfile cross-compiles and has NO RUN in the target stage, so
            linux/arm64 builds on an amd64 host (and vice versa) need no QEMU at all
lab/        lab.sh: real Ubuntu 24.04 + Docker Engine 29 KVM VMs inside ONE container (nothing installed on the host)
evidence/   logs of every run (sanitized: no host names/IPs/user names, passwords redacted)
```

Everything runs as pinned tool containers (`kit/VERSIONS.env`); the host needs only Docker (Engine/CLI ≥ 28,
buildx ≥ 0.13), bash, python3, ssh, openssl, curl.

## What was verified, and what was not

Verified 2026-10-14 on one amd64 Linux box (Ubuntu 24.04, Docker Engine 29.8.1, **no QEMU/binfmt**) as the build
machine and real KVM VMs (Ubuntu 24.04, kernel 6.8, Docker Engine 29.9.0) as servers. Logs in `evidence/`.

| What | Status | Evidence |
|---|---|---|
| Kit renders + validates on Linux (`tests/validate.sh`, shellcheck, negative profiles, name-constrained CA, `--check-agnostic`) | VERIFIED | `validate-final.log` |
| Zot 2.1.21 + Distribution 3.1.2 from `registry/compose.yaml`, internal CA, bcrypt robots, loopback-only on the host | VERIFIED (after fix F2) | `q2-registries.log` |
| Read-only robot cannot push on Zot, **can** push on Distribution; new user without restart; retention in dry-run | VERIFIED | `q2-robots.log` |
| Docker Hub pull-through mirror as dockerd mirror and BuildKit mirror | VERIFIED | `q2b-mirror.log` |
| `img release` from a Linux build host: amd64 + arm64 (arm64 with no emulation), SBOM + provenance, push by digest, Grype gate, cosign sign + verify | VERIFIED | `q3c-release.log` |
| `img deploy` → server verifies signature, pulls amd64 by digest, **runs natively** on classic-store and containerd-store servers | VERIFIED | `q3d-deploy-native.log` |
| Unsigned image, wrong key, deploy by tag: all refused | VERIFIED | `q3e-negative.log` |
| Grype gate: an image built with an outdated Go toolchain (26 High/Critical stdlib findings) fails the gate (exit 2) and `release` stops before signing; a failed build stops `release` | VERIFIED (after fix F12) | `q4a-grype-gate.log` |
| `img ship-ssh` (`docker save --platform` \| zstd \| ssh `docker load`) onto a classic-store server: correct arch, runs | VERIFIED | `q5b-ship-ssh.log` |
| Full release + deploy against Distribution 3.1.2 | VERIFIED | `q3f-distribution-release.log` |
| Save/load matrix on real Engine 29.9 (classic vs containerd store) | VERIFIED | `q4-save-load-matrix.log` |
| Switching an existing engine to `containerd-snapshotter: true` hides all images and containers (VM only) | VERIFIED | `q4b-containerd-switch.log` |
| P2: server with no internet (registry ports only): `mirror-tools`, keyed cosign verify offline, deploy by digest | VERIFIED | `q5-p2-offline.log` |
| P3: air-gapped server (no network path at all, media hot-plugged): sha256 + verify-blob, 1-byte tamper refused (also with a recomputed sha256), import keeps digests, `export`/`import` keep cosign signatures | VERIFIED | `q6a-*.log`, `q6b-*.log` |
| Remote BuildKit over SSH; `docker --context` build + run on the server | VERIFIED | `q8-remote-builder-context.log` |
| Build times: native amd64 vs cross-compiled arm64 vs QEMU-emulated arm64 | VERIFIED (measured) | `q7-bench-build-times.log` |
| Forgejo OCI registry smoke test (registry choice) | VERIFIED (smoke) | `q10-forgejo-smoke.log` |
| README-only run of a fresh clone: new app built, signed, shipped, run | VERIFIED at commit `85dde3a` (see `evidence/README-RUN.md`) | `final-readme-run.log` |
| Multi-node builder with a **genuine arm64** node | **NOT RUN** (no arm64 hardware; needs a Mac or arm64 box) | — |
| Mac (Docker Desktop) as the build machine, keychain CA install, Rosetta timings | **NOT RUN** here (this repo's Linux round). An earlier Mac round verified the flows against a simulated server | — |
| A real company server / company registry / company PKI or KMS signing | **NOT RUN** (no access) | — |
| Harbor | **NOT RUN** | — |
| `install-trust.sh` on RHEL-family servers (`update-ca-trust` branch) | **NOT RUN** (only Ubuntu VMs) | — |

Kit fixes found on real Linux hosts (F1–F12) are listed in `evidence/README-RUN.md`.

## Try it on one Linux box (the lab)

Needs: Linux amd64 with KVM (`/dev/kvm`), Docker Engine ≥ 28 with buildx, ~7 GB free RAM, internet. **Nothing is
installed on the host**: the lab is one container (`img-vmlab`) with three VMs inside, one docker network
(`img-vmlab`), SSH forwards on `127.0.0.1:22011-22013` only, and registry ports on `127.0.0.1:5443/5444`. Your
`~/.docker` is not touched (`DOCKER_CONFIG` points into `lab/.host/`). QEMU/binfmt is never registered on the host.

```sh
lab/lab.sh up                      # ~5 min first time: builds the lab image, boots srv-classic/srv-cstore/srv-offline
source lab/.host/env               # this shell only: lab ssh + isolated DOCKER_CONFIG
cd kit
P=verify-linux-vm-lab              # lab profile: registry zot.vmlab:5443 (+ mirror.vmlab:5444), server deploy@srv-cstore

# 1. registry (on this box, loopback-only): internal CA, robots, Zot + Docker Hub mirror
bin/render.py $P
registry/mkcerts.sh build/$P/certs zot.vmlab mirror.vmlab
mkdir -p build/$P/secrets && chmod 700 build/$P/secrets
for u in ci-push server-pull registry-admin; do
  pw=$(openssl rand -hex 16); echo "$u $pw" >> build/$P/secrets/registry-passwords
  registry/add-user.sh build/$P/auth "$u" "$pw"
done
docker compose --env-file build/$P/registry/.env -f registry/compose.yaml up -d

# 2. servers trust the CA (rendered install-trust.sh, run with sudo INSIDE the VMs); srv-cstore also gets daemon.json
../lab/lab.sh trust $P
../lab/lab.sh daemon-json $P srv-cstore
../lab/lab.sh login $P server-pull srv-cstore          # the server logs in with the READ-ONLY robot

# 3. build machine: push robot + signing key (both stay under build/, gitignored)
awk '$1=="ci-push"{print $2}' build/$P/secrets/registry-passwords | bin/img -p $P login ci-push
export COSIGN_PASSWORD=$(openssl rand -hex 24); echo "$COSIGN_PASSWORD" > build/$P/secrets/cosign-password
bin/img -p $P keygen
bin/img -p $P doctor               # client check reports HTTP 000 for zot.vmlab: the lab name only resolves on the lab network

# 4. release + deploy the app
bin/img -p $P release ../app/pingboard pingboard 2.0.0 -- --build-arg VERSION=2.0.0
bin/img -p $P deploy "$(cat build/$P/last/pingboard.ref)" -- --name pingboard -p 8080:8080
ssh deploy@srv-cstore curl -s localhost:8080/        # {"app":"pingboard","version":"2.0.0",...,"goarch":"amd64"}
```

Other flows from the evidence (all with the same kit):
`bin/img -p $P --set SERVER_SSH=deploy@srv-classic deploy <ref@digest>` (classic store) ·
`../lab/lab.sh net srv-offline lan-only` + `bin/img -p $P mirror-tools` + `--set TOOLS_FROM_REGISTRY=yes deploy`
(P2) · profile `verify-linux-vm-lab-p3` with `build`/`scan oci-archive:`/`bundle`/`bundle-tools`, media into an
`airgap`ped VM, `import`, `deploy` (P3) · `--set BUILDER_MODE=remote --set BUILDER_NAME=img-vmlab-remote builder`
(remote BuildKit).

Teardown (keeps the registry volumes; delete them with `docker volume rm` if you want):
```sh
docker compose --env-file build/$P/registry/.env -f registry/compose.yaml down
bin/img -p $P builder rm
../lab/lab.sh destroy              # VMs, lab container, lab image, lab network, lab/.host (incl. lab logins)
docker volume rm img-grype-db      # Grype vulnerability DB cache
rm -rf ../lab/.state               # Ubuntu cloud image cache (~600 MB)
# tool images pulled on first use (zot, registry, buildkit, oras, regctl, skopeo, httpd, golang, ...): docker image rm
```

## Using it for a real server

Copy the closest profile (`kit/profiles/p1-*.env` … `p4-*.env`), fill in names, `bin/render.py <profile>`, follow
`build/<profile>/RUNBOOK.md`. The kit's README (`kit/README.md`) has the profile table and the gotchas. Never apply
the rendered `server/daemon.json` to a server that already runs workloads on the classic store without planning it:
switching the image store hides every existing image and container (see `evidence/q4b-containerd-switch.log`).

## Left out on purpose

No secrets, keys, certificates, htpasswd files, `.env` files or passwords are in this repo — all of them are
generated locally under `kit/build/` (gitignored). Logs were sanitized: the lab host's name, user name, paths and
non-lab IP addresses were replaced with placeholders; lab-internal names (`*.vmlab`, `srv-*`, `10.77.0.0/24`) are
made up for the lab.

## License

MIT — see `LICENSE`.
