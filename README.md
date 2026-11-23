# Bash Sysadmin Toolkit

![CI](https://github.com/farahanane4-collab/bash-sysadmin-toolkit/actions/workflows/ci.yml/badge.svg)

Eine Sammlung von Bash-Skripten für typische Aufgaben in der IT-Administration:
**Benutzerverwaltung, Systemüberwachung, Informationssicherheit und Backups** –
mit Fokus auf Automatisierung, Sicherheit und Nachvollziehbarkeit.

Entstanden aus meinem Informatikstudium (Medieninformatik, BHT Berlin), in dem ich
Linux-Systemprogrammierung, Shell-Skripting und die Analyse von Systemaufrufen und
Speicherverbrauch praktisch geübt habe.

---

## Übersicht

| Skript | Zweck | Plattform |
|---|---|---|
| [`system-health.sh`](scripts/system-health.sh) | CPU-Last, Arbeitsspeicher, Festplatten, Top-Prozesse – mit Schwellwerten und Nagios-kompatiblen Exit-Codes | Linux, macOS |
| [`user-audit.sh`](scripts/user-audit.sh) | Audit aller Benutzerkonten: Admin-Rechte, leere/gesperrte Passwörter, letzter Login, Rechte der Home-Verzeichnisse, zusätzliche UID-0-Konten | Linux |
| [`bulk-users.sh`](scripts/bulk-users.sh) | Onboarding/Offboarding per CSV: Benutzer anlegen, sperren, löschen (Home wird vorher archiviert) | Linux |
| [`security-check.sh`](scripts/security-check.sh) | Sicherheits-Baseline: SSH-Konfiguration, Firewall, offene Updates, Dateirechte, SUID-Dateien – mit Score | Linux |
| [`backup.sh`](scripts/backup.sh) | Komprimierte Backups mit SHA-256-Prüfsumme, Rotation, Lock gegen Parallelläufe und Verifikation | Linux, macOS |
| [`ssh-login-report.sh`](scripts/ssh-login-report.sh) | Auswertung von SSH-Logins, Erkennung möglicher Brute-Force-Angriffe | Linux |

## Prinzipien

- **Sicher by default** – `bulk-users.sh` läuft standardmäßig als *Dry Run* und ändert erst mit `--apply` etwas. Systemkonten (UID < 1000) und `root` werden nie angefasst.
- **Read-only, wo möglich** – Audit- und Check-Skripte ändern nichts am System.
- **Robust** – `set -o errexit -o nounset -o pipefail`, Eingabevalidierung, saubere Fehlermeldungen und sinnvolle Exit-Codes.
- **Automatisierbar** – alle Skripte sind für `cron`/Monitoring geeignet (Quiet-Modus, CSV-Ausgabe, Exit-Codes).
- **Geprüfte Qualität** – alle Skripte bestehen [ShellCheck](https://www.shellcheck.net/); automatisierte Tests laufen per GitHub Actions auf Ubuntu und macOS.

## Installation

```bash
git clone https://github.com/farahanane4-collab/bash-sysadmin-toolkit.git
cd bash-sysadmin-toolkit
chmod +x scripts/*.sh
```

Keine Abhängigkeiten außer Standard-Tools (`bash`, `awk`, `tar`, `find`, `ps`, `df`).

### Mit Docker ausprobieren (z. B. unter Windows)

```bash
docker build -t bash-toolkit .
docker run --rm bash-toolkit              # alle Tests ausführen
docker run --rm -it bash-toolkit bash     # Shell im Container, z. B.:
#   ./scripts/system-health.sh
#   ./scripts/bulk-users.sh --apply examples/users.csv   (gefahrlos, nur im Container)
#   ./scripts/user-audit.sh
```

## Beispiele

### Systemzustand prüfen

```console
$ ./scripts/system-health.sh -w 80 -c 90
System health – web01 (linux) – 2026-11-23 21:55:12
  Uptime: 21:55:12 up 12 days,  2 users,  load average: 0.06, 0.02, 0.00

  CPU load (1 min)                3%   OK
  Memory used                    46%   OK
  Disk /                         29%   OK
  Disk /var                      93%   CRITICAL

  Top 5 processes by memory:
    PID 1213      12.2%  postgres
    ...

CRITICAL - CPU load (1 min)=3% Memory used=46% Disk /=29% Disk /var=93%
```

Exit-Codes: `0` OK · `1` WARNING · `2` CRITICAL · `3` UNKNOWN – direkt nutzbar als Check in Nagios/Icinga.

### Benutzer per CSV anlegen / sperren / löschen

```csv
username,full_name,groups,action
mmuster,Max Mustermann,developers;docker,create
jdoe,John Doe,,lock
oldintern,Old Intern,,delete
```

```bash
./scripts/bulk-users.sh examples/users.csv           # Dry Run: zeigt nur, was passieren würde
sudo ./scripts/bulk-users.sh --apply examples/users.csv
```

- Neue Konten erhalten ein zufälliges Startpasswort, das beim ersten Login geändert werden muss (`chage -d 0`). Die Passwörter landen in einer Datei, die nur `root` lesen kann.
- Gesperrte Konten werden zusätzlich abgelaufen (`chage -E 0`), damit auch SSH-Schlüssel nicht mehr funktionieren.
- Vor dem Löschen wird das Home-Verzeichnis nach `/var/backups/user-homes` archiviert.

### Benutzer-Audit

```bash
sudo ./scripts/user-audit.sh
sudo ./scripts/user-audit.sh --csv > audit.csv   # z. B. als Anhang für ein Ticket
```

### Sicherheits-Check

```console
$ sudo ./scripts/security-check.sh
SSH server
  [PASS] Root login via SSH disabled
  [WARN] SSH password authentication enabled
Firewall
  [PASS] ufw firewall active
Accounts and file permissions
  [PASS] Only 'root' has UID 0
  [PASS] /etc/shadow mode 640
...
Result: 9 PASS, 1 WARN, 0 FAIL  →  score 90%
```

### Backups

```bash
./scripts/backup.sh -n etc -k 14 -d /var/backups/toolkit /etc   # 14 Versionen behalten
./scripts/backup.sh --verify -d /var/backups/toolkit              # Prüfsummen kontrollieren
```

### SSH-Login-Report

```console
$ sudo ./scripts/ssh-login-report.sh -t 5
SSH login report – system log, since 24 hours ago
  Failed logins:     9
  Successful logins: 3

Top source IPs (failed)
      6  203.0.113.7       ← possible brute force
      2  198.51.100.23
```

## Automatisierung mit cron

Siehe [`examples/crontab.example`](examples/crontab.example): Health-Check alle 5 Minuten,
nächtliches Backup, wöchentliche Backup-Verifikation und ein wöchentlicher Audit-Bericht per E-Mail.

## Tests

```bash
bash tests/run-tests.sh
```

Die Tests laufen ohne Root-Rechte und ohne das System zu verändern (temporäres Verzeichnis):
Syntax-Check, ShellCheck, Exit-Codes, Auswertung einer Beispiel-Logdatei, Backup-Rotation,
Erkennung beschädigter Archive und Validierung fehlerhafter CSV-Zeilen.

## Projektstruktur

```
bash-sysadmin-toolkit/
├── lib/common.sh            # gemeinsame Funktionen (Logging, Root-Check, OS-Erkennung)
├── scripts/                 # die sechs Werkzeuge
├── examples/                # Beispiel-CSV und Crontab
├── tests/                   # Testskript und Test-Logdatei
└── .github/workflows/ci.yml # CI: Tests auf Ubuntu und macOS
```

## Ideen für die Weiterentwicklung

- Benachrichtigung bei Warnungen (E-Mail, Mattermost/Slack-Webhook)
- Anbindung an ein Ticketsystem (automatisches Ticket bei `CRITICAL`)
- Ansible-Rollen auf Basis dieser Skripte für viele Rechner gleichzeitig

---

**Autorin:** Farah Anane · Medieninformatik, BHT Berlin
