#!/usr/bin/env python3
"""Render a profile into ready-to-use files (stdlib only; python >= 3.8).

  bin/render.py <profile>                 -> build/<profile>/{profile.env,buildkitd.toml,ssh_config,RUNBOOK.md,
                                             server/daemon.json,server/install-trust.sh,registry/.env,registry/zot-config.json}
  bin/render.py --all                     -> every profiles/*.env
  bin/render.py <profile> --set K=V ...   -> override profile keys (e.g. lab wiring) before rendering
  bin/render.py --get <profile> <KEY>     -> print one resolved value
  bin/render.py --check-agnostic          -> fail if host-specific values leaked into templates (not profiles/build)

<profile> is a name from profiles/ (without .env) or a path to an .env file.
"""
import json, os, re, sys, shlex, stat

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROFILES = os.path.join(ROOT, "profiles")
BUILD = os.environ.get("IMG_BUILD_DIR", os.path.join(ROOT, "build"))

ENUMS = {
    "BUILDER_MODE": {"local", "remote", "multinode"},
    "TRANSPORT": {"registry", "ssh-load", "oci-archive"},
    "REGISTRY_KIND": {"company", "self-hosted"},
    "REGISTRY_IMPL": {"", "zot", "distribution"},
    "SIGNING": {"cosign-key", "none"},
    "SCAN_FAIL_ON": {"", "negligible", "low", "medium", "high", "critical"},
    "CACHE": {"registry", "local", "none"},
    "SERVER_INTERNET": {"yes", "no"},
    "MIRROR_ENABLED": {"yes", "no"},
    "TOOLS_FROM_REGISTRY": {"yes", "no"},
    "VERIFY_ON_SERVER": {"yes", "no"},
    "SCAN_ONLY_FIXED": {"yes", "no"},
    "REQUIRE_SERVER_CONTAINERD_STORE": {"yes", "no"},
}
REQUIRED = ["SERVER_PLATFORM", "BUILD_PLATFORMS", "BUILDER_MODE", "TRANSPORT", "REGISTRY_KIND", "REGISTRY_HOST",
            "REGISTRY_PORT", "REGISTRY_NAMESPACE", "SIGNING", "CACHE", "SERVER_INTERNET", "MIRROR_ENABLED"]
PLATFORM_RE = re.compile(r"^linux/(amd64|arm64|arm/v7|arm/v6|ppc64le|s390x|riscv64|386)(/v[0-9])?$")


def parse_env(path):
    """KEY=VALUE lines; '#' comments (also trailing, when unquoted); single/double quotes stripped."""
    out = {}
    for n, raw in enumerate(open(path), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        m = re.match(r"^([A-Z][A-Z0-9_]*)=(.*)$", line)
        if not m:
            sys.exit(f"{path}:{n}: not KEY=VALUE: {raw.rstrip()}")
        k, v = m.group(1), m.group(2).strip()
        if v[:1] in ("'", '"'):
            q = v[0]
            end = v.find(q, 1)
            if end < 0:
                sys.exit(f"{path}:{n}: unterminated quote")
            v = v[1:end]
        elif v.startswith("#"):
            v = ""
        else:
            v = re.split(r"\s+#", v, maxsplit=1)[0].strip()
        out[k] = v
    return out


def resolve_profile_path(name):
    if os.path.isfile(name):
        return os.path.abspath(name)
    p = os.path.join(PROFILES, name + ".env")
    if not os.path.isfile(p):
        sys.exit(f"unknown profile {name!r} (looked for {p})")
    return p


def load(name, overrides=()):
    ppath = resolve_profile_path(name)
    cfg = parse_env(os.path.join(ROOT, "VERSIONS.env"))
    cfg.update(parse_env(ppath))
    for o in overrides:
        k, _, v = o.partition("=")
        if not re.match(r"^[A-Z][A-Z0-9_]*$", k):
            sys.exit(f"bad --set {o!r}")
        cfg[k] = v
    cfg["PROFILE_NAME"] = cfg.get("PROFILE_NAME") or os.path.basename(ppath)[:-4]
    # defaults
    d = {"SERVER_SSH_PORT": "22", "BUILDER_DRIVER_OPTS": "", "SBOM": "true", "PROVENANCE": "mode=max",
         "REGISTRY_IMPL": "", "REGISTRY_CA_FILE": "", "MIRROR_HOST": "", "MIRROR_PORT": "", "COSIGN_KEY": "keys/cosign.key",
         "COSIGN_PUB": "keys/cosign.pub", "SCAN_FAIL_ON": "high", "SCAN_ONLY_FIXED": "yes", "VERIFY_ON_SERVER": "yes", "TOOLS_DOCKER_NETWORK": "",
         "TOOLS_FROM_REGISTRY": "no", "MIN_CLIENT_DOCKER": "28.0", "MIN_SERVER_DOCKER": "25.0", "MIN_BUILDX": "0.13",
         "REQUIRE_SERVER_CONTAINERD_STORE": "no", "MIN_SERVER_DISK_GB": "20", "REGISTRY_BIND": "127.0.0.1",
         "REGISTRY_PUSH_USERS": "ci-push", "REGISTRY_PULL_USERS": "server-pull", "REGISTRY_ADMIN_USERS": "registry-admin",
         "RETENTION_KEEP_RECENT": "30", "RETENTION_DRY_RUN": "true", "REGISTRY_NETWORK": "img-registry",
         "REGISTRY_NETWORK_EXTERNAL": "false", "MIRROR_UPSTREAM": "https://registry-1.docker.io", "BUILDER_NAME": ""}
    for k, v in d.items():
        cfg.setdefault(k, v)
    # validation
    errs = [f"missing {k}" for k in REQUIRED if not cfg.get(k)]
    for k, allowed in ENUMS.items():
        if cfg.get(k, "") not in allowed:
            errs.append(f"{k}={cfg.get(k)!r} not in {sorted(allowed)}")
    plats = [p for p in cfg["BUILD_PLATFORMS"].split(",") if p]
    for p in plats + [cfg["SERVER_PLATFORM"]]:
        if not PLATFORM_RE.match(p):
            errs.append(f"bad platform {p!r}")
    if cfg["SERVER_PLATFORM"] not in plats:
        errs.append("SERVER_PLATFORM must be one of BUILD_PLATFORMS")
    if cfg["REGISTRY_KIND"] == "self-hosted" and cfg["REGISTRY_IMPL"] not in ("zot", "distribution"):
        errs.append("self-hosted registry needs REGISTRY_IMPL=zot|distribution")
    if cfg["BUILDER_MODE"] in ("remote", "multinode") and not cfg.get("SERVER_SSH"):
        errs.append("BUILDER_MODE remote/multinode needs SERVER_SSH")
    if cfg["TRANSPORT"] == "ssh-load" and not cfg.get("SERVER_SSH"):
        errs.append("TRANSPORT=ssh-load needs SERVER_SSH")
    if cfg["TRANSPORT"] == "oci-archive" and cfg["CACHE"] == "registry":
        errs.append("TRANSPORT=oci-archive has no outside registry: use CACHE=local|none")
    if cfg["MIRROR_ENABLED"] == "yes" and not (cfg["MIRROR_HOST"] and cfg["MIRROR_PORT"]):
        errs.append("MIRROR_ENABLED=yes needs MIRROR_HOST and MIRROR_PORT")
    if cfg["MIRROR_ENABLED"] == "yes" and cfg["SERVER_INTERNET"] == "no" and cfg["REGISTRY_KIND"] == "self-hosted":
        errs.append("a pull-through mirror needs internet on its host; set MIRROR_ENABLED=no for offline servers")
    if cfg["REGISTRY_BIND"] in ("0.0.0.0", "::"):
        errs.append("REGISTRY_BIND=0.0.0.0 publishes on every interface; bind the LAN/VPN address instead")
    if not re.match(r"^[0-9]+$", cfg["REGISTRY_PORT"]):
        errs.append("REGISTRY_PORT must be a number")
    if errs:
        sys.exit(f"profile {cfg['PROFILE_NAME']}: " + "; ".join(errs))
    # derived
    cfg["REGISTRY"] = cfg["REGISTRY_HOST"] if cfg["REGISTRY_PORT"] == "443" else f"{cfg['REGISTRY_HOST']}:{cfg['REGISTRY_PORT']}"
    cfg["IMAGE_PREFIX"] = f"{cfg['REGISTRY']}/{cfg['REGISTRY_NAMESPACE']}"
    cfg["MIRROR"] = f"{cfg['MIRROR_HOST']}:{cfg['MIRROR_PORT']}" if cfg["MIRROR_ENABLED"] == "yes" else ""
    cfg["BUILDER_NAME"] = cfg["BUILDER_NAME"] or f"img-{cfg['PROFILE_NAME']}"
    cfg.setdefault("REGISTRY_PUBLISH", f"{cfg['REGISTRY_BIND']}:{cfg['REGISTRY_PORT']}")
    cfg.setdefault("MIRROR_PUBLISH", f"{cfg['REGISTRY_BIND']}:{cfg['MIRROR_PORT'] or 5444}")
    cfg["SERVER_ARCH"] = cfg["SERVER_PLATFORM"].split("/")[1]
    return cfg


def w(path, text, mode=0o644):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)
    os.chmod(path, mode)


def render(name, overrides=()):
    c = load(name, overrides)
    out = os.path.join(BUILD, c["PROFILE_NAME"])
    os.makedirs(out, exist_ok=True)
    absp = lambda p: p if (not p or os.path.isabs(p)) else os.path.join(out, p)

    # profile.env: every resolved key, shell-quoted, sourced by bin/img
    lines = [f"# rendered from profiles/{c['PROFILE_NAME']}.env + VERSIONS.env by bin/render.py — do not edit, re-render",
             f"PROFILE_DIR={shlex.quote(out)}"]
    lines += [f"{k}={shlex.quote(v)}" for k, v in sorted(c.items())]
    w(os.path.join(out, "profile.env"), "\n".join(lines) + "\n")

    # buildkitd.toml: registry CA trust (+ Docker Hub mirror) for the buildx builder. Absolute paths: buildx copies
    # the files into the builder container at `docker buildx create` time.
    t = [f"# buildkitd.toml for profile {c['PROFILE_NAME']} (used by: img builder)"]
    ca = absp(c["REGISTRY_CA_FILE"])
    if ca:
        t += [f'[registry."{c["REGISTRY"]}"]', f'  ca = ["{ca}"]']
    if c["MIRROR"]:
        t += ['[registry."docker.io"]', f'  mirrors = ["{c["MIRROR"]}"]']
        if ca:
            t += [f'[registry."{c["MIRROR"]}"]', f'  ca = ["{ca}"]']
    w(os.path.join(out, "buildkitd.toml"), "\n".join(t) + "\n")

    # ssh_config snippet (merge into ~/.ssh/config — the docker CLI's ssh:// transport uses it)
    if c.get("SERVER_SSH"):
        user, _, host = c["SERVER_SSH"].rpartition("@")
        w(os.path.join(out, "ssh_config"), "\n".join([
            f"# merge into ~/.ssh/config (docker CLI + buildx ssh:// endpoints read it; they take no -i/-o flags)",
            f"Host {host}",
            f"  User {user or 'deploy'}",
            f"  Port {c['SERVER_SSH_PORT']}",
            "  IdentitiesOnly yes",
            "  # IdentityFile ~/.ssh/id_ed25519_server        # a dedicated key, ideally hardware-backed / in the agent",
            "  ControlMaster auto                             # reuse one TCP+auth for many docker CLI calls",
            "  ControlPath ~/.ssh/control-%C",
            "  ControlPersist 10m",
            "  ServerAliveInterval 30", ""]))

    # server/daemon.json — containerd image store (keeps multi-arch indexes), optional Docker Hub mirror.
    # Deliberately NO "insecure-registries": trust the CA via /etc/docker/certs.d instead (install-trust.sh).
    dj = {"features": {"containerd-snapshotter": True}, "live-restore": True,
          "log-driver": "local", "log-opts": {"max-size": "20m", "max-file": "5"}}
    if c["MIRROR"]:
        dj["registry-mirrors"] = [f"https://{c['MIRROR']}"]
    w(os.path.join(out, "server", "daemon.json"), json.dumps(dj, indent=2) + "\n")

    # server/install-trust.sh — run ON the server as root (copy the CA next to it first)
    regs = [c["REGISTRY"]] + ([c["MIRROR"]] if c["MIRROR"] else [])
    w(os.path.join(out, "server", "install-trust.sh"), f"""#!/bin/sh
# Rendered for profile {c['PROFILE_NAME']}. Run on the Linux server as root:  sh install-trust.sh ca.crt
# Docker reads per-registry CAs from /etc/docker/certs.d/<host:port>/ca.crt (no daemon restart needed).
# The OS store is updated too so cosign/skopeo/curl on the host trust the registry.
set -eu
CA="${{1:?usage: install-trust.sh <ca.crt>}}"
for r in {' '.join(regs)}; do
  install -d -m 0755 "/etc/docker/certs.d/$r"
  install -m 0644 "$CA" "/etc/docker/certs.d/$r/ca.crt"
  echo "docker trusts $r"
done
if [ -d /usr/local/share/ca-certificates ]; then            # Debian/Ubuntu/Alpine
  install -m 0644 "$CA" /usr/local/share/ca-certificates/img-registry-{c["PROFILE_NAME"]}.crt && update-ca-certificates >/dev/null
elif [ -d /etc/pki/ca-trust/source/anchors ]; then          # RHEL/Fedora/Rocky/Alma
  install -m 0644 "$CA" /etc/pki/ca-trust/source/anchors/img-registry-{c["PROFILE_NAME"]}.crt && update-ca-trust
fi
echo "OS trust store updated (one file per profile, so several registries/CAs can coexist)"
""", 0o755)

    # registry/.env + zot config (self-hosted only)
    if c["REGISTRY_KIND"] == "self-hosted":
        regdir = os.path.join(out, "registry")
        env = {
            "COMPOSE_PROJECT": f"img-registry-{c['PROFILE_NAME']}", "COMPOSE_PROFILES": c["REGISTRY_IMPL"] + (",mirror" if c["MIRROR"] else ""),
            "REGISTRY_IMAGE": c["REGISTRY_IMAGE"], "ZOT_IMAGE": c["ZOT_IMAGE"], "REGISTRY_HOST": c["REGISTRY_HOST"],
            "MIRROR_HOST": c["MIRROR_HOST"] or "mirror.invalid", "REGISTRY_PUBLISH": c["REGISTRY_PUBLISH"],
            "MIRROR_PUBLISH": c["MIRROR_PUBLISH"], "MIRROR_UPSTREAM": c["MIRROR_UPSTREAM"],
            "CERTS_DIR": os.path.join(out, "certs"), "AUTH_DIR": os.path.join(out, "auth"),
            "ZOT_CONFIG": os.path.join(regdir, "zot-config.json"),
            "REGISTRY_NETWORK": c["REGISTRY_NETWORK"], "REGISTRY_NETWORK_EXTERNAL": c["REGISTRY_NETWORK_EXTERNAL"],
            # group that may read tls/registry.key + auth/htpasswd (0640) inside the cap-dropped containers
            "REGISTRY_FILES_GID": c.get("REGISTRY_FILES_GID") or str(os.getgid()),
        }
        w(os.path.join(regdir, ".env"), "".join(f"{k}={v}\n" for k, v in env.items()))
        split = lambda s: [u for u in s.split(",") if u]
        zc = {
            "distSpecVersion": "1.1.1",
            "storage": {"rootDirectory": "/var/lib/registry", "dedupe": True, "gc": True, "gcDelay": "1h", "gcInterval": "24h",
                        "retention": {"dryRun": c["RETENTION_DRY_RUN"] == "true", "delay": "24h", "policies": [{
                            "repositories": ["**"], "deleteReferrers": False, "deleteUntagged": True,
                            "keepTags": [{"patterns": ["^v[0-9].*"]},
                                         {"patterns": [".*"], "mostRecentlyPushedCount": int(c["RETENTION_KEEP_RECENT"])}]}]}},
            # compat docker2s2: accept Docker v2 schema 2 manifests unchanged (plain `docker push`, most Docker Hub
            # images). Without it Zot answers "manifest invalid" and mirroring with preserved digests fails.
            "http": {"address": "0.0.0.0", "port": "5443", "realm": "zot", "compat": ["docker2s2"],
                     "tls": {"cert": "/etc/zot/certs/registry.crt", "key": "/etc/zot/certs/registry.key"},
                     "auth": {"htpasswd": {"path": "/etc/zot/auth/htpasswd"}, "failDelay": 3},
                     "accessControl": {
                         "repositories": {"**": {"policies": [
                             {"users": split(c["REGISTRY_PUSH_USERS"]), "actions": ["read", "create", "update"]},
                             {"users": split(c["REGISTRY_PULL_USERS"]), "actions": ["read"]}],
                             "defaultPolicy": []}},
                         "adminPolicy": {"users": split(c["REGISTRY_ADMIN_USERS"]), "actions": ["read", "create", "update", "delete"]}}},
            "log": {"level": "info"},
            "extensions": {"search": {"enable": True}, "scrub": {"enable": True, "interval": "24h"}},
        }
        w(os.path.join(regdir, "zot-config.json"), json.dumps(zc, indent=2) + "\n")

    w(os.path.join(out, "RUNBOOK.md"), runbook(c, out))
    return out, c


def runbook(c, out):
    P = c["PROFILE_NAME"]
    img = f"bin/img -p {P}"
    s = [f"# Runbook — {P}", "", c.get("PROFILE_DESC", ""), "",
         f"Server platform **{c['SERVER_PLATFORM']}**, publish **{c['BUILD_PLATFORMS']}**, transport **{c['TRANSPORT']}**, "
         f"registry **{c['REGISTRY']}** ({c['REGISTRY_KIND']}{'/' + c['REGISTRY_IMPL'] if c['REGISTRY_IMPL'] else ''}).", "",
         "## 0. Check both ends", "```sh", f"bin/detect-host.sh --check {out}/profile.env            # on the Mac",
         f"{img} doctor                                   # Mac + server over SSH + registry reachability", "```"]
    if c["REGISTRY_KIND"] == "self-hosted":
        s += ["## 1. Registry (once, on the registry host)", "```sh",
              f"registry/mkcerts.sh {out}/certs {c['REGISTRY_HOST']}{(' ' + c['MIRROR_HOST']) if c['MIRROR'] and c['MIRROR_HOST'] != c['REGISTRY_HOST'] else ''}   # internal CA + server cert (or drop in company-CA-issued ones)",
              *[f"registry/add-user.sh {out}/auth {u}" for u in (c['REGISTRY_PUSH_USERS'] + ',' + c['REGISTRY_PULL_USERS'] + ',' + c['REGISTRY_ADMIN_USERS']).split(',') if u],
              f"docker compose --env-file {out}/registry/.env -f registry/compose.yaml up -d",
              "```"]
    s += ["## 2. Trust the CA", f"- Mac (Docker Desktop daemon + buildx multi-node merges): `security add-trusted-cert -d -r trustRoot -k ~/Library/Keychains/login.keychain {out}/certs/ca.crt`, restart Docker Desktop.",
          "- buildx builder: handled by `buildkitd.toml` (rendered) — `img builder` passes it.",
          f"- Server: `scp {out}/certs/ca.crt {out}/server/install-trust.sh {out}/server/daemon.json server:` then `sudo sh install-trust.sh ca.crt`;",
          "  merge daemon.json into /etc/docker/daemon.json (containerd store, mirror; no insecure-registries) and restart dockerd.",
          "- Never use `insecure-registries`.", ""]
    s += ["## 3. Keys + login", "```sh", f"{img} keygen            # cosign key pair (once; keep cosign.key in a secret store)",
          f"docker login {c['REGISTRY']}   # push robot on the Mac; the server logs in with its read-only robot",
          f"{img} login ci-push < pw-file  # Linux build host: same, without dockerd (no /etc/docker/certs.d, no sudo)", "```"]
    s += ["## 4. Builder", "```sh", f"{img} builder           # BUILDER_MODE={c['BUILDER_MODE']}", "```"]
    if c["TRANSPORT"] == "registry":
        s += ["## 5. Build → scan → sign → deploy", "```sh",
              f"{img} release ./app myapp 1.2.3        # build+push multi-arch, scan gate, sign; prints REF@sha256:…",
              f"{img} deploy {c['IMAGE_PREFIX']}/myapp@sha256:<digest>   # server: verify signature, pull {c['SERVER_PLATFORM']} by digest",
              "```"]
        if c["TOOLS_FROM_REGISTRY"] == "yes":
            s += ["Server has no internet: first `" + img + " mirror-tools` (copies cosign/grype/skopeo/regctl into " + c['REGISTRY'] + "/tools/*)."]
    elif c["TRANSPORT"] == "ssh-load":
        s += ["## 5. Build → scan → stream over SSH", "```sh", f"{img} build ./app myapp 1.2.3", f"{img} scan myapp:1.2.3", f"{img} ship-ssh myapp:1.2.3", "```"]
    else:
        s += ["## 5. Outside: build → scan → archive → sign-blob", "```sh",
              f"{img} build ./app myapp 1.2.3              # writes dist/myapp-1.2.3.oci.tar (multi-arch index)",
              f"{img} scan oci-archive:dist/myapp-1.2.3.oci.tar",
              f"{img} bundle dist/myapp-1.2.3.oci.tar       # -> .sha256 + .sigstore.json (cosign sign-blob bundle)",
              f"{img} bundle-tools dist/tools.tar.zst       # once: cosign/grype/skopeo/regctl/zot for SERVER_PLATFORM", "```",
              "## 6. Inside (operator)", "```sh",
              "docker load -i dist/tools.tar.zst                    # once, on each inside host that runs the tools",
              f"{img} import dist/myapp-1.2.3.oci.tar {c['IMAGE_PREFIX']}/myapp:1.2.3   # sha256 -c, cosign verify-blob, regctl copy (keeps referrers)",
              f"{img} --set SERVER_SSH=deploy@<inside-server> deploy {c['IMAGE_PREFIX']}/myapp@sha256:<digest>",
              "# single host, no registry: `docker load -i dist/myapp-1.2.3.oci.tar` works on a containerd-store daemon;",
              "# classic store: `regctl image export --platform linux/amd64 <ref>` (docker-load format). See findings §4.4.", "```"]
    return "\n".join(s) + "\n"


AGNOSTIC_FORBIDDEN = [r"/Users/", r"/home/[a-z]", r"\.lab\b", r"\bdis-(lab|sim|reg|offline)", r"192\.168\.", r"172\.(1[6-9]|2[0-9]|3[01])\.",
                      r"\b10\.\d+\.\d+\.\d+", r"desktop-linux", r"Apple M[0-9]", r"\bmac\b@"]


def check_agnostic():
    bad = []
    for d in ("bin", "registry", "server", "examples", "Makefile", "README.md"):
        base = os.path.join(ROOT, d)
        files = [base] if os.path.isfile(base) else [os.path.join(r, f) for r, _, fs in os.walk(base) for f in fs]
        for f in files:
            if f.endswith("render.py"):
                continue  # holds the forbidden list itself
            for n, line in enumerate(open(f, errors="replace"), 1):
                for pat in AGNOSTIC_FORBIDDEN:
                    if re.search(pat, line):
                        bad.append(f"{os.path.relpath(f, ROOT)}:{n}: /{pat}/ {line.strip()[:100]}")
    if bad:
        print("host-specific values found in templates:\n  " + "\n  ".join(bad))
        return 1
    print("check-agnostic: OK (no host paths, lab names or private IPs in bin/ registry/ server/ examples/ Makefile README)")
    return 0


def main(a):
    if not a or a[0] in ("-h", "--help"):
        print(__doc__); return 0
    if a[0] == "--check-agnostic":
        return check_agnostic()
    if a[0] == "--get":
        print(load(a[1])[a[2]]); return 0
    sets = [a[i + 1] for i, x in enumerate(a) if x == "--set"]
    names = [x for i, x in enumerate(a) if x != "--set" and (i == 0 or a[i - 1] != "--set")]
    if names == ["--all"]:
        names = sorted(f[:-4] for f in os.listdir(PROFILES) if f.endswith(".env"))
    for n in names:
        out, c = render(n, sets)
        print(f"rendered {c['PROFILE_NAME']:<24} -> {os.path.relpath(out, os.getcwd())}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
