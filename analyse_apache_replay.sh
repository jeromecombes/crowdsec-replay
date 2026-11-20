#!/usr/bin/env bash
# Replay de logs Apache2 avec CrowdSec (Docker), rapport HTML par journee.
# Base vierge a chaque execution ; *.log, *.log-*, *.bz2, *.gz acceptes (originaux intacts).
# Usage : ./analyse_apache_replay.sh [dossier_de_logs] [range]   (defaut : ./logs)
#   range : 202610 (mois complet) | 20261001 (jour) | 20261001 20261118 (intervalle inclusif)
#   formats tirets acceptes aussi : 2026-10, 2026-10-01, 2026-10-01 2026-11-18
# Scan recursif des sous-dossiers ; la journee provient du nom de fichier ou du chemin.
set -euo pipefail

BASEDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAPI_TIMEOUT=120
REPLAY_TIMEOUT=3600
INSPECT_LIMIT=30

log() { printf '[+] %s\n' "$*"; }
err() { printf '[!] %s\n' "$*" >&2; }

command -v docker >/dev/null 2>&1 || { err "Docker n'est pas installe ou accessible."; exit 1; }
docker compose version >/dev/null 2>&1 || { err "Le plugin 'docker compose' est requis."; exit 1; }
command -v python3 >/dev/null 2>&1 || { err "python3 est requis (decompression bz2/gz et rapport HTML)."; exit 1; }

LOGARG="${1:-$BASEDIR/logs}"
if ! LOGDIR="$(cd "$LOGARG" 2>/dev/null && pwd)"; then
  err "Dossier de logs introuvable : $LOGARG"
  exit 1
fi
RANGE_A="${2:-}"
RANGE_B="${3:-}"
if [[ -n $RANGE_A && -n $RANGE_B ]]; then
  log "Filtre applique : du $RANGE_A au $RANGE_B (inclus)"
elif [[ -n $RANGE_A ]]; then
  log "Filtre applique : $RANGE_A"
fi
RANGE_LO=""
RANGE_HI=""
if [[ -n $RANGE_A ]]; then
  bcomps=$(python3 - "$RANGE_A" "$RANGE_B" <<'PYS'
import calendar, datetime, re, sys


def expand(v):
    c = v.replace("-", "")
    m = re.fullmatch(r"(20\d{2})(\d{2})", c)
    if m:
        y, mo = int(m.group(1)), int(m.group(2))
        try:
            last = datetime.date(y, mo, calendar.monthrange(y, mo)[1])
            return int(datetime.date(y, mo, 1).strftime("%Y%m%d")), int(last.strftime("%Y%m%d"))
        except ValueError:
            print("[!] Mois invalide : " + v, file=sys.stderr); sys.exit(1)
    m = re.fullmatch(r"(20\d{2})(\d{2})(\d{2})", c)
    if m:
        try:
            s = int(datetime.date(int(m.group(1)), int(m.group(2)), int(m.group(3))).strftime("%Y%m%d"))
            return s, s
        except ValueError:
            print("[!] Date invalide : " + v, file=sys.stderr); sys.exit(1)
    print("[!] Format attendu 202610 (mois) ou 20261001 (jour), recu : " + v, file=sys.stderr)
    sys.exit(1)


lo, hi = expand(sys.argv[1])
if sys.argv[2] and sys.argv[2] != sys.argv[1]:
    lo2, hi2 = expand(sys.argv[2])
    lo, hi = min(lo, lo2), max(hi, hi2)
print(lo, hi)
PYS
)
  RANGE_LO=${bcomps% *}
  RANGE_HI=${bcomps#* }
fi
cd "$BASEDIR"

# --- Configuration (regeneree a chaque execution) ------------------------------------------
cat > docker-compose.yml <<EOF
services:
  crowdsec:
    image: crowdsecurity/crowdsec:latest
    container_name: crowdsec-replay
    environment:
      - COLLECTIONS=crowdsecurity/apache2
    volumes:
      - crowdsec-config:/etc/crowdsec
      - crowdsec-data:/var/lib/crowdsec/data
      - ${BASEDIR}/logs_staging:/var/log/apache2:ro

volumes:
  crowdsec-config:
  crowdsec-data:
EOF

# --- Outil de rapport (genere par le script) ------------------------------------------------
PROJET=$(basename "$LOGDIR" | tr -c '[:alnum:]\n' '-')
if [[ -n $RANGE_A && -n $RANGE_B && $RANGE_A != $RANGE_B ]]; then
  RLEG="${RANGE_A} au ${RANGE_B}"
  RNAME="${RANGE_A}-${RANGE_B}"
elif [[ -n $RANGE_A ]]; then
  RLEG="$RANGE_A"
  RNAME="$RANGE_A"
else
  RLEG="toute la periode disponible"
  RNAME="tout"
fi
LEGEND="${LOGDIR#$HOME/} (${RLEG})"

cat > replay_report.py <<'PY'
import glob
import html
import ipaddress
import json
import os
import re
import subprocess
import sys
from datetime import datetime

REPORT = sys.argv[1]
DOCKERCMD = ["docker", "compose", "exec", "-T", "crowdsec", "cscli"]
LIMIT = int(sys.argv[2]) if len(sys.argv) > 2 else 30
PROJET = sys.argv[3] if len(sys.argv) > 3 else "logs"
LEGEND = sys.argv[4] if len(sys.argv) > 4 else ""
RNAME = sys.argv[5] if len(sys.argv) > 5 else "tout"
RLO = int(sys.argv[6]) if len(sys.argv) > 6 and sys.argv[6].isdigit() else None
RHI = int(sys.argv[7]) if len(sys.argv) > 7 and sys.argv[7].isdigit() else None


def cscli(args, out_path):
    p = subprocess.run(DOCKERCMD + args, capture_output=True, text=True)
    with open(out_path, "w", encoding="utf-8") as fh:
        fh.write(p.stdout)
        if p.returncode != 0:
            fh.write("\n[cscli] " + (p.stderr or "").strip() + "\n")


def esc(s):
    return html.escape(str(s))


def fmt_num(n):
    return "{:,}".format(int(n)).replace(",", " ")


def as_int(v, default=0):
    try:
        return int(v)
    except (TypeError, ValueError):
        return default


def day_label(day):
    if re.fullmatch(r"20\d{6}", day):
        return "%s-%s-%s" % (day[:4], day[4:6], day[6:8])
    return "Journée sans date identifiable"


def in_range(day):
    if RLO is None:
        return True
    return bool(re.fullmatch(r"20\d{6}", day)) and day != "00000000" and RLO <= int(day) <= RHI


def load_objects(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            data = json.load(fh)
    except Exception:
        return []
    if not isinstance(data, list):
        return []
    return [d for d in data if isinstance(d, dict)]


def alert_id(obj):
    for key in ("id", "ID", "alert_id"):
        if key in obj:
            try:
                return int(obj[key])
            except (TypeError, ValueError):
                pass
    return None


def event_day(obj):
    for key in ("start_at", "StartAt", "start"):
        m = re.search(r"(\d{4})-(\d{2})-(\d{2})", str(obj.get(key) or ""))
        if m:
            return m.group(1) + m.group(2) + m.group(3)
    return None


def load_ids(path):
    ids = set()
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            data = json.load(fh)
    except Exception:
        return ids
    if isinstance(data, list):
        for item in data:
            if isinstance(item, dict):
                for key in ("id", "ID", "alert_id"):
                    if key in item:
                        try:
                            ids.add(int(item[key]))
                            break
                        except (TypeError, ValueError):
                            pass
    return ids


def read_file(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return fh.read().strip() or "(aucune sortie)"
    except OSError:
        return "(fichier absent)"


def sort_key(daykey):
    if re.fullmatch(r"20\d{6}", daykey):
        return (0, int(daykey))
    return (1, 0)


alerts_files = sorted(glob.glob(os.path.join(REPORT, "alerts_20*.json"))
                      + glob.glob(os.path.join(REPORT, "alerts_0000*.json")))
days = [re.search(r"alerts_(.+)\.json$", f).group(1) for f in alerts_files]

buckets_in = {}
buckets_out = {}
prev_ids = set()
scen_events = {}
events_total = 0
dec_seen = set()
ips = {}
pays = {}
dec_types = {}
total_dec_new = 0
for day in days:
    cur = {}
    for obj in load_objects(os.path.join(REPORT, "alerts_%s.json" % day)):
        aid = alert_id(obj)
        if aid is not None:
            cur[aid] = obj
    new_ids = sorted(set(cur) - prev_ids)
    prev_ids.update(cur)
    for aid in new_ids:
        bkey = event_day(cur[aid]) or day
        tgt = buckets_in if in_range(bkey) else buckets_out
        tgt.setdefault(bkey, []).append(aid)
        name = str(cur[aid].get("scenario") or "(scénario inconnu)")
        cell = scen_events.setdefault(name, [0, 0])
        cell[0] += 1
        cell[1] += as_int(cur[aid].get("events_count"), 0)
        events_total += as_int(cur[aid].get("events_count"), 0)
        found = False
        for ddec in (cur[aid].get("decisions") or []):
            if not isinstance(ddec, dict):
                continue
            v = str(ddec.get("value") or ddec.get("Value") or "")
            if not v:
                continue
            did = None
            for dkey in ("id", "ID", "decision_id"):
                if dkey in ddec:
                    try:
                        did = int(ddec[dkey])
                        break
                    except (TypeError, ValueError):
                        pass
            if did is not None:
                if did in dec_seen:
                    continue
                dec_seen.add(did)
            found = True
            total_dec_new += 1
            dtype = str(ddec.get("type") or ddec.get("Type") or "?")
            dec_types[dtype] = dec_types.get(dtype, 0) + 1
            icell = ips.setdefault(v, {"n": 0, "days": set(), "types": set()})
            icell["n"] += 1
            icell["days"].add(bkey)
            icell["types"].add(dtype)
            cnv = ""
            for ckey in ("cn", "CN", "country", "Country"):
                if ddec.get(ckey):
                    cnv = str(ddec[ckey])
                    break
            if cnv:
                pcell = pays.setdefault(cnv, {"n": 0, "ips": set(), "days": set(), "types": set()})
                pcell["n"] += 1
                pcell["ips"].add(v)
                pcell["days"].add(bkey)
                pcell["types"].add(dtype)
        if not found:
            src = cur[aid].get("source")
            if isinstance(src, dict):
                v = str(src.get("value") or src.get("ip") or "")
                cnv = ""
                for ckey in ("cn", "CN", "country", "Country"):
                    if src.get(ckey):
                        cnv = str(src[ckey])
                        break
                if (v and v not in ("", "null", "None")) or cnv:
                    icell = ips.setdefault(v or "(IP inconnue)", {"n": 0, "days": set(), "types": set()})
                    icell["days"].add(bkey)
                    icell["types"].add("(sans décision)")
                    if cnv:
                        pcell = pays.setdefault(cnv, {"n": 0, "ips": set(), "days": set(), "types": set()})
                        pcell["ips"].add(v)
                        pcell["days"].add(bkey)
                        pcell["types"].add("(sans décision)")

dec_files = sorted(glob.glob(os.path.join(REPORT, "decisions_20*.json"))
                   + glob.glob(os.path.join(REPORT, "decisions_0000*.json")))
for f in dec_files:
    mday = re.search(r"decisions_(.+)\.json$", f).group(1)
    for d in load_objects(f):
        did = None
        for key in ("id", "ID", "decision_id"):
            if key in d:
                try:
                    did = int(d[key])
                    break
                except (TypeError, ValueError):
                    pass
        if did is None or did in dec_seen:
            continue
        dec_seen.add(did)
        total_dec_new += 1
        dtype = str(d.get("type") or d.get("Type") or "?")
        dec_types[dtype] = dec_types.get(dtype, 0) + 1
        value = str(d.get("value") or d.get("Value") or "(valeur inconnue)")
        cell = ips.setdefault(value, {"n": 0, "days": set(), "types": set()})
        cell["n"] += 1
        cell["days"].add(mday)
        cell["types"].add(dtype)
        cnv = ""
        for ckey in ("cn", "CN", "country", "Country"):
            if d.get(ckey):
                cnv = str(d[ckey])
                break
        if cnv:
            pcell = pays.setdefault(cnv, {"n": 0, "ips": set(), "days": set(), "types": set()})
            pcell["n"] += 1
            pcell["ips"].add(value)
            pcell["days"].add(mday)
            pcell["types"].add(dtype)

replay_rows = []
try:
    with open(os.path.join(REPORT, "volumes.csv"), encoding="utf-8") as fh:
        for line in fh:
            flds = line.rstrip("\n").split(";")
            if len(flds) >= 4:
                replay_rows.append(flds)
except OSError:
    pass

total_files = sum(as_int(f[1]) for f in replay_rows)
total_lines = sum(as_int(f[2]) for f in replay_rows)
days_erreur = sum(1 for f in replay_rows if f[3] and f[3].upper() != "OK")
total_alerts = sum(len(v) for v in buckets_in.values()) + sum(len(v) for v in buckets_out.values())
out_count = total_alerts - sum(len(v) for v in buckets_in.values())


def build(buckets):
    recap_rows = []
    sections = []
    for daykey in sorted(buckets, key=sort_key):
        aids = buckets[daykey]
        anchor = re.sub(r"\D", "", daykey) or "nodate"
        recap_rows.append("<tr><td>%s</td><td><a href='#d%s'>%d</a></td></tr>" %
                          (esc(day_label(daykey)), anchor, len(aids)))
        sec = ["<h2 id='d%s'><a href='#d%s'>%s</a></h2>" %
               (anchor, anchor, esc(day_label(daykey))),
               "<p><b>%d</b> alerte(s) pour des évènements de cette journée.</p>" % len(aids)]
        if not aids:
            sec.append("<p class='zero'>Aucune alerte.</p>")
        insp_dir = os.path.join(REPORT, "inspect")
        os.makedirs(insp_dir, exist_ok=True)
        for aid in aids[:LIMIT]:
            out = os.path.join(insp_dir, "%s_%s.txt" % (anchor, aid))
            cscli(["alerts", "inspect", str(aid)], out)
            sec.append("<h3>alerts inspect %s</h3>" % aid)
            sec.append("<pre>%s</pre>" % esc(read_file(out)))
        if len(aids) > LIMIT:
            sec.append("<p>+ %d autres alertes non développées (total : %d).</p>" %
                       (len(aids) - LIMIT, len(aids)))
        sections.append("\n".join(sec))
    return recap_rows, sections


networks = {}
for value, cell in ips.items():
    try:
        if "/" in value:
            net = ipaddress.ip_network(value, strict=False)
        else:
            addr = ipaddress.ip_address(value)
            net = ipaddress.ip_network("%s/%d" % (addr, 24 if addr.version == 4 else 64), strict=False)
    except ValueError:
        continue
    entry = networks.setdefault(str(net), {"ips": set(), "n": 0, "days": set(), "types": set()})
    entry["ips"].add(value)
    entry["n"] += cell["n"]
    entry["days"] |= cell["days"]
    entry["types"] |= cell["types"]


def top_table(headers, rows, extra_note):
    out = ["<table class=\"recap\"><tr>%s</tr>" %
           "".join("<th>%s</th>" % esc(h) for h in headers)]
    out.extend(rows)
    out.append("</table>")
    if extra_note:
        out.append("<p class='zero'>%s</p>" % esc(extra_note))
    return "\n".join(out)


top_ips_rows = []
top_ip_srcs = sorted(ips.items(), key=lambda kv: (-kv[1]["n"], -len(kv[1]["days"]), kv[0]))
for value, cell in top_ip_srcs[:10]:
    top_ips_rows.append("<tr><td>%s</td><td>%d</td><td>%d</td><td>%s</td></tr>" % (
        esc(value), cell["n"], len(cell["days"]), esc(", ".join(sorted(cell["types"])))))
top_ips_html = top_table(
    ["IP source", "Décisions", "Journées", "Types"],
    top_ips_rows,
    "+ %d autres IP avec décisions." % (len(ips) - 10) if len(ips) > 10 else "")

top_nets_rows = []
top_nets = sorted(networks.items(),
                  key=lambda kv: (-kv[1]["n"], -len(kv[1]["ips"]), -len(kv[1]["days"]), kv[0]))
for net, cell in top_nets[:10]:
    top_nets_rows.append("<tr><td>%s</td><td>%d</td><td>%d</td><td>%d</td><td>%s</td></tr>" % (
        esc(net), len(cell["ips"]), cell["n"], len(cell["days"]),
        esc(", ".join(sorted(cell["types"])))))
top_nets_html = top_table(
    ["Réseau (CIDR)", "IP distinctes", "Décisions", "Journées", "Types"],
    top_nets_rows,
    "+ %d autres réseaux." % (len(networks) - 10) if len(networks) > 10 else "")

top_pays_rows = []
top_pays = sorted(pays.items(), key=lambda kv: (-kv[1]["n"], -len(kv[1]["ips"]), -len(kv[1]["days"]), kv[0]))
for cnv, cell in top_pays[:10]:
    top_pays_rows.append("<tr><td>%s</td><td>%d</td><td>%d</td><td>%d</td><td>%s</td></tr>" % (
        esc(cnv), len(cell["ips"]), cell["n"], len(cell["days"]),
        esc(", ".join(sorted(cell["types"])))))
top_pays_html = top_table(
    ["Pays (code ISO)", "IP distinctes", "Décisions", "Journées", "Types"],
    top_pays_rows,
    "+ %d autres pays." % (len(pays) - 10) if len(pays) > 10 else "")

top_scen_rows = []
top_scen = sorted(scen_events.items(), key=lambda kv: (-kv[1][0], -kv[1][1], kv[0]))
for name, (na, ne) in top_scen[:10]:
    top_scen_rows.append("<tr><td>%s</td><td>%d</td><td>%s</td></tr>" %
                         (esc(name), na, fmt_num(ne)))
top_scen_html = top_table(
    ["Scénario (type d'attaque)", "Alertes", "Évènements"],
    top_scen_rows,
    "+ %d autres scénarios." % (len(scen_events) - 10) if len(scen_events) > 10 else "")

synth = ["<h2>Synthèse</h2>"]
key_rows = []
if replay_rows:
    err_note = " (%d en erreur)" % days_erreur if days_erreur else ""
    key_rows.append(("Journées rejouées", "%d%s" % (len(replay_rows), err_note)))
    key_rows.append(("Fichiers analysés / lignes lues", "%s / %s" % (
        fmt_num(total_files), fmt_num(total_lines))))
key_rows.append(("Alertes", fmt_num(total_alerts)))
if total_alerts and total_lines:
    pct = ("%.2f" % (total_alerts * 100.0 / total_lines)).replace(".", ",")
    avg = total_lines / float(total_alerts)
    if avg >= 1:
        ratio_txt = "1 alerte pour %s lignes" % fmt_num(int(round(avg)))
    else:
        ratio_txt = "%s alertes pour 1 ligne" % ("%.2f" % (1.0 / avg)).replace(".", ",")
    key_rows.append(("Ratio alertes / lignes", "%s (%s %% des lignes)" % (ratio_txt, pct)))
if events_total:
    key_rows.append(("Évènements cumulés (alertes)", fmt_num(events_total)))
if total_dec_new:
    breakdown = " · ".join("%s : %d" % (t, dec_types[t]) for t in
                           sorted(dec_types, key=lambda x: (-dec_types[x], x)))
    key_rows.append(("Décisions (%s)" % breakdown, fmt_num(total_dec_new)))
else:
    key_rows.append(("Décisions", "0"))
key_rows.append(("IP sources distinctes (dans les décisions)", fmt_num(len(ips))))
active = sorted(((len(v), day_label(k)) for k, v in list(buckets_in.items()) + list(buckets_out.items())), reverse=True)
if active and active[0][0] > 0:
    key_rows.append(("Journée la plus active", "%s (%d alerte(s))" % (active[0][1], active[0][0])))
synth.append("<table class=\"resume\"><tr><th>Indicateur</th><th>Valeur</th></tr>%s</table>" % "".join(
    "<tr><td class='k'>%s</td><td>%s</td></tr>" % (esc(k), esc(v)) for k, v in key_rows))
if top_ip_srcs:
    synth.append("<h3>Top 10 des IP sources (d'après les décisions et les alertes)</h3>")
    synth.append(top_ips_html)
    if top_nets and (len(top_nets) > 1 or len(top_nets[0][1]["ips"]) > 1):
        synth.append("<h3>Top 10 des réseaux attaquants (agrégation IP par /24, /64 pour IPv6)</h3>")
        synth.append(top_nets_html)
else:
    synth.append("<p class='zero'>Aucune décision émise : pas de top IP à afficher.</p>")
if pays:
    synth.append("<h3>Top 10 des pays attaquants (code ISO 3166-1 issu des décisions)</h3>")
    synth.append(top_pays_html)
elif total_dec_new:
    synth.append("<p class='zero'>Aucune information de pays disponible : le champ pays n'est pas présent dans les décisions.</p>")
if top_scen:
    synth.append("<h3>Top 10 des scénarios déclenchés</h3>")
    synth.append(top_scen_html)
else:
    synth.append("<p class='zero'>Aucun scénario déclenché.</p>")
if days_erreur:
    synth.append("<p class=\"bad\">Attention : %d journée(s) en statut ERREUR — voir la sortie du replay sous « Fichiers rejoués ».</p>" % days_erreur)
synthese_html = "\n".join(synth)

recap_in, secs_in = build(buckets_in)
recap_out, secs_out = build(buckets_out)

titre = "Rapport CrowdSec Replay — %s" % PROJET
gen = datetime.now().strftime("%Y-%m-%d %H:%M:%S")

head = """<!doctype html>
<html lang="fr"><head><meta charset="utf-8">
<title>%s</title>
<style>
body{font-family:sans-serif;margin:2em auto;max-width:1400px;color:#222;line-height:1.45}
h1{border-bottom:2px solid #4a7}h2{margin-top:2em;background:#f4f8f6;padding:.4em .6em;border-left:4px solid #4a7}
pre{background:#f2f2f2;color:#222;padding:.8em;overflow-x:auto;line-height:1.4}
table.resume,.recap{border-collapse:collapse}
table.resume td,.recap th,table.resume th,.recap td{border:1px solid #bbb;padding:.35em .8em;text-align:left}
.recap th,.resume th{background:#eef}.resume td.k{font-weight:bold;background:#fafafa}
h3{margin:1.2em 0 .2em;font-family:monospace}
.zero{color:#888}.meta{color:#666}.bad{color:#b30}.ok{color:#280}
</style></head><body>
<h1>%s</h1>""" % (esc(titre), esc(titre))

if out_count:
    meta = ("<p class=\"meta\">Généré le %s · %s · alertes au total : <b>%d</b> · "
            "dont <b>%d</b> hors de la plage demandée · décisions au total : <b>%d</b></p>"
            % (esc(gen), esc(LEGEND), total_alerts, out_count, total_dec_new))
else:
    meta = ("<p class=\"meta\">Généré le %s · %s · alertes au total : <b>%d</b> · "
            "décisions au total : <b>%d</b></p>"
            % (esc(gen), esc(LEGEND), total_alerts, total_dec_new))

recap_html = "<h2>Récapitulatif (par journée des évènements)</h2>\n"
recap_html += "<table class=\"recap\"><tr><th>Journée</th><th>Alertes</th></tr>\n"
recap_html += "\n".join(recap_in) + "\n</table>"
if buckets_out:
    recap_html += "\n<p class=\"bad\"><b>%d</b> alerte(s) datent d'évènements hors de la plage demandée : voir <a href='#horsplage'>la section dédiée</a>.</p>" % out_count

replay_html = "<h2>Fichiers rejoués (par journée de fichier)</h2>\n"
replay_html += "<table class=\"recap\"><tr><th>Journée du fichier</th><th>Fichiers</th><th>Lignes</th><th>Statut</th></tr>\n"
for flds in replay_rows:
    lbl = esc(day_label(flds[0])) if re.fullmatch(r"20\d{6}", flds[0]) else esc(flds[0])
    replay_html += "<tr><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>" % (
        lbl, esc(flds[1]), esc(flds[2]), esc(flds[3]))
replay_html += "\n</table>"
for flds in replay_rows:
    if len(flds) >= 4 and flds[3] and flds[3].upper() != "OK":
        lbl = esc(day_label(flds[0])) if re.fullmatch(r"20\d{6}", flds[0]) else esc(flds[0])
        replay_html += "\n<h3>Sortie du replay — %s (statut %s)</h3>\n<pre>%s</pre>" % (
            lbl, esc(flds[3]), esc(read_file(os.path.join(REPORT, "replay_%s.log" % flds[0]))))

body = "\n\n".join(secs_in)
if buckets_out:
    body += "\n\n<h2 id='horsplage'>Alertes hors de la plage demandée (d'après la date des évènements)</h2>\n"
    body += "<table class=\"recap\"><tr><th>Journée des évènements</th><th>Alertes</th></tr>\n"
    body += "\n".join(recap_out) + "\n</table>"
    body += "\n\n" + "\n\n".join(secs_out)

globales_html = """<h2>Résultats globaux (toute la session)</h2>
<h3>alerts list -a</h3><pre>%s</pre>
<h3>decisions list</h3><pre>%s</pre>
<h3>metrics (cumul de la session)</h3><pre>%s</pre>""" % (
    esc(read_file(os.path.join(REPORT, "alerts_all.txt"))),
    esc(read_file(os.path.join(REPORT, "decisions_all.txt"))),
    esc(read_file(os.path.join(REPORT, "metrics_all.txt"))))

closing = "</body></html>"

html_doc = head + "\n" + meta + "\n" + synthese_html + "\n" + globales_html + "\n" + recap_html + "\n" + replay_html + "\n" + body + "\n" + closing

out = os.path.join(REPORT, "rapport_%s_%s.html" % (PROJET, RNAME))
with open(out, "w", encoding="utf-8") as fh:
    fh.write(html_doc)
print("RAPPORT:" + out)
PY

log "Nettoyage des residus des executions precedentes (les rapports HTML sont conserves)..."
rm -rf "$BASEDIR/logs_staging"
rm -f "$BASEDIR/crowdsec_rapport"/alerts_*.json "$BASEDIR/crowdsec_rapport"/decisions_*.json \
      "$BASEDIR/crowdsec_rapport"/alerts_all.txt "$BASEDIR/crowdsec_rapport"/decisions_all.txt \
      "$BASEDIR/crowdsec_rapport"/metrics_all.txt "$BASEDIR/crowdsec_rapport"/replay_*.log
rm -rf "$BASEDIR/crowdsec_rapport"/inspect

# 1) Staging : decompresse bz2/gz (originaux intacts), copie le reste, groupe par journee
#    La date (AAAAMMJJ) est extraite du nom de fichier ; sans date -> journee "00000000".
python3 - "$LOGDIR" "$BASEDIR/logs_staging" "$RANGE_A" "$RANGE_B" <<'PY'
import bz2, calendar, datetime, gzip, os, re, shutil, sys

src_dir, stage, range_a, range_b = sys.argv[1], sys.argv[2], sys.argv[3] or "", sys.argv[4] or ""


def fail(msg):
    print("[!] Erreur de range : " + msg, file=sys.stderr)
    sys.exit(1)


def expand(v):
    c = v.replace("-", "")
    m = re.fullmatch(r"(20\d{2})(\d{2})", c)
    if m:
        y, mo = int(m.group(1)), int(m.group(2))
        try:
            first = datetime.date(y, mo, 1)
            last = datetime.date(y, mo, calendar.monthrange(y, mo)[1])
            return int(first.strftime("%Y%m%d")), int(last.strftime("%Y%m%d"))
        except ValueError:
            fail("mois invalide : " + v)
    m = re.fullmatch(r"(20\d{2})(\d{2})(\d{2})", c)
    if m:
        try:
            d = datetime.date(int(m.group(1)), int(m.group(2)), int(m.group(3)))
            s = int(d.strftime("%Y%m%d"))
            return s, s
        except ValueError:
            fail("date invalide : " + v)
    fail("format attendu 202610 (mois) ou 20261001 (jour), recu : " + v)


lo = hi = None
if range_a:
    lo, hi = expand(range_a)
    if range_b and range_b != range_a:
        lo_b, hi_b = expand(range_b)
        lo, hi = min(lo, lo_b), max(hi, hi_b)

kept = skipped = 0
stage_abs = os.path.realpath(stage)
for root, dirs, files in os.walk(src_dir):
    dirs[:] = [d for d in dirs if os.path.realpath(os.path.join(root, d)) != stage_abs]
    for fn in sorted(files):
        path = os.path.join(root, fn)
        if os.path.realpath(path) == stage_abs or os.path.realpath(path).startswith(stage_abs + os.sep):
            continue
        low = fn.lower()
        opener, stem = None, fn
        if low.endswith(".bz2"):
            opener, stem = bz2.open, fn[:-4]
        elif low.endswith(".gz"):
            opener, stem = gzip.open, fn[:-4]
        elif not re.search(r"\.log(-.*)?$", low):
            continue
        rel = os.path.relpath(path, src_dir)
        m = re.search(r"20\d{6}", fn) or re.search(r"20\d{6}", rel)
        day = m.group(0) if m else "00000000"
        if lo is not None:
            if day == "00000000" or not (lo <= int(day) <= hi):
                skipped += 1
                continue
        kept += 1
        prefix = os.path.dirname(rel).replace(os.sep, "__")
        core = stem if stem.endswith(".log") else stem + ".log"
        unique = (prefix + "__" + core) if prefix not in ("", ".") else core
        daydir = os.path.join(stage, day)
        os.makedirs(daydir, exist_ok=True)
        target, n = os.path.join(daydir, unique), 2
        while os.path.exists(target):
            target = os.path.join(daydir, "%s_%d.log" % (unique[:-4], n))
            n += 1
        if opener is None:
            shutil.copyfile(path, target)
        else:
            with opener(path, "rb") as fh_in, open(target, "wb") as fh_out:
                shutil.copyfileobj(fh_in, fh_out)

if lo is not None:
    print("[i] Fichiers retenus : %d - hors range/ignores : %d" % (kept, skipped), file=sys.stderr)
if kept == 0:
    fail("aucun fichier ne correspond a ce range dans " + src_dir)
PY

total_files=$(find "$BASEDIR/logs_staging" -name '*.log' | wc -l)
total_lines=$(find "$BASEDIR/logs_staging" -name '*.log' -exec cat {} + | wc -l)
log "$total_files fichier(s), $total_lines ligne(s) prepares dans $BASEDIR/logs_staging"

# 2) Base vierge + demarrage LAPI
log "Nettoyage de la precedente base d'analyse..."
docker compose down -v --remove-orphans >/dev/null 2>&1 || true
log "Demarrage de CrowdSec (telechargement des parsers/scenarios si besoin)..."
docker compose up -d

ready=0
for ((i = 0; i < LAPI_TIMEOUT; i++)); do
  if docker compose exec -T crowdsec cscli lapi status >/dev/null 2>&1; then
    ready=1
    break
  fi
  (( i > 0 && i % 10 == 0 )) && printf '  attente de la LAPI... %ss\n' "$i"
  sleep 1
done
if [[ $ready -ne 1 ]]; then
  err "CrowdSec n'est pas demarre en ${LAPI_TIMEOUT}s."
  docker compose ps -a || true
  docker compose logs --tail 50 crowdsec || true
  docker compose down -v >/dev/null 2>&1 || true
  exit 1
fi

REPORT="$BASEDIR/crowdsec_rapport"
mkdir -p "$REPORT"
printf '' > "$REPORT/volumes.csv"

# 3) Replay jour par jour, puis capture cumulee des alertes/decisions
days=$(ls "$BASEDIR/logs_staging" | sort)
for day in $days; do
  if [[ -n $RANGE_LO ]]; then
    if [[ $day == 00000000 ]] || (( 10#$day < 10#$RANGE_LO || 10#$day > 10#$RANGE_HI )); then
      [[ $day == 00000000 ]] && jlabel="sans date" || jlabel="${day:0:4}-${day:4:2}-${day:6:2}"
      log "Journee $jlabel hors filtre, ignoree."
      continue
    fi
  fi
  dcount=$(ls "$BASEDIR/logs_staging/$day"/*.log | wc -l)
  dlines=$(cat "$BASEDIR/logs_staging/$day"/*.log | wc -l)
  if [[ $day == 00000000 ]]; then
    label="sans date identifiable"
  else
    label="${day:0:4}-${day:4:2}-${day:6:2}"
  fi
  log "Replay du $label : $dcount fichier(s), $dlines ligne(s)"

  if docker compose exec -T crowdsec \
        timeout "$REPLAY_TIMEOUT" \
        crowdsec -type apache2 -dsn "file:///var/log/apache2/$day/*.log" -no-api > "$REPORT/replay_$day.log" 2>&1; then
    statut="ok"
  else
    rc=$?
    statut="ERREUR"
    err "Le replay du $label a echoue (code $rc), poursuite avec les journees suivantes."
    err "Détail conservé dans $REPORT/replay_$day.log, dernières lignes :"
    tail -n 15 "$REPORT/replay_$day.log" >&2 || true
  fi

  docker compose exec -T crowdsec cscli alerts list -a -o json > "$REPORT/alerts_$day.json" 2>/dev/null || true
  docker compose exec -T crowdsec cscli decisions list -a -o json > "$REPORT/decisions_$day.json" 2>/dev/null || true
  printf '%s;%d;%d;%s\n' "$day" "$dcount" "$dlines" "$statut" >> "$REPORT/volumes.csv"
done

# 4) Captures globales + rapport
docker compose exec -T crowdsec cscli alerts list -a > "$REPORT/alerts_all.txt" 2>&1 || true
docker compose exec -T crowdsec cscli decisions list > "$REPORT/decisions_all.txt" 2>&1 || true
docker compose exec -T crowdsec cscli metrics > "$REPORT/metrics_all.txt" 2>&1 || true

if out=$(python3 "$BASEDIR/replay_report.py" "$REPORT" "$INSPECT_LIMIT" "$PROJET" "$LEGEND" "$RNAME" "$RANGE_LO" "$RANGE_HI" 2>&1); then
  rapport=${out#RAPPORT:}
  log "Rapport HTML genere : $rapport"
else
  err "La generation du rapport HTML a echoue :"
  printf '%s\n' "$out" >&2
  err "Les resultats bruts restent dans $REPORT."
fi

docker compose stop >/dev/null 2>&1 || true
log "Conteneur arrete (volumes conserves pour inspection ulterieure ; supprimes au prochain lancement)."

log "Contenu detaille : $REPORT ; pour approfondir :"
echo "    docker compose start                          # relancer le conteneur"
echo "    docker compose exec crowdsec cscli alerts list -a"
echo "    docker compose exec crowdsec cscli alerts inspect <ID>"
echo "    docker compose exec crowdsec cscli metrics"
echo "    docker compose down -v    # supprimer conteneur et volumes"
