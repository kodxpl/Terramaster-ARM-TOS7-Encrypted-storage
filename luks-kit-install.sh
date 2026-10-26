#!/bin/bash
# =============================================================================
#  luks-kit-install.sh  -  LUKS directly on TOS md RAID (md -> LUKS -> PV -> VG)
#  TerraMaster TOS 7 (tested on F4-212, TOS_ARM2.0_6.0.587)
#
#  Installs / updates everything in /opt/lvmshim and the boot unit
#  luks-pools.service. Safe to re-run (idempotent). Does NOT touch any disk.
#
#  Encrypted arrays are listed by md UUID in /opt/lvmshim/pools.conf, so it
#  does not matter whether TOS names an array md1, md2, md127 ...
#  An open array /dev/mdN is always mapped as /dev/mapper/cryptN.
# =============================================================================
KIT_VERSION=2026-10-25
set -e
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }

D=/opt/lvmshim
[ -d $D ] && cp -a $D /root/lvmshim.bak.$(date +%Y%m%d-%H%M%S)
mkdir -p $D /root/luks-pools

# -----------------------------------------------------------------------------
cat > $D/common.sh <<'EOF_COMMON'
#!/bin/bash
# shared helpers
POOLS_CONF=/opt/lvmshim/pools.conf
STATE_DIR=/root/luks-pools

# md UUIDs of encrypted pools (one per line in pools.conf)
pool_uuids(){ grep -vE '^[[:space:]]*(#|$)' "$POOLS_CONF" 2>/dev/null | awk '{print $1}'; }

# device name TOS uses for this array, from the mdadm config (e.g. /dev/md1)
md_conf_name(){
  local f
  for f in /etc/mdadm/mdadm.conf /etc/mdadm.conf; do
    [ -r "$f" ] && awk -v u="UUID=$1" '$1=="ARRAY" && index($0,u){print $2; exit}' "$f"
  done | head -1
}

# active md device carrying this UUID (empty if not assembled)
md_active_dev(){
  local d
  for d in /dev/md[0-9]*; do
    [ -b "$d" ] || continue
    [ "$(mdadm --detail --export "$d" 2>/dev/null | sed -n 's/^MD_UUID=//p')" = "$1" ] && { echo "$d"; return 0; }
  done
  return 1
}

# make sure the array is assembled (under the name TOS expects); print device
md_ensure(){
  local d
  d=$(md_active_dev "$1") && { echo "$d"; return 0; }
  d=$(md_conf_name "$1")
  if [ -n "$d" ]; then mdadm --assemble --run "$d" --uuid="$1" >&2 || return 1
  else mdadm --assemble --scan --run --uuid="$1" >&2 || return 1; fi
  md_active_dev "$1"
}

# at least one member disk of this array is in the NAS (or the array is running)
md_members_present(){ md_active_dev "$1" >/dev/null || mdadm --examine --scan 2>/dev/null | grep -qi "UUID=$1"; }

# pools from pools.conf whose disks are present; pools with all disks removed are skipped
present_uuids(){ local u; for u in $(pool_uuids); do md_members_present "$u" && echo "$u"; done; }

crypt_name(){ echo "crypt${1#/dev/md}"; }      # /dev/md2 -> crypt2
header_file(){ echo "$STATE_DIR/${1//:/-}-header.img"; }
EOF_COMMON

# -----------------------------------------------------------------------------
cat > $D/lvm-shim <<'EOF_LVM'
#!/bin/bash
# Wraps every LVM command. While /dev/mapper/cryptN is open:
#  - argument /dev/mdN  -> /dev/mapper/cryptN
#  - output /dev/mapper/cryptN -> /dev/mdN
#  - device hints in /etc/lvm/backup/* rewritten to /dev/mdN
#    (StorageManager maps VG -> md from those hints)
cmd=$(basename "$0")
args=()
for a in "$@"; do
  if [[ $a =~ ^/dev/md([0-9]+)$ ]] && [ -b "/dev/mapper/crypt${BASH_REMATCH[1]}" ]; then
    n=${BASH_REMATCH[1]}
    [ "$cmd" = pvresize ] && cryptsetup resize "crypt$n"
    a="/dev/mapper/crypt$n"
  fi
  args+=("$a")
done
fix(){ sed -E 's#/dev/mapper/crypt([0-9]+)#/dev/md\1#g'; }
fixbak(){
  grep -l 'device = "/dev/mapper/crypt[0-9]' /etc/lvm/backup/* 2>/dev/null \
    | xargs -r sed -i -E 's#(device = ")/dev/mapper/crypt([0-9]+)"#\1/dev/md\2"#'
}
if [ -e /opt/lvmshim/DEBUG ]; then
  out=$(/usr/sbin/lvm "$cmd" "${args[@]}" | fix; exit ${PIPESTATUS[0]}); rc=$?
  fixbak
  /opt/lvmshim/log "$cmd" "$rc" "$out" "$@"
  [ -n "$out" ] && printf '%s\n' "$out"; exit $rc
fi
/usr/sbin/lvm "$cmd" "${args[@]}" | fix
rc=${PIPESTATUS[0]}
fixbak
exit $rc
EOF_LVM

# -----------------------------------------------------------------------------
cat > $D/blkid-shim <<'EOF_BLKID'
#!/bin/bash
# blkid: an open /dev/mdN is reported with the type of what is inside (LVM2_member)
REAL=/usr/sbin/blkid.real
ls /dev/mapper/crypt[0-9]* &>/dev/null || exec $REAL "$@"
args=(); devs=0
for a in "$@"; do
  if [[ $a =~ ^/dev/md([0-9]+)$ ]]; then
    devs=1; [ -b "/dev/mapper/crypt${BASH_REMATCH[1]}" ] && a="/dev/mapper/crypt${BASH_REMATCH[1]}"
  elif [[ $a == /dev/* && $a != /dev/null ]]; then devs=1; fi
  args+=("$a")
done
open=$(ls /dev/mapper/ | sed -n 's/^crypt\([0-9][0-9]*\)$/md\1/p' | paste -sd'|')
doit(){
  if [ $devs -eq 0 ]; then
    $REAL "${args[@]}" | grep -Ev "^/dev/(${open}):" | sed -E 's#^/dev/mapper/crypt([0-9]+):#/dev/md\1:#'
    return ${PIPESTATUS[0]}
  fi
  $REAL "${args[@]}" | sed -E 's#/dev/mapper/crypt([0-9]+)#/dev/md\1#g'
  return ${PIPESTATUS[0]}
}
if [ -e /opt/lvmshim/DEBUG ]; then
  out=$(doit); rc=$?
  /opt/lvmshim/log blkid $rc "$out" "$@"
  [ -n "$out" ] && printf '%s\n' "$out"; exit $rc
fi
doit; exit $?
EOF_BLKID

# -----------------------------------------------------------------------------
cat > $D/lsblk-shim <<'EOF_LSBLK'
#!/bin/bash
# lsblk: hide the crypt layer from TOS (JSON tree and single-column queries)
REAL=/usr/bin/lsblk.real
ls /dev/mapper/crypt[0-9]* &>/dev/null || exec $REAL "$@"
json=0; nohead=0; nodeps=0; col=""; md=""; ndev=0; prev=""
for a in "$@"; do
  case "$a" in
    --json) json=1 ;; --noheadings) nohead=1 ;; --nodeps) nodeps=1 ;;
    --output=*) col="${a#--output=}" ;;
    --*) ;;
    -*) [[ $a == *J* ]] && json=1; [[ $a == *n* ]] && nohead=1; [[ $a == *d* ]] && nodeps=1 ;;
    /dev/*) ndev=$((ndev+1)); [[ $a =~ ^/dev/md([0-9]+)$ ]] && [ -b "/dev/mapper/crypt${BASH_REMATCH[1]}" ] && md="${BASH_REMATCH[1]}" ;;
    *) [[ $prev == -o || $prev == --output || $prev =~ ^-[a-zA-Z]*o$ ]] && col="$a" ;;
  esac
  prev="$a"
done
doit(){
  local o r inner
  if [ $json -eq 1 ]; then
    $REAL "$@" | python3 /opt/lvmshim/lsblk-json.py; return ${PIPESTATUS[0]}
  fi
  if [ -z "$md" ]; then $REAL "$@"; return $?; fi
  if [ $ndev -ne 1 ] || [[ -z $col || $col == *,* ]]; then
    mkdir -p /run/lvmshim; echo "$(date +%F_%T) passthrough: lsblk $*" >> /run/lvmshim/unhandled.log
    $REAL "$@"; return $?
  fi
  o=$($REAL "$@"); r=$?
  if [ "${col^^}" = FSTYPE ]; then inner=$($REAL -dno FSTYPE /dev/mapper/crypt$md); else inner=""; fi
  echo "$o" | awk -v h=$nohead -v d=$nodeps -v isfs="${col^^}" -v inner="$inner" '
    BEGIN{mdrow = (h ? 1 : 2)}
    NR < mdrow {print; next}
    NR == mdrow {print (isfs=="FSTYPE" ? inner : $0); next}
    NR == mdrow+1 && !d {next}
    {print}'
  return $r
}
if [ -e /opt/lvmshim/DEBUG ]; then
  out=$(doit "$@"); rc=$?
  /opt/lvmshim/log lsblk $rc "$out" "$@"
  [ -n "$out" ] && printf '%s\n' "$out"; exit $rc
fi
doit "$@"; exit $?
EOF_LSBLK

# -----------------------------------------------------------------------------
cat > $D/lsblk-json.py <<'EOF_JSON'
import json, sys, os
raw = sys.stdin.read()
try:
    d = json.loads(raw)
except Exception:
    sys.stdout.write(raw); sys.exit(0)
def nm(n):
    return os.path.basename(n.get('name') or n.get('kname') or '')
def fix(nodes):
    for n in nodes:
        ch = n.get('children') or []
        base = nm(n)
        if base.startswith('md') and base[2:].isdigit():
            for c in list(ch):
                if nm(c) == 'crypt' + base[2:]:
                    if 'fstype' in n:
                        n['fstype'] = c.get('fstype')
                    ch.remove(c)
                    ch.extend(c.get('children') or [])
            if ch: n['children'] = ch
            else: n.pop('children', None)
        if n.get('children'):
            fix(n['children'])
fix(d.get('blockdevices', []))
print(json.dumps(d, indent=3))
EOF_JSON

# -----------------------------------------------------------------------------
cat > $D/log <<'EOF_LOG'
#!/bin/bash
# debug logger, active only while /opt/lvmshim/DEBUG exists
cmd=$1; rc=$2; out=$3; shift 3
p1=$(awk '{print $4}' /proc/$PPID/stat 2>/dev/null); p2=$(awk '{print $4}' /proc/$p1/stat 2>/dev/null)
caller="$(cat /proc/$p2/comm 2>/dev/null)/$(cat /proc/$p1/comm 2>/dev/null)"
{ echo "### $(date +%T) [$caller] rc=$rc: $cmd $*"; [ -n "$out" ] && printf '%s\n' "$out" | sed 's/^/    /'; } >> /root/luks-pools/calls.log
EOF_LOG

# -----------------------------------------------------------------------------
cat > $D/install-shims.sh <<'EOF_INST'
#!/bin/bash
# (re)apply all shims - idempotent, run at every boot and after firmware updates
for f in /usr/sbin/*; do
  [ -L "$f" ] && [ "$(readlink "$f")" = lvm ] && ln -sfn /opt/lvmshim/lvm-shim "$f"
done
for c in pvs pvdisplay pvresize pvscan pvremove pvcreate vgs vgdisplay vgchange vgcfgbackup lvs lvdisplay lvcreate lvextend lvremove; do
  [ -e /usr/sbin/$c ] || [ -L /usr/sbin/$c ] || continue
  [ "$(readlink /usr/sbin/$c)" = /opt/lvmshim/lvm-shim ] || ln -sfn /opt/lvmshim/lvm-shim /usr/sbin/$c
done
wrap(){ local bin=$1 shim=$2
  if [ -f "$bin" ] && [ ! -L "$bin" ]; then mv -f "$bin" "$bin.real"; fi
  [ -x "$bin.real" ] || { logger -t lvmshim "missing $bin.real"; return 1; }
  [ "$(readlink $bin)" = "$shim" ] || ln -sfn "$shim" "$bin"
}
wrap /usr/sbin/blkid /opt/lvmshim/blkid-shim
wrap /usr/bin/lsblk  /opt/lvmshim/lsblk-shim
exit 0
EOF_INST

cat > $D/remove-shims.sh <<'EOF_RM'
#!/bin/bash
# restore original tools (encrypted pools will NOT work with TOS afterwards)
for f in /usr/sbin/*; do
  [ -L "$f" ] && [ "$(readlink "$f")" = /opt/lvmshim/lvm-shim ] && ln -sfn lvm "$f"
done
for b in /usr/sbin/blkid /usr/bin/lsblk; do [ -x $b.real ] && mv -f $b.real $b; done
exit 0
EOF_RM

# -----------------------------------------------------------------------------
cat > $D/unlock.sh <<'EOF_UNLOCK'
#!/bin/bash
# Interactive unlock (run over SSH while the NAS waits at boot)
. /opt/lvmshim/common.sh
/opt/lvmshim/install-shims.sh
[ -n "$(pool_uuids)" ] || { echo "no pools in $POOLS_CONF"; exit 1; }
for u in $(pool_uuids); do md_members_present "$u" || echo "SKIP: $u - no disks of this pool in the NAS"; done
rc=0
for u in $(present_uuids); do
  md=$(md_ensure "$u") || { echo "FAIL: cannot assemble array $u"; rc=1; continue; }
  c=$(crypt_name "$md")
  if [ ! -b /dev/mapper/$c ]; then
    echo "Unlocking $md ($u) as $c"
    cryptsetup open "$md" "$c" || { echo "FAIL: could not open $md"; rc=1; continue; }
  fi
  vg=$(/usr/sbin/lvm pvs --noheadings -o vg_name /dev/mapper/$c 2>/dev/null | tr -d ' ')
  [ -n "$vg" ] && /usr/sbin/lvm vgchange -ay "$vg" >/dev/null
  echo "OK:   $md -> $c -> ${vg:-<no VG>}"
done
vgcfgbackup >/dev/null 2>&1      # via shim: device hints -> /dev/mdN
exit $rc
EOF_UNLOCK

# -----------------------------------------------------------------------------
cat > $D/wait-unlock.sh <<'EOF_WAIT'
#!/bin/bash
# Boot: holds TOS storage start until every pool is unlocked.
# Unlock routes: SSH (unlock.sh), browser page (https://<nas>:8443), USB key stick.
# UNLOCK_TIMEOUT=0 (default) waits forever; >0 powers off after that many seconds.
. /opt/lvmshim/common.sh
UNLOCK_TIMEOUT=0; UNLOCK_WEB_PORT=8443
[ -r /opt/lvmshim/settings.conf ] && . /opt/lvmshim/settings.conf
/opt/lvmshim/install-shims.sh
for u in $(pool_uuids); do md_members_present "$u" || logger -t luks-pools "pool $u: no member disks present - not waiting for it"; done
[ -n "$(present_uuids)" ] || exit 0

all_open(){ local u md
  for u in $(present_uuids); do
    md=$(md_active_dev "$u") || return 1
    [ -b /dev/mapper/$(crypt_name "$md") ] || return 1
  done; }

for u in $(present_uuids); do md_ensure "$u" >/dev/null || logger -t luks-pools "cannot assemble $u"; done

# optional unattended unlock: USB stick labelled NASKEY with <md-uuid, ':'->'-'>.key
if [ -b /dev/disk/by-label/NASKEY ]; then
  mkdir -p /run/naskey && mount -o ro /dev/disk/by-label/NASKEY /run/naskey && {
    for u in $(present_uuids); do
      md=$(md_active_dev "$u") || continue
      k=/run/naskey/${u//:/-}.key
      [ -f "$k" ] && cryptsetup open --key-file "$k" "$md" "$(crypt_name "$md")"
    done
    umount /run/naskey; }
fi

WEBPID=
if ! all_open; then
  if [ "${UNLOCK_WEB_PORT:-0}" != 0 ] && [ -s /opt/lvmshim/tls/cert.pem ] && command -v python3 >/dev/null; then
    UNLOCK_PORT=$UNLOCK_WEB_PORT python3 /opt/lvmshim/unlock-web.py &
    WEBPID=$!
    logger -t luks-pools "browser unlock page on https://<nas>:$UNLOCK_WEB_PORT"
  fi
  logger -t luks-pools "waiting for unlock (timeout ${UNLOCK_TIMEOUT}s, 0 = forever): ssh + /opt/lvmshim/unlock.sh, or the browser page"
fi

t=0
while ! all_open; do
  [ "$UNLOCK_TIMEOUT" -gt 0 ] && [ $t -ge "$UNLOCK_TIMEOUT" ] && break
  # restart the page if it died
  if [ -n "$WEBPID" ] && ! kill -0 $WEBPID 2>/dev/null; then
    UNLOCK_PORT=$UNLOCK_WEB_PORT python3 /opt/lvmshim/unlock-web.py & WEBPID=$!
  fi
  sleep 1; t=$((t+1))
done
[ -n "$WEBPID" ] && { sleep 3; kill $WEBPID 2>/dev/null; }   # 3 s: let the page answer "done"

if all_open; then
  for u in $(present_uuids); do
    md=$(md_active_dev "$u"); c=$(crypt_name "$md")
    vg=$(/usr/sbin/lvm pvs --noheadings -o vg_name /dev/mapper/$c 2>/dev/null | tr -d ' ')
    [ -n "$vg" ] && /usr/sbin/lvm vgchange -ay "$vg"
  done
  vgcfgbackup >/dev/null 2>&1
  logger -t luks-pools "all pools unlocked, continuing boot"
  exit 0
fi
logger -t luks-pools "not all pools unlocked in ${UNLOCK_TIMEOUT}s - powering off to protect them"
for u in $(present_uuids); do
  md=$(md_active_dev "$u") || continue
  [ -b /dev/mapper/$(crypt_name "$md") ] || mdadm --stop "$md"
done
systemctl --no-block poweroff
exit 1
EOF_WAIT

# -----------------------------------------------------------------------------
cat > $D/poolstate.sh <<'EOF_STATE'
#!/bin/bash
# one line per pool: <md-uuid> <md device|-> <crypt name|-> <open|locked|missing>
. /opt/lvmshim/common.sh
for u in $(pool_uuids); do
  if md=$(md_active_dev "$u"); then
    c=$(crypt_name "$md"); [ -b /dev/mapper/$c ] && st=open || st=locked
  elif md_members_present "$u"; then md=-; c=-; st=missing
  else md=-; c=-; st=absent; fi
  echo "$u $md $c $st"
done
EOF_STATE

cat > $D/open-pool.sh <<'EOF_OPEN'
#!/bin/bash
# open one pool by md UUID; passphrase is read from stdin (exactly, no newline added)
. /opt/lvmshim/common.sh
u=$1
pool_uuids | grep -qx "$u" || { echo "unknown pool"; exit 3; }
md=$(md_ensure "$u" 2>/dev/null) || { echo "cannot assemble the RAID array"; exit 2; }
c=$(crypt_name "$md")
[ -b /dev/mapper/$c ] && { echo "already unlocked"; exit 0; }
cryptsetup open --key-file=- "$md" "$c" >/dev/null 2>&1 || { echo "wrong passphrase"; exit 1; }
vg=$(/usr/sbin/lvm pvs --noheadings -o vg_name /dev/mapper/$c 2>/dev/null | tr -d ' ')
[ -n "$vg" ] && /usr/sbin/lvm vgchange -ay "$vg" >/dev/null 2>&1
logger -t luks-pools "unlocked $md as $c"
echo "unlocked"
EOF_OPEN

cat > $D/unlock-web.py <<'EOF_WEB'
#!/usr/bin/env python3
"""Minimal HTTPS unlock page, run by wait-unlock.sh only while pools are locked.
Standard library only. Passphrases go to cryptsetup on stdin and are never logged."""
import html, http.server, os, secrets, ssl, subprocess, threading, time, urllib.parse

BASE = os.environ.get('LVMSHIM_DIR', '/opt/lvmshim')
PORT = int(os.environ.get('UNLOCK_PORT', '8443'))
CERT, KEY = BASE + '/tls/cert.pem', BASE + '/tls/key.pem'
HOST = os.uname().nodename
LOCK = threading.Lock()
RESULTS = {}

def pools():
    out = subprocess.run([BASE + '/poolstate.sh'], capture_output=True, text=True).stdout
    return [l.split() for l in out.splitlines() if len(l.split()) == 4]

def render(msgs, done):
    rows = ''.join(
        '<tr><td>{}</td><td class="{}">{}</td></tr>'.format(
            html.escape(md if md != '-' else 'array ' + u[:8]), st,
            {'open': 'unlocked', 'locked': 'locked', 'missing': 'array not assembled', 'absent': 'disks not in NAS, skipped'}[st])
        for u, md, c, st in pools())
    note = ''.join('<p class="msg">{}</p>'.format(html.escape(m)) for m in msgs)
    if done:
        body = ('<p class="ok">All pools are unlocked. TOS is starting now; its web interface '
                'will be available in about a minute.</p>')
    else:
        body = ('<form method="post" action="/" autocomplete="off">'
                '<label for="pw">Passphrase</label>'
                '<input id="pw" name="pw" type="password" autocomplete="off" autofocus required>'
                '<button type="submit">Unlock</button></form>'
                '<p class="hint">The passphrase is tried on every locked pool. '
                'Pools with a different passphrase stay locked; submit again for those.</p>')
    return f'''<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>{html.escape(HOST)} unlock</title>
<style>
:root{{--bg:#f6f6f4;--fg:#1d1d1b;--muted:#6b6b66;--card:#fff;--line:#deded9;--acc:#2f5d8a;--ok:#2e7d4f;--bad:#b3261e}}
@media (prefers-color-scheme:dark){{:root{{--bg:#151514;--fg:#ececea;--muted:#9a9a95;--card:#1f1f1d;--line:#33332f;--acc:#7aa7d6;--ok:#6cc08b;--bad:#f08a80}}}}
body{{margin:0;background:var(--bg);color:var(--fg);font:16px/1.45 system-ui,sans-serif}}
main{{max-width:420px;margin:12vh auto;padding:0 16px}}
.card{{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:24px}}
h1{{font-size:20px;margin:0 0 4px}} .sub{{color:var(--muted);margin:0 0 18px;font-size:14px}}
table{{width:100%;border-collapse:collapse;margin-bottom:18px;font-size:14px}}
td{{padding:6px 0;border-bottom:1px solid var(--line)}} td:last-child{{text-align:right}}
.open{{color:var(--ok)}} .locked,.missing{{color:var(--bad)}} .absent{{color:var(--muted)}}
label{{display:block;font-size:14px;margin-bottom:6px}}
input{{box-sizing:border-box;width:100%;padding:10px;font-size:16px;border:1px solid var(--line);border-radius:6px;background:var(--bg);color:var(--fg)}}
button{{margin-top:12px;width:100%;padding:10px;font-size:16px;border:0;border-radius:6px;background:var(--acc);color:#fff;cursor:pointer}}
.hint{{color:var(--muted);font-size:13px;margin:14px 0 0}} .msg{{font-size:14px;margin:0 0 12px}} .ok{{color:var(--ok)}}
</style></head><body><main><div class="card">
<h1>Unlock encrypted storage</h1><p class="sub">{html.escape(HOST)} is waiting before it starts its storage services.</p>
<table>{rows}</table>{note}{body}</div></main></body></html>'''

class Handler(http.server.BaseHTTPRequestHandler):
    server_version = 'unlock'
    sys_version = ''
    timeout = 30

    def log_message(self, fmt, *args):
        pass

    def page(self, msgs=(), done=False):
        data = render(msgs, done).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(data)))
        self.send_header('Cache-Control', 'no-store')
        self.send_header('X-Frame-Options', 'DENY')
        self.send_header('Referrer-Policy', 'no-referrer')
        self.send_header('Content-Security-Policy',
                         "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'")
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        url = urllib.parse.urlsplit(self.path)
        if url.path not in ('/', '/index.html'):
            self.send_error(404); return
        token = urllib.parse.parse_qs(url.query).get('r', [''])[0]
        with LOCK:
            msgs = RESULTS.pop(token, ())      # shown once; a reload shows the plain page
        self.page(msgs, done=all(p[3] in ('open', 'absent') for p in pools()))

    def do_POST(self):
        n = int(self.headers.get('Content-Length') or 0)
        if n <= 0 or n > 4096:
            self.send_error(400); return
        form = urllib.parse.parse_qs(self.rfile.read(n).decode('utf-8', 'replace'), keep_blank_values=True)
        pw = form.get('pw', [''])[0]
        msgs = []
        if not pw:
            msgs.append('Enter a passphrase.')
        else:
            with LOCK:                      # one attempt at a time
                opened = 0
                for u, md, c, st in pools():
                    if st in ('open', 'absent'):
                        continue
                    r = subprocess.run([BASE + '/open-pool.sh', u], input=pw.encode('utf-8'),
                                       capture_output=True)
                    name = md if md != '-' else 'array ' + u[:8]
                    msgs.append('{}: {}'.format(name, r.stdout.decode(errors='replace').strip() or 'failed'))
                    opened += (r.returncode == 0)
                if not opened:
                    time.sleep(3)           # slow down guessing
        pw = None
        # Post/Redirect/Get: the browser keeps only a GET in its history, so a reload or a
        # reconnecting tab can never send the passphrase again
        token = secrets.token_urlsafe(16)
        with LOCK:
            RESULTS[token] = msgs
            while len(RESULTS) > 20:
                RESULTS.pop(next(iter(RESULTS)))
        self.send_response(303)
        self.send_header('Location', '/?r=' + token)
        self.send_header('Content-Length', '0')
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()

class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def handle_error(self, request, client_address):
        pass                                # plain-HTTP probes, dropped connections

def main():
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    ctx.load_cert_chain(CERT, KEY)
    srv = Server(('', PORT), Handler)
    srv.socket = ctx.wrap_socket(srv.socket, server_side=True, do_handshake_on_connect=False)
    srv.serve_forever()

if __name__ == '__main__':
    main()
EOF_WEB

cat > $D/settings.conf.default <<'EOF_SET'
# /opt/lvmshim/settings.conf
# Seconds to wait for the unlock at boot before powering off; 0 = wait forever.
UNLOCK_TIMEOUT=0
# Port of the browser unlock page (https); 0 disables the page.
UNLOCK_WEB_PORT=8443
EOF_SET

# -----------------------------------------------------------------------------
cat > $D/check.sh <<'EOF_CHECK'
#!/bin/bash
# Read-only health check. Exit code 0 = all PASS.
. /opt/lvmshim/common.sh
fail=0
ok(){ echo "  PASS  $*"; }
bad(){ echo "  FAIL  $*"; fail=1; }

echo "== components (kit version $(cat /opt/lvmshim/VERSION 2>/dev/null || echo unknown))"
for c in pvs vgs lvs pvresize vgcfgbackup lvcreate lvextend; do
  [ "$(readlink /usr/sbin/$c)" = /opt/lvmshim/lvm-shim ] && ok "$c shimmed" || bad "$c not shimmed (run install-shims.sh)"
done
[ "$(readlink /usr/sbin/blkid)" = /opt/lvmshim/blkid-shim ] && [ -x /usr/sbin/blkid.real ] && ok "blkid shimmed" || bad "blkid not shimmed"
[ "$(readlink /usr/bin/lsblk)" = /opt/lvmshim/lsblk-shim ] && [ -x /usr/bin/lsblk.real ] && ok "lsblk shimmed" || bad "lsblk not shimmed"
[ -e /opt/lvmshim/DEBUG ] && bad "debug logging is on (rm /opt/lvmshim/DEBUG)" || ok "debug logging off"
systemctl is-enabled luks-pools.service >/dev/null 2>&1 && ok "luks-pools.service enabled" || bad "luks-pools.service not enabled"
systemctl is-enabled ssh.service >/dev/null 2>&1 && ok "SSH enabled at boot" \
  || bad "SSH not enabled at boot - enable it in the TOS UI, otherwise pools cannot be unlocked (NAS powers off)"
[ -e /etc/systemd/system/luks-md1.service ] && bad "old luks-md1.service still present" || ok "no old unit"
[ -s /opt/lvmshim/tls/cert.pem ] && command -v python3 >/dev/null && ok "browser unlock page ready (port $(. /opt/lvmshim/settings.conf; echo $UNLOCK_WEB_PORT))" || bad "browser unlock page not available (certificate or python3 missing)"
( . /opt/lvmshim/settings.conf; [ "${UNLOCK_TIMEOUT:-0}" = 0 ] ) && ok "boot waits for unlock without time limit" || ok "boot powers off after $(. /opt/lvmshim/settings.conf; echo $UNLOCK_TIMEOUT)s without unlock"
[ -n "$(pool_uuids)" ] && ok "pools.conf: $(pool_uuids | wc -l) pool(s)" || bad "pools.conf has no pools"

for u in $(pool_uuids); do
  echo "== pool $u"
  md_members_present "$u" || { ok "disks of this pool are not in the NAS - skipped (re-insert, then reboot and unlock)"; continue; }
  md=$(md_active_dev "$u") || { bad "array not active"; continue; }
  c=$(crypt_name "$md"); n=${md#/dev/md}
  ok "array is $md"
  grep -q '\[U*\]' <(grep -A1 "^md$n " /proc/mdstat) && ! grep -A1 "^md$n " /proc/mdstat | grep -q '_' \
     && ok "RAID healthy" || bad "RAID degraded or rebuilding: $(grep -A1 "^md$n " /proc/mdstat | tail -1)"
  cryptsetup luksDump "$md" >/dev/null 2>&1 && ok "LUKS header readable" || bad "no readable LUKS header on $md"
  [ -b /dev/mapper/$c ] || { bad "$c not open (run unlock.sh)"; continue; }
  ok "$c open"
  t=$(blkid -o value -s TYPE "$md");                 [ "$t" = LVM2_member ] && ok "blkid sees LVM2_member" || bad "blkid sees '$t'"
  t=$(lsblk --noheadings -o FSTYPE "$md" | head -1); [ "$t" = LVM2_member ] && ok "lsblk sees LVM2_member" || bad "lsblk sees '$t'"
  vg=$(pvs --noheadings -o vg_name "$md" 2>/dev/null | tr -d ' ')
  [ -n "$vg" ] && ok "pvs $md -> $vg" || { bad "pvs $md shows no VG"; continue; }
  ps=$(pvs --noheadings --units s --nosuffix -o pe_start "$md" 2>/dev/null | tr -d ' ')
  [ -n "$ps" ] && [ $((ps % 8)) = 0 ] && ok "PV data start $ps sectors (4K aligned)" || bad "PV data start '$ps' not 4K aligned - volumes cannot be created"
  h=$(sed -n 's/.*device = "\([^"]*\)".*/\1/p' /etc/lvm/backup/$vg 2>/dev/null | head -1)
  [ "$h" = "$md" ] && ok "LVM backup hint $h" || bad "LVM backup hint is '$h' (run: vgcfgbackup)"
  tag=$(pvs --noheadings -o vg_tags "$md" 2>/dev/null | tr -d ' ')
  [ -n "$tag" ] && grep -q "^\[$tag\]" /etc/volume/storage.conf && ok "registered as TOS pool $tag" || bad "VG tag '$tag' not in storage.conf"
  grep -q "^\[$u\]" /etc/volume/storage.conf /etc/volume/volume.conf 2>/dev/null \
     && bad "bogus legacy entry [$u] in /etc/volume/*.conf" || ok "no legacy-volume entry"
  hb=$(header_file "$u")
  if [ -f "$hb" ]; then
    cmp -s <(head -c "$(stat -c %s "$hb")" "$md") "$hb" && ok "header matches $hb" || bad "header differs from $hb"
  else bad "no header backup $hb"; fi
  for lv in $(lvs --noheadings -o lv_name "$vg" 2>/dev/null); do
    mp=$(findmnt -rn -o TARGET -S "/dev/mapper/$vg-$lv" 2>/dev/null | grep -m1 '^/Volume')
    [ -n "$mp" ] && ok "volume $vg/$lv mounted on $mp" || bad "volume $vg/$lv not mounted"
  done
done
echo "== misc"
[ -s /run/lvmshim/unhandled.log ] && bad "unhandled lsblk calls in /run/lvmshim/unhandled.log" || ok "no unhandled lsblk calls"
echo
[ $fail = 0 ] && echo "RESULT: ALL CHECKS PASSED" || echo "RESULT: SOME CHECKS FAILED - do not continue"
exit $fail
EOF_CHECK

# -----------------------------------------------------------------------------
cat > $D/convert-pool.sh <<'EOF_CONV'
#!/bin/bash
# Convert an EMPTY TOS pool (md -> PV -> VG, no volumes) into md -> LUKS -> PV -> VG.
# Usage: convert-pool.sh /dev/mdN        ALL DATA ON THE ARRAY IS DESTROYED.
. /opt/lvmshim/common.sh
md=${1:-}
die(){ echo; echo "STOP: $*"; exit 1; }
[[ $md =~ ^/dev/md[0-9]+$ ]] || { echo "usage: $0 /dev/mdN"; exit 2; }
n=${md#/dev/md}; c=crypt$n
LVM=/usr/sbin/lvm

echo "== pre-checks"
[ -b "$md" ] || die "$md does not exist"
case $n in 8|9) die "$md is a TOS system/swap array";; esac
u=$(mdadm --detail --export "$md" | sed -n 's/^MD_UUID=//p'); [ -n "$u" ] || die "no MD_UUID for $md"
pool_uuids | grep -qx "$u" && die "$u is already in $POOLS_CONF"
[ "$(cat /sys/block/md$n/md/degraded)" = 0 ] || die "array is degraded"
[ "$(cat /sys/block/md$n/md/sync_action)" = idle ] || die "array is syncing/rebuilding - wait until it is idle"
[ -e /dev/mapper/$c ] && die "/dev/mapper/$c already exists"
[ "$(md_conf_name "$u")" = "$md" ] || die "mdadm config does not list $u as $md"
sz=$(blockdev --getsz "$md"); [ $((sz % 8)) = 0 ] || die "array size is not 4K aligned"
/opt/lvmshim/install-shims.sh
vg=$($LVM pvs --noheadings -o vg_name "$md" 2>/dev/null | tr -d ' ')
[ -n "$vg" ] || die "$md is not an LVM PV with a VG - create the pool in the TOS UI first"
[ "$($LVM vgs --noheadings -o pv_count "$vg" | tr -d ' ')" = 1 ] || die "$vg has more than one PV"
[ "$($LVM vgs --noheadings -o lv_count "$vg" | tr -d ' ')" = 0 ] || die "$vg still has volumes - delete them in the UI first"
tag=$($LVM vgs --noheadings -o vg_tags "$vg" | tr -d ' ')
vgid=$($LVM vgs --noheadings -o vg_uuid "$vg" | tr -d ' ')
pvid=$($LVM pvs --noheadings -o pv_uuid "$md" | tr -d ' ')
pe_start=$($LVM pvs --noheadings --units s --nosuffix -o pe_start "$md" | tr -d ' ')
# LUKS uses 4 KiB sectors: the data start must be 4K aligned. TOS may pick odd offsets
# (e.g. 65535 from a bogus optimal-io hint), so round up to a 1 MiB boundary.
pe_start=$(( (pe_start + 2047) / 2048 * 2048 ))
ext=$($LVM vgs --noheadings --units s --nosuffix -o vg_extent_size "$vg" | tr -d ' ')
[ -n "$tag" ] && grep -q "^\[$tag\]" /etc/volume/storage.conf || die "VG tag '$tag' is not a TOS pool in storage.conf"
grep -qs "$u" /etc/volume/storage/$tag.json || die "/etc/volume/storage/$tag.json does not reference $u"
mkdir -p "$STATE_DIR"; B="$STATE_DIR/${u//:/-}"
$LVM vgcfgbackup -f "$B.vg.orig" "$vg" >/dev/null || die "vgcfgbackup failed"
cp /etc/volume/storage/$tag.json "$B.pool.json"

cat <<INFO

  array      $md   (md UUID $u)
  VG         $vg   (uuid $vgid, TOS tag $tag)
  PV uuid    $pvid
  pe_start   $pe_start sectors, extent $ext sectors
  mapping    /dev/mapper/$c

  ALL DATA ON $md WILL BE DESTROYED.
INFO
read -r -p "Type YES to encrypt $md: " a; [ "$a" = YES ] || die "aborted, nothing changed"

echo "== encrypting"
systemctl stop StorageManager
$LVM vgchange -an "$vg" >/dev/null || die "vgchange -an failed (StorageManager is stopped; start it again)"
wipefs -a "$md" >/dev/null
cryptsetup luksFormat --type luks2 --sector-size 4096 "$md" || die "luksFormat failed - array now has no PV; re-run convert or delete the pool in the UI"
cryptsetup open "$md" "$c" || die "cryptsetup open failed"
cryptsetup luksHeaderBackup "$md" --header-backup-file "$(header_file "$u")" || die "header backup failed"

echo "== restoring $vg on /dev/mapper/$c"
SZ=$(blockdev --getsz /dev/mapper/$c); PE=$(( (SZ - pe_start) / ext ))
[ "$PE" -gt 0 ] || die "computed pe_count $PE"
sed -E "s/(pe_start = )[0-9]+/\1$pe_start/; s/(dev_size = )[0-9]+/\1$SZ/; s/(pe_count = )[0-9]+/\1$PE/" "$B.vg.orig" > "$B.vg.luks"
$LVM pvcreate -y --uuid "$pvid" --restorefile "$B.vg.luks" /dev/mapper/$c >/dev/null || die "pvcreate failed"
$LVM vgcfgrestore -f "$B.vg.luks" "$vg" >/dev/null || die "vgcfgrestore failed"
$LVM vgchange -ay "$vg" >/dev/null
echo "$u" >> "$POOLS_CONF"
vgcfgbackup >/dev/null 2>&1        # via shim: hint -> $md

echo "== post-checks"
[ "$($LVM vgs --noheadings -o vg_uuid "$vg" | tr -d ' ')" = "$vgid" ] || die "VG uuid changed"
[ "$(pvs --noheadings -o vg_name "$md" | tr -d ' ')" = "$vg" ] || die "pvs $md does not show $vg"
[ "$($LVM pvs --noheadings --units s --nosuffix -o pe_start /dev/mapper/$c | tr -d ' ')" = "$pe_start" ] || die "PV data start is not $pe_start"
# prove the kernel accepts LVs on it: create and remove a 4 MiB test LV
$LVM lvcreate -y -l 1 -n luks_probe "$vg" >/dev/null 2>&1 && $LVM lvremove -y "$vg/luks_probe" >/dev/null 2>&1 \
  || die "test volume could not be created on $vg - do not create volumes in the UI"
vgcfgbackup >/dev/null 2>&1
[ "$(blkid -o value -s TYPE "$md")" = LVM2_member ] || die "blkid shim not effective"
grep -q "device = \"$md\"" /etc/lvm/backup/$vg || die "LVM backup hint not $md"
systemctl start StorageManager
echo
echo "DONE: $md is now LUKS-encrypted (pe_count $PE). Header backup: $(header_file "$u")"
echo "Copy the header backup OFF the NAS now. Then run /opt/lvmshim/check.sh"
EOF_CONV

# -----------------------------------------------------------------------------
chmod 755 $D/*.sh $D/*-shim $D/log $D/unlock-web.py
[ -f $D/settings.conf ] || cp $D/settings.conf.default $D/settings.conf

# self-signed certificate for the browser unlock page (kept across re-installs)
if [ ! -s $D/tls/cert.pem ]; then
  mkdir -p $D/tls && chmod 700 $D/tls
  if command -v openssl >/dev/null; then
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=$(hostname)" \
      -keyout $D/tls/key.pem -out $D/tls/cert.pem >/dev/null 2>&1 && chmod 600 $D/tls/key.pem
  else
    echo "WARNING: openssl not found - browser unlock page disabled (SSH unlock still works)"
  fi
fi
touch $D/pools.conf
grep -q '^#' $D/pools.conf || sed -i '1i # md UUIDs (mdadm format) of LUKS-encrypted pools, one per line' $D/pools.conf

cat > /etc/systemd/system/luks-pools.service <<'EOF_UNIT'
[Unit]
Description=Wait for LUKS unlock of encrypted md pools before TOS storage
After=ssh.service network.target
Before=tnas-mntfc.service tnas-mntdata.service StorageManager.service

[Service]
Type=oneshot
RemainAfterExit=yes
TimeoutStartSec=infinity
ExecStart=/opt/lvmshim/wait-unlock.sh

[Install]
WantedBy=tnas-system.target
EOF_UNIT

# keep a copy of this installer next to the data (survives firmware updates of /opt)
cp -f "$0" /root/luks-pools/luks-kit-install.sh 2>/dev/null || true

systemctl daemon-reload
$D/install-shims.sh
[ -s $D/tls/cert.pem ] && echo "Unlock page certificate $(openssl x509 -noout -fingerprint -sha256 -in $D/tls/cert.pem)"
echo "$KIT_VERSION" > $D/VERSION
echo "Kit version $KIT_VERSION installed to $D. Unit: luks-pools.service ($(systemctl is-enabled luks-pools.service 2>/dev/null || echo disabled))"#!/bin/bash
# =============================================================================
#  luks-kit-install.sh  -  LUKS directly on TOS md RAID (md -> LUKS -> PV -> VG)
#  TerraMaster TOS 7 (tested on F4-212, TOS_ARM2.0_6.0.587)
#
#  Installs / updates everything in /opt/lvmshim and the boot unit
#  luks-pools.service. Safe to re-run (idempotent). Does NOT touch any disk.
#
#  Encrypted arrays are listed by md UUID in /opt/lvmshim/pools.conf, so it
#  does not matter whether TOS names an array md1, md2, md127 ...
#  An open array /dev/mdN is always mapped as /dev/mapper/cryptN.
# =============================================================================
KIT_VERSION=2026-10-25
set -e
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }

D=/opt/lvmshim
[ -d $D ] && cp -a $D /root/lvmshim.bak.$(date +%Y%m%d-%H%M%S)
mkdir -p $D /root/luks-pools

# -----------------------------------------------------------------------------
cat > $D/common.sh <<'EOF_COMMON'
#!/bin/bash
# shared helpers
POOLS_CONF=/opt/lvmshim/pools.conf
STATE_DIR=/root/luks-pools

# md UUIDs of encrypted pools (one per line in pools.conf)
pool_uuids(){ grep -vE '^[[:space:]]*(#|$)' "$POOLS_CONF" 2>/dev/null | awk '{print $1}'; }

# device name TOS uses for this array, from the mdadm config (e.g. /dev/md1)
md_conf_name(){
  local f
  for f in /etc/mdadm/mdadm.conf /etc/mdadm.conf; do
    [ -r "$f" ] && awk -v u="UUID=$1" '$1=="ARRAY" && index($0,u){print $2; exit}' "$f"
  done | head -1
}

# active md device carrying this UUID (empty if not assembled)
md_active_dev(){
  local d
  for d in /dev/md[0-9]*; do
    [ -b "$d" ] || continue
    [ "$(mdadm --detail --export "$d" 2>/dev/null | sed -n 's/^MD_UUID=//p')" = "$1" ] && { echo "$d"; return 0; }
  done
  return 1
}

# make sure the array is assembled (under the name TOS expects); print device
md_ensure(){
  local d
  d=$(md_active_dev "$1") && { echo "$d"; return 0; }
  d=$(md_conf_name "$1")
  if [ -n "$d" ]; then mdadm --assemble --run "$d" --uuid="$1" >&2 || return 1
  else mdadm --assemble --scan --run --uuid="$1" >&2 || return 1; fi
  md_active_dev "$1"
}

# at least one member disk of this array is in the NAS (or the array is running)
md_members_present(){ md_active_dev "$1" >/dev/null || mdadm --examine --scan 2>/dev/null | grep -qi "UUID=$1"; }

# pools from pools.conf whose disks are present; pools with all disks removed are skipped
present_uuids(){ local u; for u in $(pool_uuids); do md_members_present "$u" && echo "$u"; done; }

crypt_name(){ echo "crypt${1#/dev/md}"; }      # /dev/md2 -> crypt2
header_file(){ echo "$STATE_DIR/${1//:/-}-header.img"; }
EOF_COMMON

# -----------------------------------------------------------------------------
cat > $D/lvm-shim <<'EOF_LVM'
#!/bin/bash
# Wraps every LVM command. While /dev/mapper/cryptN is open:
#  - argument /dev/mdN  -> /dev/mapper/cryptN
#  - output /dev/mapper/cryptN -> /dev/mdN
#  - device hints in /etc/lvm/backup/* rewritten to /dev/mdN
#    (StorageManager maps VG -> md from those hints)
cmd=$(basename "$0")
args=()
for a in "$@"; do
  if [[ $a =~ ^/dev/md([0-9]+)$ ]] && [ -b "/dev/mapper/crypt${BASH_REMATCH[1]}" ]; then
    n=${BASH_REMATCH[1]}
    [ "$cmd" = pvresize ] && cryptsetup resize "crypt$n"
    a="/dev/mapper/crypt$n"
  fi
  args+=("$a")
done
fix(){ sed -E 's#/dev/mapper/crypt([0-9]+)#/dev/md\1#g'; }
fixbak(){
  grep -l 'device = "/dev/mapper/crypt[0-9]' /etc/lvm/backup/* 2>/dev/null \
    | xargs -r sed -i -E 's#(device = ")/dev/mapper/crypt([0-9]+)"#\1/dev/md\2"#'
}
if [ -e /opt/lvmshim/DEBUG ]; then
  out=$(/usr/sbin/lvm "$cmd" "${args[@]}" | fix; exit ${PIPESTATUS[0]}); rc=$?
  fixbak
  /opt/lvmshim/log "$cmd" "$rc" "$out" "$@"
  [ -n "$out" ] && printf '%s\n' "$out"; exit $rc
fi
/usr/sbin/lvm "$cmd" "${args[@]}" | fix
rc=${PIPESTATUS[0]}
fixbak
exit $rc
EOF_LVM

# -----------------------------------------------------------------------------
cat > $D/blkid-shim <<'EOF_BLKID'
#!/bin/bash
# blkid: an open /dev/mdN is reported with the type of what is inside (LVM2_member)
REAL=/usr/sbin/blkid.real
ls /dev/mapper/crypt[0-9]* &>/dev/null || exec $REAL "$@"
args=(); devs=0
for a in "$@"; do
  if [[ $a =~ ^/dev/md([0-9]+)$ ]]; then
    devs=1; [ -b "/dev/mapper/crypt${BASH_REMATCH[1]}" ] && a="/dev/mapper/crypt${BASH_REMATCH[1]}"
  elif [[ $a == /dev/* && $a != /dev/null ]]; then devs=1; fi
  args+=("$a")
done
open=$(ls /dev/mapper/ | sed -n 's/^crypt\([0-9][0-9]*\)$/md\1/p' | paste -sd'|')
doit(){
  if [ $devs -eq 0 ]; then
    $REAL "${args[@]}" | grep -Ev "^/dev/(${open}):" | sed -E 's#^/dev/mapper/crypt([0-9]+):#/dev/md\1:#'
    return ${PIPESTATUS[0]}
  fi
  $REAL "${args[@]}" | sed -E 's#/dev/mapper/crypt([0-9]+)#/dev/md\1#g'
  return ${PIPESTATUS[0]}
}
if [ -e /opt/lvmshim/DEBUG ]; then
  out=$(doit); rc=$?
  /opt/lvmshim/log blkid $rc "$out" "$@"
  [ -n "$out" ] && printf '%s\n' "$out"; exit $rc
fi
doit; exit $?
EOF_BLKID

# -----------------------------------------------------------------------------
cat > $D/lsblk-shim <<'EOF_LSBLK'
#!/bin/bash
# lsblk: hide the crypt layer from TOS (JSON tree and single-column queries)
REAL=/usr/bin/lsblk.real
ls /dev/mapper/crypt[0-9]* &>/dev/null || exec $REAL "$@"
json=0; nohead=0; nodeps=0; col=""; md=""; ndev=0; prev=""
for a in "$@"; do
  case "$a" in
    --json) json=1 ;; --noheadings) nohead=1 ;; --nodeps) nodeps=1 ;;
    --output=*) col="${a#--output=}" ;;
    --*) ;;
    -*) [[ $a == *J* ]] && json=1; [[ $a == *n* ]] && nohead=1; [[ $a == *d* ]] && nodeps=1 ;;
    /dev/*) ndev=$((ndev+1)); [[ $a =~ ^/dev/md([0-9]+)$ ]] && [ -b "/dev/mapper/crypt${BASH_REMATCH[1]}" ] && md="${BASH_REMATCH[1]}" ;;
    *) [[ $prev == -o || $prev == --output || $prev =~ ^-[a-zA-Z]*o$ ]] && col="$a" ;;
  esac
  prev="$a"
done
doit(){
  local o r inner
  if [ $json -eq 1 ]; then
    $REAL "$@" | python3 /opt/lvmshim/lsblk-json.py; return ${PIPESTATUS[0]}
  fi
  if [ -z "$md" ]; then $REAL "$@"; return $?; fi
  if [ $ndev -ne 1 ] || [[ -z $col || $col == *,* ]]; then
    mkdir -p /run/lvmshim; echo "$(date +%F_%T) passthrough: lsblk $*" >> /run/lvmshim/unhandled.log
    $REAL "$@"; return $?
  fi
  o=$($REAL "$@"); r=$?
  if [ "${col^^}" = FSTYPE ]; then inner=$($REAL -dno FSTYPE /dev/mapper/crypt$md); else inner=""; fi
  echo "$o" | awk -v h=$nohead -v d=$nodeps -v isfs="${col^^}" -v inner="$inner" '
    BEGIN{mdrow = (h ? 1 : 2)}
    NR < mdrow {print; next}
    NR == mdrow {print (isfs=="FSTYPE" ? inner : $0); next}
    NR == mdrow+1 && !d {next}
    {print}'
  return $r
}
if [ -e /opt/lvmshim/DEBUG ]; then
  out=$(doit "$@"); rc=$?
  /opt/lvmshim/log lsblk $rc "$out" "$@"
  [ -n "$out" ] && printf '%s\n' "$out"; exit $rc
fi
doit "$@"; exit $?
EOF_LSBLK

# -----------------------------------------------------------------------------
cat > $D/lsblk-json.py <<'EOF_JSON'
import json, sys, os
raw = sys.stdin.read()
try:
    d = json.loads(raw)
except Exception:
    sys.stdout.write(raw); sys.exit(0)
def nm(n):
    return os.path.basename(n.get('name') or n.get('kname') or '')
def fix(nodes):
    for n in nodes:
        ch = n.get('children') or []
        base = nm(n)
        if base.startswith('md') and base[2:].isdigit():
            for c in list(ch):
                if nm(c) == 'crypt' + base[2:]:
                    if 'fstype' in n:
                        n['fstype'] = c.get('fstype')
                    ch.remove(c)
                    ch.extend(c.get('children') or [])
            if ch: n['children'] = ch
            else: n.pop('children', None)
        if n.get('children'):
            fix(n['children'])
fix(d.get('blockdevices', []))
print(json.dumps(d, indent=3))
EOF_JSON

# -----------------------------------------------------------------------------
cat > $D/log <<'EOF_LOG'
#!/bin/bash
# debug logger, active only while /opt/lvmshim/DEBUG exists
cmd=$1; rc=$2; out=$3; shift 3
p1=$(awk '{print $4}' /proc/$PPID/stat 2>/dev/null); p2=$(awk '{print $4}' /proc/$p1/stat 2>/dev/null)
caller="$(cat /proc/$p2/comm 2>/dev/null)/$(cat /proc/$p1/comm 2>/dev/null)"
{ echo "### $(date +%T) [$caller] rc=$rc: $cmd $*"; [ -n "$out" ] && printf '%s\n' "$out" | sed 's/^/    /'; } >> /root/luks-pools/calls.log
EOF_LOG

# -----------------------------------------------------------------------------
cat > $D/install-shims.sh <<'EOF_INST'
#!/bin/bash
# (re)apply all shims - idempotent, run at every boot and after firmware updates
for f in /usr/sbin/*; do
  [ -L "$f" ] && [ "$(readlink "$f")" = lvm ] && ln -sfn /opt/lvmshim/lvm-shim "$f"
done
for c in pvs pvdisplay pvresize pvscan pvremove pvcreate vgs vgdisplay vgchange vgcfgbackup lvs lvdisplay lvcreate lvextend lvremove; do
  [ -e /usr/sbin/$c ] || [ -L /usr/sbin/$c ] || continue
  [ "$(readlink /usr/sbin/$c)" = /opt/lvmshim/lvm-shim ] || ln -sfn /opt/lvmshim/lvm-shim /usr/sbin/$c
done
wrap(){ local bin=$1 shim=$2
  if [ -f "$bin" ] && [ ! -L "$bin" ]; then mv -f "$bin" "$bin.real"; fi
  [ -x "$bin.real" ] || { logger -t lvmshim "missing $bin.real"; return 1; }
  [ "$(readlink $bin)" = "$shim" ] || ln -sfn "$shim" "$bin"
}
wrap /usr/sbin/blkid /opt/lvmshim/blkid-shim
wrap /usr/bin/lsblk  /opt/lvmshim/lsblk-shim
exit 0
EOF_INST

cat > $D/remove-shims.sh <<'EOF_RM'
#!/bin/bash
# restore original tools (encrypted pools will NOT work with TOS afterwards)
for f in /usr/sbin/*; do
  [ -L "$f" ] && [ "$(readlink "$f")" = /opt/lvmshim/lvm-shim ] && ln -sfn lvm "$f"
done
for b in /usr/sbin/blkid /usr/bin/lsblk; do [ -x $b.real ] && mv -f $b.real $b; done
exit 0
EOF_RM

# -----------------------------------------------------------------------------
cat > $D/unlock.sh <<'EOF_UNLOCK'
#!/bin/bash
# Interactive unlock (run over SSH while the NAS waits at boot)
. /opt/lvmshim/common.sh
/opt/lvmshim/install-shims.sh
[ -n "$(pool_uuids)" ] || { echo "no pools in $POOLS_CONF"; exit 1; }
for u in $(pool_uuids); do md_members_present "$u" || echo "SKIP: $u - no disks of this pool in the NAS"; done
rc=0
for u in $(present_uuids); do
  md=$(md_ensure "$u") || { echo "FAIL: cannot assemble array $u"; rc=1; continue; }
  c=$(crypt_name "$md")
  if [ ! -b /dev/mapper/$c ]; then
    echo "Unlocking $md ($u) as $c"
    cryptsetup open "$md" "$c" || { echo "FAIL: could not open $md"; rc=1; continue; }
  fi
  vg=$(/usr/sbin/lvm pvs --noheadings -o vg_name /dev/mapper/$c 2>/dev/null | tr -d ' ')
  [ -n "$vg" ] && /usr/sbin/lvm vgchange -ay "$vg" >/dev/null
  echo "OK:   $md -> $c -> ${vg:-<no VG>}"
done
vgcfgbackup >/dev/null 2>&1      # via shim: device hints -> /dev/mdN
exit $rc
EOF_UNLOCK

# -----------------------------------------------------------------------------
cat > $D/wait-unlock.sh <<'EOF_WAIT'
#!/bin/bash
# Boot: holds TOS storage start until every pool is unlocked.
# Unlock routes: SSH (unlock.sh), browser page (https://<nas>:8443), USB key stick.
# UNLOCK_TIMEOUT=0 (default) waits forever; >0 powers off after that many seconds.
. /opt/lvmshim/common.sh
UNLOCK_TIMEOUT=0; UNLOCK_WEB_PORT=8443
[ -r /opt/lvmshim/settings.conf ] && . /opt/lvmshim/settings.conf
/opt/lvmshim/install-shims.sh
for u in $(pool_uuids); do md_members_present "$u" || logger -t luks-pools "pool $u: no member disks present - not waiting for it"; done
[ -n "$(present_uuids)" ] || exit 0

all_open(){ local u md
  for u in $(present_uuids); do
    md=$(md_active_dev "$u") || return 1
    [ -b /dev/mapper/$(crypt_name "$md") ] || return 1
  done; }

for u in $(present_uuids); do md_ensure "$u" >/dev/null || logger -t luks-pools "cannot assemble $u"; done

# optional unattended unlock: USB stick labelled NASKEY with <md-uuid, ':'->'-'>.key
if [ -b /dev/disk/by-label/NASKEY ]; then
  mkdir -p /run/naskey && mount -o ro /dev/disk/by-label/NASKEY /run/naskey && {
    for u in $(present_uuids); do
      md=$(md_active_dev "$u") || continue
      k=/run/naskey/${u//:/-}.key
      [ -f "$k" ] && cryptsetup open --key-file "$k" "$md" "$(crypt_name "$md")"
    done
    umount /run/naskey; }
fi

WEBPID=
if ! all_open; then
  if [ "${UNLOCK_WEB_PORT:-0}" != 0 ] && [ -s /opt/lvmshim/tls/cert.pem ] && command -v python3 >/dev/null; then
    UNLOCK_PORT=$UNLOCK_WEB_PORT python3 /opt/lvmshim/unlock-web.py &
    WEBPID=$!
    logger -t luks-pools "browser unlock page on https://<nas>:$UNLOCK_WEB_PORT"
  fi
  logger -t luks-pools "waiting for unlock (timeout ${UNLOCK_TIMEOUT}s, 0 = forever): ssh + /opt/lvmshim/unlock.sh, or the browser page"
fi

t=0
while ! all_open; do
  [ "$UNLOCK_TIMEOUT" -gt 0 ] && [ $t -ge "$UNLOCK_TIMEOUT" ] && break
  # restart the page if it died
  if [ -n "$WEBPID" ] && ! kill -0 $WEBPID 2>/dev/null; then
    UNLOCK_PORT=$UNLOCK_WEB_PORT python3 /opt/lvmshim/unlock-web.py & WEBPID=$!
  fi
  sleep 1; t=$((t+1))
done
[ -n "$WEBPID" ] && { sleep 3; kill $WEBPID 2>/dev/null; }   # 3 s: let the page answer "done"

if all_open; then
  for u in $(present_uuids); do
    md=$(md_active_dev "$u"); c=$(crypt_name "$md")
    vg=$(/usr/sbin/lvm pvs --noheadings -o vg_name /dev/mapper/$c 2>/dev/null | tr -d ' ')
    [ -n "$vg" ] && /usr/sbin/lvm vgchange -ay "$vg"
  done
  vgcfgbackup >/dev/null 2>&1
  logger -t luks-pools "all pools unlocked, continuing boot"
  exit 0
fi
logger -t luks-pools "not all pools unlocked in ${UNLOCK_TIMEOUT}s - powering off to protect them"
for u in $(present_uuids); do
  md=$(md_active_dev "$u") || continue
  [ -b /dev/mapper/$(crypt_name "$md") ] || mdadm --stop "$md"
done
systemctl --no-block poweroff
exit 1
EOF_WAIT

# -----------------------------------------------------------------------------
cat > $D/poolstate.sh <<'EOF_STATE'
#!/bin/bash
# one line per pool: <md-uuid> <md device|-> <crypt name|-> <open|locked|missing>
. /opt/lvmshim/common.sh
for u in $(pool_uuids); do
  if md=$(md_active_dev "$u"); then
    c=$(crypt_name "$md"); [ -b /dev/mapper/$c ] && st=open || st=locked
  elif md_members_present "$u"; then md=-; c=-; st=missing
  else md=-; c=-; st=absent; fi
  echo "$u $md $c $st"
done
EOF_STATE

cat > $D/open-pool.sh <<'EOF_OPEN'
#!/bin/bash
# open one pool by md UUID; passphrase is read from stdin (exactly, no newline added)
. /opt/lvmshim/common.sh
u=$1
pool_uuids | grep -qx "$u" || { echo "unknown pool"; exit 3; }
md=$(md_ensure "$u" 2>/dev/null) || { echo "cannot assemble the RAID array"; exit 2; }
c=$(crypt_name "$md")
[ -b /dev/mapper/$c ] && { echo "already unlocked"; exit 0; }
cryptsetup open --key-file=- "$md" "$c" >/dev/null 2>&1 || { echo "wrong passphrase"; exit 1; }
vg=$(/usr/sbin/lvm pvs --noheadings -o vg_name /dev/mapper/$c 2>/dev/null | tr -d ' ')
[ -n "$vg" ] && /usr/sbin/lvm vgchange -ay "$vg" >/dev/null 2>&1
logger -t luks-pools "unlocked $md as $c"
echo "unlocked"
EOF_OPEN

cat > $D/unlock-web.py <<'EOF_WEB'
#!/usr/bin/env python3
"""Minimal HTTPS unlock page, run by wait-unlock.sh only while pools are locked.
Standard library only. Passphrases go to cryptsetup on stdin and are never logged."""
import html, http.server, os, secrets, ssl, subprocess, threading, time, urllib.parse

BASE = os.environ.get('LVMSHIM_DIR', '/opt/lvmshim')
PORT = int(os.environ.get('UNLOCK_PORT', '8443'))
CERT, KEY = BASE + '/tls/cert.pem', BASE + '/tls/key.pem'
HOST = os.uname().nodename
LOCK = threading.Lock()
RESULTS = {}

def pools():
    out = subprocess.run([BASE + '/poolstate.sh'], capture_output=True, text=True).stdout
    return [l.split() for l in out.splitlines() if len(l.split()) == 4]

def render(msgs, done):
    rows = ''.join(
        '<tr><td>{}</td><td class="{}">{}</td></tr>'.format(
            html.escape(md if md != '-' else 'array ' + u[:8]), st,
            {'open': 'unlocked', 'locked': 'locked', 'missing': 'array not assembled', 'absent': 'disks not in NAS, skipped'}[st])
        for u, md, c, st in pools())
    note = ''.join('<p class="msg">{}</p>'.format(html.escape(m)) for m in msgs)
    if done:
        body = ('<p class="ok">All pools are unlocked. TOS is starting now; its web interface '
                'will be available in about a minute.</p>')
    else:
        body = ('<form method="post" action="/" autocomplete="off">'
                '<label for="pw">Passphrase</label>'
                '<input id="pw" name="pw" type="password" autocomplete="off" autofocus required>'
                '<button type="submit">Unlock</button></form>'
                '<p class="hint">The passphrase is tried on every locked pool. '
                'Pools with a different passphrase stay locked; submit again for those.</p>')
    return f'''<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>{html.escape(HOST)} unlock</title>
<style>
:root{{--bg:#f6f6f4;--fg:#1d1d1b;--muted:#6b6b66;--card:#fff;--line:#deded9;--acc:#2f5d8a;--ok:#2e7d4f;--bad:#b3261e}}
@media (prefers-color-scheme:dark){{:root{{--bg:#151514;--fg:#ececea;--muted:#9a9a95;--card:#1f1f1d;--line:#33332f;--acc:#7aa7d6;--ok:#6cc08b;--bad:#f08a80}}}}
body{{margin:0;background:var(--bg);color:var(--fg);font:16px/1.45 system-ui,sans-serif}}
main{{max-width:420px;margin:12vh auto;padding:0 16px}}
.card{{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:24px}}
h1{{font-size:20px;margin:0 0 4px}} .sub{{color:var(--muted);margin:0 0 18px;font-size:14px}}
table{{width:100%;border-collapse:collapse;margin-bottom:18px;font-size:14px}}
td{{padding:6px 0;border-bottom:1px solid var(--line)}} td:last-child{{text-align:right}}
.open{{color:var(--ok)}} .locked,.missing{{color:var(--bad)}} .absent{{color:var(--muted)}}
label{{display:block;font-size:14px;margin-bottom:6px}}
input{{box-sizing:border-box;width:100%;padding:10px;font-size:16px;border:1px solid var(--line);border-radius:6px;background:var(--bg);color:var(--fg)}}
button{{margin-top:12px;width:100%;padding:10px;font-size:16px;border:0;border-radius:6px;background:var(--acc);color:#fff;cursor:pointer}}
.hint{{color:var(--muted);font-size:13px;margin:14px 0 0}} .msg{{font-size:14px;margin:0 0 12px}} .ok{{color:var(--ok)}}
</style></head><body><main><div class="card">
<h1>Unlock encrypted storage</h1><p class="sub">{html.escape(HOST)} is waiting before it starts its storage services.</p>
<table>{rows}</table>{note}{body}</div></main></body></html>'''

class Handler(http.server.BaseHTTPRequestHandler):
    server_version = 'unlock'
    sys_version = ''
    timeout = 30

    def log_message(self, fmt, *args):
        pass

    def page(self, msgs=(), done=False):
        data = render(msgs, done).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(data)))
        self.send_header('Cache-Control', 'no-store')
        self.send_header('X-Frame-Options', 'DENY')
        self.send_header('Referrer-Policy', 'no-referrer')
        self.send_header('Content-Security-Policy',
                         "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'")
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        url = urllib.parse.urlsplit(self.path)
        if url.path not in ('/', '/index.html'):
            self.send_error(404); return
        token = urllib.parse.parse_qs(url.query).get('r', [''])[0]
        with LOCK:
            msgs = RESULTS.pop(token, ())      # shown once; a reload shows the plain page
        self.page(msgs, done=all(p[3] in ('open', 'absent') for p in pools()))

    def do_POST(self):
        n = int(self.headers.get('Content-Length') or 0)
        if n <= 0 or n > 4096:
            self.send_error(400); return
        form = urllib.parse.parse_qs(self.rfile.read(n).decode('utf-8', 'replace'), keep_blank_values=True)
        pw = form.get('pw', [''])[0]
        msgs = []
        if not pw:
            msgs.append('Enter a passphrase.')
        else:
            with LOCK:                      # one attempt at a time
                opened = 0
                for u, md, c, st in pools():
                    if st in ('open', 'absent'):
                        continue
                    r = subprocess.run([BASE + '/open-pool.sh', u], input=pw.encode('utf-8'),
                                       capture_output=True)
                    name = md if md != '-' else 'array ' + u[:8]
                    msgs.append('{}: {}'.format(name, r.stdout.decode(errors='replace').strip() or 'failed'))
                    opened += (r.returncode == 0)
                if not opened:
                    time.sleep(3)           # slow down guessing
        pw = None
        # Post/Redirect/Get: the browser keeps only a GET in its history, so a reload or a
        # reconnecting tab can never send the passphrase again
        token = secrets.token_urlsafe(16)
        with LOCK:
            RESULTS[token] = msgs
            while len(RESULTS) > 20:
                RESULTS.pop(next(iter(RESULTS)))
        self.send_response(303)
        self.send_header('Location', '/?r=' + token)
        self.send_header('Content-Length', '0')
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()

class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def handle_error(self, request, client_address):
        pass                                # plain-HTTP probes, dropped connections

def main():
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    ctx.load_cert_chain(CERT, KEY)
    srv = Server(('', PORT), Handler)
    srv.socket = ctx.wrap_socket(srv.socket, server_side=True, do_handshake_on_connect=False)
    srv.serve_forever()

if __name__ == '__main__':
    main()
EOF_WEB

cat > $D/settings.conf.default <<'EOF_SET'
# /opt/lvmshim/settings.conf
# Seconds to wait for the unlock at boot before powering off; 0 = wait forever.
UNLOCK_TIMEOUT=0
# Port of the browser unlock page (https); 0 disables the page.
UNLOCK_WEB_PORT=8443
EOF_SET

# -----------------------------------------------------------------------------
cat > $D/check.sh <<'EOF_CHECK'
#!/bin/bash
# Read-only health check. Exit code 0 = all PASS.
. /opt/lvmshim/common.sh
fail=0
ok(){ echo "  PASS  $*"; }
bad(){ echo "  FAIL  $*"; fail=1; }

echo "== components (kit version $(cat /opt/lvmshim/VERSION 2>/dev/null || echo unknown))"
for c in pvs vgs lvs pvresize vgcfgbackup lvcreate lvextend; do
  [ "$(readlink /usr/sbin/$c)" = /opt/lvmshim/lvm-shim ] && ok "$c shimmed" || bad "$c not shimmed (run install-shims.sh)"
done
[ "$(readlink /usr/sbin/blkid)" = /opt/lvmshim/blkid-shim ] && [ -x /usr/sbin/blkid.real ] && ok "blkid shimmed" || bad "blkid not shimmed"
[ "$(readlink /usr/bin/lsblk)" = /opt/lvmshim/lsblk-shim ] && [ -x /usr/bin/lsblk.real ] && ok "lsblk shimmed" || bad "lsblk not shimmed"
[ -e /opt/lvmshim/DEBUG ] && bad "debug logging is on (rm /opt/lvmshim/DEBUG)" || ok "debug logging off"
systemctl is-enabled luks-pools.service >/dev/null 2>&1 && ok "luks-pools.service enabled" || bad "luks-pools.service not enabled"
systemctl is-enabled ssh.service >/dev/null 2>&1 && ok "SSH enabled at boot" \
  || bad "SSH not enabled at boot - enable it in the TOS UI, otherwise pools cannot be unlocked (NAS powers off)"
[ -e /etc/systemd/system/luks-md1.service ] && bad "old luks-md1.service still present" || ok "no old unit"
[ -s /opt/lvmshim/tls/cert.pem ] && command -v python3 >/dev/null && ok "browser unlock page ready (port $(. /opt/lvmshim/settings.conf; echo $UNLOCK_WEB_PORT))" || bad "browser unlock page not available (certificate or python3 missing)"
( . /opt/lvmshim/settings.conf; [ "${UNLOCK_TIMEOUT:-0}" = 0 ] ) && ok "boot waits for unlock without time limit" || ok "boot powers off after $(. /opt/lvmshim/settings.conf; echo $UNLOCK_TIMEOUT)s without unlock"
[ -n "$(pool_uuids)" ] && ok "pools.conf: $(pool_uuids | wc -l) pool(s)" || bad "pools.conf has no pools"

for u in $(pool_uuids); do
  echo "== pool $u"
  md_members_present "$u" || { ok "disks of this pool are not in the NAS - skipped (re-insert, then reboot and unlock)"; continue; }
  md=$(md_active_dev "$u") || { bad "array not active"; continue; }
  c=$(crypt_name "$md"); n=${md#/dev/md}
  ok "array is $md"
  grep -q '\[U*\]' <(grep -A1 "^md$n " /proc/mdstat) && ! grep -A1 "^md$n " /proc/mdstat | grep -q '_' \
     && ok "RAID healthy" || bad "RAID degraded or rebuilding: $(grep -A1 "^md$n " /proc/mdstat | tail -1)"
  cryptsetup luksDump "$md" >/dev/null 2>&1 && ok "LUKS header readable" || bad "no readable LUKS header on $md"
  [ -b /dev/mapper/$c ] || { bad "$c not open (run unlock.sh)"; continue; }
  ok "$c open"
  t=$(blkid -o value -s TYPE "$md");                 [ "$t" = LVM2_member ] && ok "blkid sees LVM2_member" || bad "blkid sees '$t'"
  t=$(lsblk --noheadings -o FSTYPE "$md" | head -1); [ "$t" = LVM2_member ] && ok "lsblk sees LVM2_member" || bad "lsblk sees '$t'"
  vg=$(pvs --noheadings -o vg_name "$md" 2>/dev/null | tr -d ' ')
  [ -n "$vg" ] && ok "pvs $md -> $vg" || { bad "pvs $md shows no VG"; continue; }
  ps=$(pvs --noheadings --units s --nosuffix -o pe_start "$md" 2>/dev/null | tr -d ' ')
  [ -n "$ps" ] && [ $((ps % 8)) = 0 ] && ok "PV data start $ps sectors (4K aligned)" || bad "PV data start '$ps' not 4K aligned - volumes cannot be created"
  h=$(sed -n 's/.*device = "\([^"]*\)".*/\1/p' /etc/lvm/backup/$vg 2>/dev/null | head -1)
  [ "$h" = "$md" ] && ok "LVM backup hint $h" || bad "LVM backup hint is '$h' (run: vgcfgbackup)"
  tag=$(pvs --noheadings -o vg_tags "$md" 2>/dev/null | tr -d ' ')
  [ -n "$tag" ] && grep -q "^\[$tag\]" /etc/volume/storage.conf && ok "registered as TOS pool $tag" || bad "VG tag '$tag' not in storage.conf"
  grep -q "^\[$u\]" /etc/volume/storage.conf /etc/volume/volume.conf 2>/dev/null \
     && bad "bogus legacy entry [$u] in /etc/volume/*.conf" || ok "no legacy-volume entry"
  hb=$(header_file "$u")
  if [ -f "$hb" ]; then
    cmp -s <(head -c "$(stat -c %s "$hb")" "$md") "$hb" && ok "header matches $hb" || bad "header differs from $hb"
  else bad "no header backup $hb"; fi
  for lv in $(lvs --noheadings -o lv_name "$vg" 2>/dev/null); do
    mp=$(findmnt -rn -o TARGET -S "/dev/mapper/$vg-$lv" 2>/dev/null | grep -m1 '^/Volume')
    [ -n "$mp" ] && ok "volume $vg/$lv mounted on $mp" || bad "volume $vg/$lv not mounted"
  done
done
echo "== misc"
[ -s /run/lvmshim/unhandled.log ] && bad "unhandled lsblk calls in /run/lvmshim/unhandled.log" || ok "no unhandled lsblk calls"
echo
[ $fail = 0 ] && echo "RESULT: ALL CHECKS PASSED" || echo "RESULT: SOME CHECKS FAILED - do not continue"
exit $fail
EOF_CHECK

# -----------------------------------------------------------------------------
cat > $D/convert-pool.sh <<'EOF_CONV'
#!/bin/bash
# Convert an EMPTY TOS pool (md -> PV -> VG, no volumes) into md -> LUKS -> PV -> VG.
# Usage: convert-pool.sh /dev/mdN        ALL DATA ON THE ARRAY IS DESTROYED.
. /opt/lvmshim/common.sh
md=${1:-}
die(){ echo; echo "STOP: $*"; exit 1; }
[[ $md =~ ^/dev/md[0-9]+$ ]] || { echo "usage: $0 /dev/mdN"; exit 2; }
n=${md#/dev/md}; c=crypt$n
LVM=/usr/sbin/lvm

echo "== pre-checks"
[ -b "$md" ] || die "$md does not exist"
case $n in 8|9) die "$md is a TOS system/swap array";; esac
u=$(mdadm --detail --export "$md" | sed -n 's/^MD_UUID=//p'); [ -n "$u" ] || die "no MD_UUID for $md"
pool_uuids | grep -qx "$u" && die "$u is already in $POOLS_CONF"
[ "$(cat /sys/block/md$n/md/degraded)" = 0 ] || die "array is degraded"
[ "$(cat /sys/block/md$n/md/sync_action)" = idle ] || die "array is syncing/rebuilding - wait until it is idle"
[ -e /dev/mapper/$c ] && die "/dev/mapper/$c already exists"
[ "$(md_conf_name "$u")" = "$md" ] || die "mdadm config does not list $u as $md"
sz=$(blockdev --getsz "$md"); [ $((sz % 8)) = 0 ] || die "array size is not 4K aligned"
/opt/lvmshim/install-shims.sh
vg=$($LVM pvs --noheadings -o vg_name "$md" 2>/dev/null | tr -d ' ')
[ -n "$vg" ] || die "$md is not an LVM PV with a VG - create the pool in the TOS UI first"
[ "$($LVM vgs --noheadings -o pv_count "$vg" | tr -d ' ')" = 1 ] || die "$vg has more than one PV"
[ "$($LVM vgs --noheadings -o lv_count "$vg" | tr -d ' ')" = 0 ] || die "$vg still has volumes - delete them in the UI first"
tag=$($LVM vgs --noheadings -o vg_tags "$vg" | tr -d ' ')
vgid=$($LVM vgs --noheadings -o vg_uuid "$vg" | tr -d ' ')
pvid=$($LVM pvs --noheadings -o pv_uuid "$md" | tr -d ' ')
pe_start=$($LVM pvs --noheadings --units s --nosuffix -o pe_start "$md" | tr -d ' ')
# LUKS uses 4 KiB sectors: the data start must be 4K aligned. TOS may pick odd offsets
# (e.g. 65535 from a bogus optimal-io hint), so round up to a 1 MiB boundary.
pe_start=$(( (pe_start + 2047) / 2048 * 2048 ))
ext=$($LVM vgs --noheadings --units s --nosuffix -o vg_extent_size "$vg" | tr -d ' ')
[ -n "$tag" ] && grep -q "^\[$tag\]" /etc/volume/storage.conf || die "VG tag '$tag' is not a TOS pool in storage.conf"
grep -qs "$u" /etc/volume/storage/$tag.json || die "/etc/volume/storage/$tag.json does not reference $u"
mkdir -p "$STATE_DIR"; B="$STATE_DIR/${u//:/-}"
$LVM vgcfgbackup -f "$B.vg.orig" "$vg" >/dev/null || die "vgcfgbackup failed"
cp /etc/volume/storage/$tag.json "$B.pool.json"

cat <<INFO

  array      $md   (md UUID $u)
  VG         $vg   (uuid $vgid, TOS tag $tag)
  PV uuid    $pvid
  pe_start   $pe_start sectors, extent $ext sectors
  mapping    /dev/mapper/$c

  ALL DATA ON $md WILL BE DESTROYED.
INFO
read -r -p "Type YES to encrypt $md: " a; [ "$a" = YES ] || die "aborted, nothing changed"

echo "== encrypting"
systemctl stop StorageManager
$LVM vgchange -an "$vg" >/dev/null || die "vgchange -an failed (StorageManager is stopped; start it again)"
wipefs -a "$md" >/dev/null
cryptsetup luksFormat --type luks2 --sector-size 4096 "$md" || die "luksFormat failed - array now has no PV; re-run convert or delete the pool in the UI"
cryptsetup open "$md" "$c" || die "cryptsetup open failed"
cryptsetup luksHeaderBackup "$md" --header-backup-file "$(header_file "$u")" || die "header backup failed"

echo "== restoring $vg on /dev/mapper/$c"
SZ=$(blockdev --getsz /dev/mapper/$c); PE=$(( (SZ - pe_start) / ext ))
[ "$PE" -gt 0 ] || die "computed pe_count $PE"
sed -E "s/(pe_start = )[0-9]+/\1$pe_start/; s/(dev_size = )[0-9]+/\1$SZ/; s/(pe_count = )[0-9]+/\1$PE/" "$B.vg.orig" > "$B.vg.luks"
$LVM pvcreate -y --uuid "$pvid" --restorefile "$B.vg.luks" /dev/mapper/$c >/dev/null || die "pvcreate failed"
$LVM vgcfgrestore -f "$B.vg.luks" "$vg" >/dev/null || die "vgcfgrestore failed"
$LVM vgchange -ay "$vg" >/dev/null
echo "$u" >> "$POOLS_CONF"
vgcfgbackup >/dev/null 2>&1        # via shim: hint -> $md

echo "== post-checks"
[ "$($LVM vgs --noheadings -o vg_uuid "$vg" | tr -d ' ')" = "$vgid" ] || die "VG uuid changed"
[ "$(pvs --noheadings -o vg_name "$md" | tr -d ' ')" = "$vg" ] || die "pvs $md does not show $vg"
[ "$($LVM pvs --noheadings --units s --nosuffix -o pe_start /dev/mapper/$c | tr -d ' ')" = "$pe_start" ] || die "PV data start is not $pe_start"
# prove the kernel accepts LVs on it: create and remove a 4 MiB test LV
$LVM lvcreate -y -l 1 -n luks_probe "$vg" >/dev/null 2>&1 && $LVM lvremove -y "$vg/luks_probe" >/dev/null 2>&1 \
  || die "test volume could not be created on $vg - do not create volumes in the UI"
vgcfgbackup >/dev/null 2>&1
[ "$(blkid -o value -s TYPE "$md")" = LVM2_member ] || die "blkid shim not effective"
grep -q "device = \"$md\"" /etc/lvm/backup/$vg || die "LVM backup hint not $md"
systemctl start StorageManager
echo
echo "DONE: $md is now LUKS-encrypted (pe_count $PE). Header backup: $(header_file "$u")"
echo "Copy the header backup OFF the NAS now. Then run /opt/lvmshim/check.sh"
EOF_CONV

# -----------------------------------------------------------------------------
chmod 755 $D/*.sh $D/*-shim $D/log $D/unlock-web.py
[ -f $D/settings.conf ] || cp $D/settings.conf.default $D/settings.conf

# self-signed certificate for the browser unlock page (kept across re-installs)
if [ ! -s $D/tls/cert.pem ]; then
  mkdir -p $D/tls && chmod 700 $D/tls
  if command -v openssl >/dev/null; then
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=$(hostname)" \
      -keyout $D/tls/key.pem -out $D/tls/cert.pem >/dev/null 2>&1 && chmod 600 $D/tls/key.pem
  else
    echo "WARNING: openssl not found - browser unlock page disabled (SSH unlock still works)"
  fi
fi
touch $D/pools.conf
grep -q '^#' $D/pools.conf || sed -i '1i # md UUIDs (mdadm format) of LUKS-encrypted pools, one per line' $D/pools.conf

cat > /etc/systemd/system/luks-pools.service <<'EOF_UNIT'
[Unit]
Description=Wait for LUKS unlock of encrypted md pools before TOS storage
After=ssh.service network.target
Before=tnas-mntfc.service tnas-mntdata.service StorageManager.service

[Service]
Type=oneshot
RemainAfterExit=yes
TimeoutStartSec=infinity
ExecStart=/opt/lvmshim/wait-unlock.sh

[Install]
WantedBy=tnas-system.target
EOF_UNIT

# keep a copy of this installer next to the data (survives firmware updates of /opt)
cp -f "$0" /root/luks-pools/luks-kit-install.sh 2>/dev/null || true

systemctl daemon-reload
$D/install-shims.sh
[ -s $D/tls/cert.pem ] && echo "Unlock page certificate $(openssl x509 -noout -fingerprint -sha256 -in $D/tls/cert.pem)"
echo "$KIT_VERSION" > $D/VERSION
echo "Kit version $KIT_VERSION installed to $D. Unit: luks-pools.service ($(systemctl is-enabled luks-pools.service 2>/dev/null || echo disabled))"
