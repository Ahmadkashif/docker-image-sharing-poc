# img — build on a Mac (or any Linux box), ship to a Linux server

Profile-driven templates for building multi-arch images from Apple Silicon (or a Linux workstation/CI) and getting
them onto an on-prem Linux server — through a registry, over SSH, or on removable media. Nothing here is tuned to one
machine: pick a profile, fill in names, render, run. The full guide (decision tree, trade-offs, security, day-2) is
`../README.md` (repo root).

```
profiles/*.env        one file per situation (edit a copy; KEY=VALUE, comments allowed)
VERSIONS.env          pinned tool images (multi-arch)
bin/render.py         profile -> build/<profile>/ (profile.env, buildkitd.toml, ssh_config, server/daemon.json,
                      server/install-trust.sh, registry/.env, registry/zot-config.json, RUNBOOK.md)
bin/detect-host.sh    what can this machine / the server do? (arch, docker, containerd store, buildx, emulation,
                      insecure registries, registry TLS+auth probe, internet) — macOS + Linux, bash 3.2+
bin/img               doctor | login | keygen | builder | build | scan | sign | verify | release | deploy |
                      ship-ssh | bundle | import | export | mirror-tools | bundle-tools
registry/             compose.yaml (Zot or Distribution with TLS + auth, optional Docker Hub mirror),
                      mkcerts.sh (name-constrained internal CA), add-user.sh (bcrypt robots), gc.sh
examples/             Dockerfile cross-compile pattern (+ per-language notes)
tests/validate.sh     render + lint + config-check every profile, no side effects
```

## Profiles

| Profile | Server | Internet on server | Registry | Transport |
|---|---|---|---|---|
| `p1-company-registry` | amd64 | yes | existing company registry | build → push → server pulls by digest |
| `p1-selfhosted-registry` | amd64 | yes | Zot on the server/LAN (+ Docker Hub mirror) | same |
| `p2-lan-only` | amd64 | **no** | Zot on the server; tools mirrored into it | same, `mirror-tools` first |
| `p3-airgapped` | amd64 | **no path at all** | inside Zot (or none) | multi-arch OCI archive + sha256 + cosign bundle on media |
| `p4-arm64-server` | **arm64** | yes | Zot | same as P1, no emulation needed |
| `verify-mac-lab*` | simulated (dind) | lab | lab | Mac-round verification profiles |
| `verify-linux-vm-lab*` | real KVM VMs | lab (`-p3`: air-gapped) | lab Zot / Distribution | Linux-round verification profiles (one-box lab) |

Minimums per role are in each profile (`MIN_*`) and checked by `bin/detect-host.sh --check` / `img doctor`.
Requirements table: `../README.md` (repo root) §8.

## Quick start (P1, self-hosted registry)

```sh
cp profiles/p1-selfhosted-registry.env profiles/acme.env      # edit: SERVER_SSH, REGISTRY_HOST, REGISTRY_BIND, users
bin/render.py acme                                            # -> build/acme/
cat build/acme/RUNBOOK.md                                     # the exact commands for this profile, in order

# registry host (once)
registry/mkcerts.sh build/acme/certs <registry-host>          # or drop company-CA-issued certs into certs/tls/
registry/add-user.sh build/acme/auth ci-push                  # prints a generated password once
registry/add-user.sh build/acme/auth server-pull
docker compose --env-file build/acme/registry/.env -f registry/compose.yaml up -d

# trust the CA: Mac keychain (Docker Desktop), buildx (automatic via buildkitd.toml), server (install-trust.sh)
bin/img -p acme login ci-push < pw-file                       # Linux build host: daemon-free login (no certs.d/sudo);
                                                              # on a Mac `docker login` works too
bin/img -p acme doctor                                        # both ends + registry, against the profile minimums
COSIGN_PASSWORD=… bin/img -p acme keygen
bin/img -p acme release ./myapp myapp 1.2.3                   # build+push amd64+arm64, grype gate, cosign sign+verify
bin/img -p acme deploy <registry>/team/myapp@sha256:…         # server: verify signature, pull amd64 by digest
```

## Notes that bite

- Mount **directories** for certs/htpasswd (compose does): single-file bind mounts go stale when a file is replaced.
- Zot needs `http.compat: ["docker2s2"]` (rendered) to accept Docker-format manifests from plain `docker push`.
- Multi-node builds (`BUILDER_MODE=multinode`) assemble the final index **on your machine**: it must resolve and
  trust the registry (keychain CA on macOS).
- `docker save` of a multi-arch image into a **classic-store** server loads the *saving* machine's architecture.
  `img ship-ssh` always passes `--platform $SERVER_PLATFORM`.
- On macOS the first `docker login` stores credentials in the keychain helper; `img` reads them from there and hands
  tool containers a 0600 temp file that is deleted on exit.
- Never `insecure-registries`; never publish the registry on `0.0.0.0` of an internet-facing host (render refuses).

Linux-specific (found on real hosts, 2026-10-14):
- Registry containers run as `0:<your gid>` with all capabilities dropped, so `tls/registry.key` and `auth/htpasswd`
  are 0640 and group-readable by the gid that ran `mkcerts.sh` / `add-user.sh` (rendered as `REGISTRY_FILES_GID`).
- `docker login` is done by dockerd, which then needs to resolve + trust the registry (`/etc/docker/certs.d`, root).
  A build machine does not need that: use `bin/img login <user>` (password on stdin).
- No QEMU on the build host? Then `linux/arm64` (or amd64 on arm64) builds only work when the Dockerfile's final
  stage has **no RUN** — cross-compile in a `FROM --platform=$BUILDPLATFORM` stage and `COPY` onto distroless/scratch.
  `detect-host.sh --check` warns about it.
- Switching an existing Engine to `"containerd-snapshotter": true` (rendered `server/daemon.json`) hides **all**
  existing images and containers until you switch back. Plan it; never do it on a box with running workloads.
- For air-gapped sites, `bundle-tools` also carries the registry image and `httpd` (htpasswd for `add-user.sh`);
  the docker compose plugin itself is not bundled.
