# Custom OnlyOffice DocumentServer Builder (`linux/amd64`)

Automatisierte GitHub-Actions-Pipeline zum Kompilieren und Veröffentlichen eines angepassten **OnlyOffice DocumentServer** Docker-Images (`linux/amd64` / `x86_64`) auf Basis der offiziellen `ONLYOFFICE/build_tools` und `ONLYOFFICE/Docker-DocumentServer` Repositories.

## Features des Custom-Builds
- **Kein 20-Verbindungen-Limit:** Setzt `LICENSE_CONNECTIONS = 9999` direkt im Quellcode (`server/Common/sources/constants.js` & `license.js`), kompatibel sowohl mit v8/v9 als auch v10.x.
- **Aktiviertes Mobile-Editing:** Schaltet die Editierfunktion in mobilen Browsern und WebViews (`isSupportEditFeature -> true`) für Document-, Spreadsheet- und Presentation-Editoren frei.
- **Fail-Fast Patch-Validierung:** `scripts/patch-limits.sh` prüft vor und nach dem Patchen per `grep`, ob alle Zielstrukturen exakt gegriffen haben. Bei unerwarteten Upstream-Änderungen bricht der Build sofort kontrolliert ab.
- **GitHub-Runner Disk-Optimierung:** Bereinigt vorab unnötige Toolchains (`.NET`, `Android SDK`, `Haskell`, `CodeQL`, `Boost`) und richtet ein 8 GB Swapfile für den speicherintensiven C++/V8-Build ein.

---

## Welche Versionsnummer (`onlyoffice_version`) wird verwendet?

Maßgeblich ist ein offizieller **DocumentServer-Release-Tag**, der sowohl in [`ONLYOFFICE/build_tools`](https://github.com/ONLYOFFICE/build_tools/tags) als auch in [`ONLYOFFICE/server`](https://github.com/ONLYOFFICE/server/tags) existiert und mit dem offiziellen `.deb`-Release übereinstimmt (aktuell: **`v10.0.0.169`**, entsprechend Paketversion `10.0.0-169`).

Die aktuellste veröffentlichte Paketversion lässt sich jederzeit mit folgendem Befehl abfragen (Bindestrich `-` durch Punkt `.` ersetzen und `v` voranstellen):
```bash
curl -sL "https://download.onlyoffice.com/repo/debian/dists/squeeze/main/binary-amd64/Packages" | grep -A 10 "^Package: onlyoffice-documentserver$" | grep "^Version:" | head -n 1
```

---

## 1. Einrichtung der GitHub Secrets

Damit die GitHub Actions Pipeline das fertige Docker-Image in deinen Docker Hub Account pushen kann, müssen im GitHub-Repository zwei **Actions Secrets** hinterlegt werden:

1. Erstelle auf [Docker Hub](https://hub.docker.com/settings/security) ein Personal Access Token (PAT) mit **Read, Write, Delete**-Berechtigungen.
2. Navigiere in deinem GitHub-Repository zu **Settings → Secrets and variables → Actions → New repository secret**.
3. Lege die folgenden beiden Secrets an:
   - `DOCKERHUB_USERNAME`: Dein Docker Hub Benutzername.
   - `DOCKERHUB_TOKEN`: Das zuvor generierte Docker Hub Access Token.

---

## 2. Build / Update über GitHub Actions anstoßen

### Manuell per Knopfdruck (`workflow_dispatch`)
1. Öffne im GitHub-Repository den Reiter **Actions**.
2. Wähle links den Workflow **Build and Push Custom OnlyOffice DocumentServer**.
3. Klicke rechts auf **Run workflow**.
4. Gib im Feld `OnlyOffice Release Git Tag` den gewünschten Release-Tag ein (Standard: `v10.0.0.169`).
5. Klicke auf **Run workflow**.

> **Hinweis zur Build-Dauer:** Da `build_tools` den gesamten C++-Kern (`core`), die V8-Engine sowie `sdkjs`, `web-apps` und `server` aus dem Quellcode kompiliert, dauert ein Durchlauf auf einem Standard-GitHub-Runner ca. **2,5 bis 4 Stunden**.

### Automatisch per Zeitplan (`schedule`)
Der Workflow ist zusätzlich so konfiguriert, dass er am **1. jedes Monats um 02:00 UTC** automatisch durchläuft.

Nach erfolgreichem Durchlauf stehen auf Docker Hub zwei Tags bereit:
- `<DOCKERHUB_USERNAME>/onlyoffice-documentserver:latest`
- `<DOCKERHUB_USERNAME>/onlyoffice-documentserver:<onlyoffice_version>`

---

## 3. Deployment auf dem Ziel-Host (`docker-compose.yml`)

Erstelle auf deinem Ziel-Server (`linux/amd64`) ein Verzeichnis (z. B. `/opt/onlyoffice`) und lege dort folgende `docker-compose.yml` an:

```yaml
services:
  onlyoffice-documentserver:
    image: <DEIN_DOCKERHUB_USERNAME>/onlyoffice-documentserver:latest
    container_name: onlyoffice-documentserver
    restart: unless-stopped
    platform: linux/amd64
    ports:
      - "8080:80"
    environment:
      - JWT_ENABLED=true
      - JWT_SECRET=BitteDurchEinSicheresGeheimnisErsetzen123!
      - JWT_HEADER=Authorization
      - JWT_IN_BODY=true
    volumes:
      - ./data:/var/www/onlyoffice/Data
      - ./logs:/var/log/onlyoffice
      - ./lib:/var/lib/onlyoffice
      - ./db:/var/lib/postgresql
    shm_size: '2gb'
```

### Container starten & aktualisieren

```bash
# Container im Hintergrund starten
docker compose up -d

# Logs prüfen (Initialisierung dauert beim ersten Start ca. 1-2 Minuten)
docker compose logs -f

# Späteres Update auf eine neu gebaute Version
docker compose pull
docker compose up -d
```
