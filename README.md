# crowdsec-replay

Analyse **a posteriori** (replay) de logs Apache2 avec CrowdSec sous Docker, et génération d'un **rapport HTML** détaillé par journée : alertes, décisions, scénarios déclenchés, top IP / réseaux / pays, volumes analysés.

Idéal pour auditer une période passée (logs d'archives, coupures de '*.log-*', logs compressés) sans toucher à un CrowdSec de production : chaque exécution part d'une **base vierge**.

## Prérequis

- Docker + plugin `docker compose`
- `python3` (decompression bz2/gz + génération du rapport)

## Usage

```bash
./analyse_apache_replay.sh [dossier_de_logs] [range]        # defaut : ./logs
```

Formats de `range` (les formats tirets sont acceptés aussi) :

| Exemple | Signification |
|---|---|
| *(vide)* | toute la période disponible |
| `202610` | tout le mois d'octobre 2026 |
| `2026-10` | idem |
| `20261001` | la journée du 01/10/2026 |
| `20261001 20261118` | de 20161001 au 18/11/2026 **inclus** |
| `2026-10-01 2026-11-18` | idem |

- Formats de fichiers acceptés : `*.log`, `*.log-*` (rotations), `*.bz2`, `*.gz` — **originaux intacts** (décompression dans un dossier de staging `logs_staging/`, purgé à chaque run).
- **Scan récursif** des sous-dossiers ; la journée provient du nom de fichier (premier `AAAAMMJJ` trouvé), sinon du chemin, sinon journée « sans date » (`00000000`).
- **Fichier courant sans date** (`access.log`, `error.log` à la racine) : **inclus** au replay même si un range est demandé — les alertes sont ensuite reclassées d'après la date de leurs évènements, celles hors plage allant dans la section dédiée du rapport. Pour les exclure : `SKIP_SANS_DATE=1 ./analyse_apache_replay.sh ...`.
- Le nom de l'argument 1 donne le **projet** (préfixe du rapport) ; le paramètre optionnel range figure dans le nom du rapport : plusieurs rapports (sites/périodes) coexistent dans `crowdsec_rapport/`.

```bash
./analyse_apache_replay.sh /srv/logs/siteA 202610
# -> crowdsec_rapport/rapport_siteA_202610.html
./analyse_apache_replay.sh /srv/logs/siteB 2026-10-01 2026-11-18
# -> crowdsec_rapport/rapport_siteB_2026-10-01-2026-11-18.html
```

## Le rapport HTML

Généré dans `crowdsec_rapport/` sous le nom `rapport_<projet>_<periode>.html` :

- **Synthèse** (en tête de rapport) : chiffres clés (journées, fichiers, lignes, ratio alertes/lignes, évènements cumulés, décisions par type — `ban : x · captcha : y` —, IP distinctes, journée la plus active, journées en erreur), **top 10 des IP attaquantes** (décisions, journées, types), **top 10 des réseaux attaquants** (agrégation /24 IPv4, /64 IPv6), **top 10 des pays attaquants** (code ISO 3166-1 du champ pays des décisions) et **top 10 des scénarios déclenchés** (alertes + évènements) ;
- **Résultats globaux (toute la session)** — juste après la synthèse : `cscli alerts list -a`, `cscli decisions list`, `cscli metrics` (les métriques du moteur sont cumulatives sur la session, pas par journée) ;
- **Récapitulatif par journée des évènements** : les alertes sont associées à la date de leurs évènements (champ « Begin » / `start_at`), pas à la date du nom de fichier — un fichier mal daté ne fausse plus les sections ;
- **Fichiers rejoués** (par journée de fichier : fichiers, lignes, statut) ; pour chaque journée en erreur, la **sortie du replay** est affichée (diagnostic direct) et conservée dans `crowdsec_rapport/replay_<journee>.log` ;
- **Alertes hors plage** : si des évènements d'une alerte sortent du range demandé, elles sont listées dans une section dédiée plutôt que noyées dans les journées du range ;
- **Une section par journée** : `cscli alerts inspect <ID>` pour chaque alerte (limité à 30/journée — ajustez `INSPECT_LIMIT` en tête de script).

Les tops sont alimentés par les **décisions embarquées** dans le JSON des alertes, complétées par `cscli decisions list -a -o json` (incluant les décisions **expirées**, indispensables en replay où « until » suit la date des évènements). Une alerte sans décision contribue via sa source, avec le type « (sans décision) ».

## Fonctionnement

1. **Staging** — décompression bz2/gz + copie vers `logs_staging/`, regroupées par journée (anti-doublons, garde du range : compteurs détaillés affichés — retenus / hors range / sans date).
2. **Reset + init** — `docker compose down -v` (volumes config + base SQLite supprimés = base vierge), démarrage du conteneur, installation de la collection `crowdsecurity/apache2`.
3. **Replay** — pour chaque journée (ordre chronologique) : `crowdsec -type apache2 -dsn "file:///var/log/apache2/<journee>/*.log" -no-api` exécuté **dans le conteneur** (mode documenté « injection dans une base existante »), sortie capturée par journée.
4. **Captures** — après chaque journée : `alerts list -a -o json`, `decisions list -a -o json` + volumes (`volumes.csv`) ; à la fin : captures globales texte.
5. **Rapport** — agrégation Python (`replay_report.py`, régénéré par le script), HTML autonome écrit dans `crowdsec_rapport/`.

## Purge à chaque exécution

Au démarrage : `logs_staging/`, JSON intermédiaires (`alerts_*.json`, `decisions_*.json`), captures texte (`*_all.txt`), logs de replay et dossier `inspect/` sont supprimés. **Les rapports HTML existants sont conservés.**

## Limites connues

- `metrics` est un cumul de la session, pas par journée ;
- `REPLAY_TIMEOUT` = 3600 s/journée (runs très volumineux : augmentez la valeur en tête de script) ;
- certains `error.log` Apache passent mal les parsers Apache2 (statut ok quand même, 0 alerte) ;
- les délais d'attente LAPI se règlent via `LAPI_TIMEOUT`.

> ⚠️ vie privée : les rapports contiennent des adresses IP et le contenu des requêtes (URLs, user agents). S'ils couvrent des logs d'une application traitant des données personnelles, traitez les fichiers HTML comme des données personnelles (conservation limitée, pas de publication).
