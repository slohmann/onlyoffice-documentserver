# Custom ONLYOFFICE DocumentServer Builder (`linux/amd64` & `linux/arm64`)

Automated GitHub Actions pipeline to compile **ONLYOFFICE DocumentServer** from source, apply connection and mobile-editing patches, and publish slim multi-architecture Docker images (`linux/amd64` and `linux/arm64/v8`) based on the official [`ONLYOFFICE/build_tools`](https://github.com/ONLYOFFICE/build_tools) and [`ONLYOFFICE/Docker-DocumentServer`](https://github.com/ONLYOFFICE/Docker-DocumentServer) repositories.

> **Disclaimer:** This is an unofficial community build repository and is not affiliated with or endorsed by Ascensio System SIA / ONLYOFFICE. Upstream ONLYOFFICE DocumentServer source code is licensed under AGPL-3.0; verify license compliance for your intended use case before deploying.

---

## Features

- **Raised Connection Limit (`LICENSE_CONNECTIONS = 9999`):** Patches `server/Common/sources/constants.js` and `server/Common/sources/license.js` prior to compilation to raise the default 20 concurrent connections limit to `9999` (`LICENSE_USERS = 9999`).
- **Mobile Web Editing Enabled:** Unlocks editing in mobile browsers and WebViews (`isSupportEditFeature -> true`) across the Document, Spreadsheet, and Presentation editors in `web-apps`.
- **Multi-Architecture Docker Images (`linux/amd64` & `linux/arm64`):** Builds native `x86_64` and cross-compiled `aarch64` (`linux_arm64`) server binaries, packages them into Ubuntu 24.04 containers, and publishes a unified multi-arch manifest list (`:latest` and `:<onlyoffice_version>`) compatible with both x86_64 servers and ARM64 instances (e.g., Oracle Cloud Ampere A1, AWS Graviton, Raspberry Pi).
- **Slim Image Size (Single-Layer Overlay):** Strips debug symbols from compiled C++ ELF binaries/shared libraries (`x2t`, `allfontsgen`, `allthemesgen`, `*.so*`) and uses a BuildKit bind-mount overlay inside the official Dockerfile `RUN` step so `/var/www/onlyoffice/documentserver` is stored only once in the final image.
- **Fail-Fast Patch Verification:** [`scripts/patch-limits.sh`](scripts/patch-limits.sh) validates target patterns both before and after patching so upstream source changes fail immediately rather than silently producing an unpatched image.
- **Standard GitHub Runner Compatible:** Frees pre-installed runner toolchains, configures a 4 GB swapfile, uses shallow Git clones (`--depth 1`), and prunes intermediate V8/Boost/CEF/QMake build artifacts during compilation so the build fits within standard 72 GB GitHub-hosted runners.

---

## Quick Start (`docker-compose.yml`)

Create a directory on your host (for example `/opt/onlyoffice`) and add the following `docker-compose.yml` (Docker automatically selects `linux/amd64` or `linux/arm64/v8` from the multi-arch manifest; replace `sl71` with your own Docker Hub username if you forked and built your own image):

```yaml
services:
  onlyoffice-documentserver:
    image: sl71/onlyoffice-documentserver:latest
    container_name: onlyoffice-documentserver
    restart: unless-stopped
    ports:
      - "8080:80"
    environment:
      - JWT_ENABLED=true
      - JWT_SECRET=CHANGE_ME_TO_A_LONG_RANDOM_SECRET
      - JWT_HEADER=Authorization
      - JWT_IN_BODY=true
    volumes:
      - ./data:/var/www/onlyoffice/Data
      - ./logs:/var/log/onlyoffice
      - ./lib:/var/lib/onlyoffice
      - ./db:/var/lib/postgresql
    shm_size: '2gb'
```

### Start & Update

```bash
# Start container in the background (first-time DB/font initialization takes ~1-2 minutes)
docker compose up -d

# Follow startup logs
docker compose logs -f

# Update to a newly published image
docker compose pull
docker compose up -d
```

---

## Building Your Own Image via GitHub Actions

### 1. Configure Repository Secrets

Fork this repository and configure two **Actions Secrets** so GitHub Actions can push images to your Docker Hub account:

1. Create a Docker Hub Personal Access Token (PAT) at [Docker Hub Security Settings](https://hub.docker.com/settings/security) with **Read, Write, Delete** permissions.
2. Open **Settings → Secrets and variables → Actions → New repository secret** in your GitHub fork.
3. Add:
   - `DOCKERHUB_USERNAME`: Your Docker Hub username.
   - `DOCKERHUB_TOKEN`: Your Docker Hub Personal Access Token.

### 2. Choosing `onlyoffice_version`

Use an official release tag that exists across `ONLYOFFICE/build_tools`, `ONLYOFFICE/server`, `ONLYOFFICE/core`, `ONLYOFFICE/sdkjs`, and `ONLYOFFICE/web-apps` and matches the published Debian package version (default: `v10.0.0.169`).

You can check the latest published Debian package version at any time (replace `-` with `.` and prefix with `v`):

```bash
curl -sL "https://download.onlyoffice.com/repo/debian/dists/squeeze/main/binary-amd64/Packages" \
  | grep -A 10 "^Package: onlyoffice-documentserver$" \
  | grep "^Version:" \
  | head -n 1
```

### 3. Triggering a Build

#### Manual Trigger (`workflow_dispatch`)
1. Go to the **Actions** tab in your repository.
2. Select **Build and Push Custom OnlyOffice DocumentServer**.
3. Click **Run workflow**.
4. Enter `onlyoffice_version` (default: `v10.0.0.169`) and choose `platforms`:
   - `linux/amd64,linux/arm64` *(default — builds both architectures in parallel and merges them into one multi-arch manifest)*
   - `linux/amd64` *(builds `x86_64` only)*
   - `linux/arm64` *(builds `aarch64` / `arm64` only)*

> **Build Duration:** Compiling `core`, V8, `sdkjs`, `web-apps`, and `server` from source takes roughly **2 to 3.5 hours** per architecture on standard GitHub-hosted runners.

#### Scheduled Builds (`schedule`)
By default, the workflow also runs automatically on the **1st of each month at 02:00 UTC** and publishes both architectures (`linux/amd64` and `linux/arm64`).

### Published Docker Hub Tags

After a successful run, the following tags are available on Docker Hub:
- `<DOCKERHUB_USERNAME>/onlyoffice-documentserver:latest` *(multi-arch manifest list)*
- `<DOCKERHUB_USERNAME>/onlyoffice-documentserver:<onlyoffice_version>` *(multi-arch manifest list)*
- `<DOCKERHUB_USERNAME>/onlyoffice-documentserver:<onlyoffice_version>-amd64` *(if built)*
- `<DOCKERHUB_USERNAME>/onlyoffice-documentserver:<onlyoffice_version>-arm64` *(if built)*
