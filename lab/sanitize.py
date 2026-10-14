#!/usr/bin/env python3
"""Sanitize lab logs for publishing: host/user names, paths, non-lab IPs, secrets; drop docker pull progress noise.
usage: [SANITIZE_EXTRA=name1,name2] sanitize.py <out-dir> <secret-files...> -- <log files...>"""
import ipaddress, os, re, socket, sys
out = sys.argv[1]; i = sys.argv.index("--"); secret_files, logs = sys.argv[2:i], sys.argv[i + 1:]
secrets = set()
for f in secret_files:
    for line in open(f, errors="replace"):
        for tok in line.split():
            if len(tok) >= 12: secrets.add(tok)
user = os.environ.get("USER", "")
host = socket.gethostname()
topic = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
subs = [(topic + "/templates", "<repo>/kit"), (topic + "/lab-linux", "<repo>/lab"), (topic + "/poc-app", "<repo>/app"),
        (topic + "/mac-source/phase-4/sample-app", "<bench-app>"), (topic, "<topic>"),
        (os.path.expanduser("~"), "/home/<user>")]
noise = re.compile(r"^\s*[0-9a-f]{12}: (Pulling fs layer|Waiting|Verifying Checksum|Download complete|Pull complete|Already exists|Downloading|Extracting)|^\s*[0-9a-f]{12} (Pulling fs layer|Downloading|Download complete|Extracting|Pull complete|Already exists)")
ipre = re.compile(r"\b(\d{1,3}(?:\.\d{1,3}){3})(/\d+)?\b")
keep_nets = [ipaddress.ip_network(n) for n in ("10.77.0.0/24", "127.0.0.0/8", "0.0.0.0/32", "1.1.1.1/32")]
def ip_sub(m):
    try: a = ipaddress.ip_address(m.group(1))
    except ValueError: return m.group(0)
    if any(a in n for n in keep_nets): return m.group(0)
    if a.is_private: return "<docker-net-ip>" + (m.group(2) or "")
    return "<public-ip>" + (m.group(2) or "")
os.makedirs(out, exist_ok=True)
for f in logs:
    txt = []
    for line in open(f, errors="replace"):
        if noise.search(line): continue
        for a, b in subs: line = line.replace(a, b)
        for s in secrets: line = line.replace(s, "<redacted>")
        line = re.sub(r"/tmp/claude-\d+/[^\s'\"]*", "<tmp>", line)
        if host: line = line.replace(host, "<host>")
        if user: line = re.sub(rf"\b{re.escape(user)}\b", "<user>", line)
        for extra in filter(None, os.environ.get("SANITIZE_EXTRA", "").split(",")):   # e.g. tailnet / LAN names
            line = line.replace(extra, "<redacted-name>")
        line = ipre.sub(ip_sub, line)
        txt.append(line)
    open(os.path.join(out, os.path.basename(f)), "w").write("".join(txt))
    print("sanitized", os.path.basename(f))
