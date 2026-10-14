# Evidence index

All logs here were produced on 2026-10-14 by the commands shown inside them, then sanitized with `lab/sanitize.py`
(host name, user name, home paths, non-lab IPs and every generated password replaced; docker pull progress dropped).
Pre-/post-state inventories of the lab host are not published (they list unrelated projects on that machine).

## README-only verification

`final-readme-run.log`: a fresh `git clone` of this repository at commit
**85dde3ac72b4507ceef1d84a04d22934712a0ec4**, then the first `sh` block of README.md section "Try it on one Linux box
(the lab)" executed verbatim (`set -x`). Result: lab VMs booted from scratch, registry + CA + robots created, the new
app `pingboard` 2.0.0 released (amd64 + arm64, SBOM + provenance, Grype gate, cosign sign + verify) and deployed to
`srv-cstore` by digest `sha256:7a313e60…3e34a`; the server verified the signature, pulled amd64 and served
`{"app":"pingboard","version":"2.0.0",…,"goarch":"amd64"}`. `QUICKSTART_RC=0`.

`q4a-grype-gate.log` and `q5b-ship-ssh.log` ran in the same lab right after; the first 4a attempt exposed F12 (a failed
build did not stop `release`), fixed in the next commit and re-run.

## Logs
| File | What |
|---|---|
| `q1-*` | detect-host, check-agnostic, validate.sh on the unchanged kit (Linux) |
| `q0-server-prep.log` | rendered install-trust.sh / daemon.json applied inside the VMs |
| `q2-*` | registries on a real host; robot rights; add-user without restart; Docker Hub mirror |
| `q3*` | img login, keygen/builder/doctor, release (first attempt + fixed), deploy native, negative tests, Distribution |
| `q4*` | save/load matrix (classic vs containerd), containerd-snapshotter switch, Grype gate |
| `q5*` | P2 offline server, ship-ssh |
| `q6*` | P3 outside (build/scan/bundle/bundle-tools/export) and inside (air-gapped VM) |
| `q7-*` | build-time bench (host native, VM native, VM with QEMU) |
| `q8-*` | remote BuildKit over SSH, `docker --context` |
| `q9-*` | the five open questions answered for the lab host as a stand-in server |
| `q10-*` | Forgejo OCI registry smoke test |
| `validate-final.log`, `publish-scan.log`, `teardown-research-run.log` | final validation, pre-push secret scan, teardown |

## Kit fixes found on real Linux (each re-run after the fix)
| # | Bug | Fix |
|---|---|---|
| F1 | detect-host never warned that arm64 can't be built on amd64 without QEMU | warning: final stage must have no RUN, or use multinode |
| F2 | registries crash-looped: cap_drop ALL removes DAC_OVERRIDE; 0600 key/htpasswd unreadable | compose `user: 0:${REGISTRY_FILES_GID}`, key/htpasswd 0640 |
| F3 | second profile's CA overwrote the first in the OS trust store | one file per profile |
| F4 | `docker login` needs dockerd to resolve + trust the registry (root certs.d) | `img login` (daemon-free) |
| F5 | cosign (uid 65532) could not read the 0600 authfile/key → 401 | cosign runs as the invoking user |
| F6 | P3 outside died: the inside registry's CA doesn't exist outside | CA only required by registry commands |
| F7 | builder failed on the absent CA in buildkitd.toml | skip absent CA entries |
| F8 | cosign bundle written 0600, unreadable inside | chmod 0644 |
| F9 | inside add-user.sh had no htpasswd | bundle-tools carries the registry + httpd images |
| F10 | verify-blob/sign-blob saw only $PWD | mount the archive's directory |
| F11 | BuildKit v0.33.0 / registry 3.1.1 had published advisories | v0.33.1 / 3.1.2 |
| F12 | a failed build did not stop `release` (errexit not inherited in `$(...)`) | explicit checks in build/release |
