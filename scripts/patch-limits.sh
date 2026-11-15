#!/usr/bin/env bash
# ==============================================================================
# scripts/patch-limits.sh
# ==============================================================================
# Patches ONLYOFFICE DocumentServer source repositories (server, core, web-apps)
# prior to compilation by build_tools:
#   1. Raises concurrent connection limit from 20 to 9999 (and raises user limits).
#   2. Unlocks Mobile Web Editing across all mobile editor controllers
#      (both modern v9/v10 React patch.jsx and legacy ExtJS Main.js).
#   3. Performs strict pre- and post-patch grep validations so the build aborts
#      immediately if upstream file structures or variable names change.
#   4. Cleans unneeded .git packfiles from large asset sub-repositories to save
#      several gigabytes of runner disk space during compilation.
# ==============================================================================

set -euo pipefail

WORKSPACE_ROOT="${1:-$(pwd)}"
if [[ -d "${WORKSPACE_ROOT}/build_tools/server" ]]; then
  REPO_BASE="${WORKSPACE_ROOT}/build_tools"
elif [[ -d "${WORKSPACE_ROOT}/../server" ]]; then
  REPO_BASE="$(cd "${WORKSPACE_ROOT}/.." && pwd)"
elif [[ -d "${WORKSPACE_ROOT}/server" ]]; then
  REPO_BASE="${WORKSPACE_ROOT}"
else
  echo "[ERROR] Could not locate cloned sub-repositories ('server', 'core', 'web-apps')." >&2
  echo "        Checked relative to: ${WORKSPACE_ROOT}" >&2
  exit 1
fi

SERVER_DIR="${REPO_BASE}/server"
CORE_DIR="${REPO_BASE}/core"
WEBAPPS_DIR="${REPO_BASE}/web-apps"

echo "=================================================================="
echo "[INFO] Starting OnlyOffice Source Patching..."
echo "       SERVER_DIR  : ${SERVER_DIR}"
echo "       CORE_DIR    : ${CORE_DIR}"
echo "       WEBAPPS_DIR : ${WEBAPPS_DIR}"
echo "=================================================================="

# ------------------------------------------------------------------------------
# 1. Verify existence of required sub-repositories
# ------------------------------------------------------------------------------
for dir in "${SERVER_DIR}" "${CORE_DIR}" "${WEBAPPS_DIR}"; do
  if [[ ! -d "${dir}" ]]; then
    echo "[FATAL] Required repository directory not found: ${dir}" >&2
    exit 1
  fi
done

# ------------------------------------------------------------------------------
# 2. Patch Connection Limits in server/Common/sources/constants.js
# ------------------------------------------------------------------------------
CONSTANTS_FILE="${SERVER_DIR}/Common/sources/constants.js"

if [[ ! -f "${CONSTANTS_FILE}" ]]; then
  echo "[FATAL] Target file not found: ${CONSTANTS_FILE}" >&2
  echo "        OnlyOffice directory structure may have changed in this release." >&2
  exit 1
fi

echo "[INFO] Inspecting ${CONSTANTS_FILE} for LICENSE_CONNECTIONS..."
if grep -Eq "exports\.LICENSE_CONNECTIONS[[:space:]]*=" "${CONSTANTS_FILE}"; then
  python3 - "${CONSTANTS_FILE}" << 'PYEOF'
import re, sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    content = f.read()

content = re.sub(r'(exports\.LICENSE_CONNECTIONS\s*=\s*)\d+', r'\g<1>9999', content)
content = re.sub(r'(exports\.LICENSE_USERS\s*=\s*)\d+', r'\g<1>9999', content)

with open(path, "w", encoding="utf-8") as f:
    f.write(content)
PYEOF

  if ! grep -Eq "exports\.LICENSE_CONNECTIONS[[:space:]]*=[[:space:]]*9999" "${CONSTANTS_FILE}"; then
    echo "[FATAL] Post-patch validation failed: 'exports.LICENSE_CONNECTIONS = 9999' not found in ${CONSTANTS_FILE}!" >&2
    exit 1
  fi
  echo "[SUCCESS] Patched LICENSE_CONNECTIONS = 9999 and LICENSE_USERS = 9999 in ${CONSTANTS_FILE}"
else
  echo "[FATAL] Expected 'exports.LICENSE_CONNECTIONS' not found in ${CONSTANTS_FILE}!" >&2
  exit 1
fi

# ------------------------------------------------------------------------------
# 3. Check & Patch License / Connection Evaluators in server & core (if present)
# ------------------------------------------------------------------------------
LICENSE_FILE="${SERVER_DIR}/Common/sources/license.js"
if [[ -f "${LICENSE_FILE}" ]]; then
  echo "[INFO] Checking ${LICENSE_FILE} for hardcoded fallback limits or package type restrictions..."
  python3 - "${LICENSE_FILE}" << 'PYEOF'
import re, sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    content = f.read()

content = re.sub(r'(connections\s*:\s*)20\b', r'\g<1>9999', content)
content = re.sub(r'(connectionsView\s*:\s*)20\b', r'\g<1>9999', content)
content = re.sub(r'(light\s*:\s*)true\b', r'\g<1>false', content)

with open(path, "w", encoding="utf-8") as f:
    f.write(content)
PYEOF
fi

# Check core repository for any C++ connection/license macro constants if defined
while IFS= read -r cfile; do
  [[ -z "${cfile}" ]] && continue
  echo "[INFO] Patching LICENSE_CONNECTIONS reference in core file: ${cfile}"
  python3 - "${cfile}" << 'PYEOF'
import re, sys
path = sys.argv[1]
with open(path, "r", encoding="utf-8", errors="ignore") as f:
    content = f.read()
content = re.sub(r'(LICENSE_CONNECTIONS\s*=?\s*)20\b', r'\g<1>9999', content)
with open(path, "w", encoding="utf-8") as f:
    f.write(content)
PYEOF
done < <(grep -RIl "LICENSE_CONNECTIONS" "${CORE_DIR}" 2>/dev/null || true)

# ------------------------------------------------------------------------------
# 4. Patch Mobile Editing Restrictions in web-apps
# ------------------------------------------------------------------------------
echo "[INFO] Locating Mobile Editor patch definitions in ${WEBAPPS_DIR}/apps..."

# Find only files that actually DEFINE isSupportEditFeature (e.g., mobile/src/lib/patch.jsx
# in OnlyOffice v9/v10, or mobile/app/controller/Main.js in legacy v7/v8),
# ignoring consumer files like appOptions.js where isSupportEditFeature is just a parameter.
PATCHED_MOBILE_COUNT=0

while IFS= read -r mfile; do
  [[ -z "${mfile}" ]] && continue
  echo "[INFO] Patching mobile editing flag in: ${mfile}"

  # Use Python for reliable single-line and multi-line replacement of:
  #   1. EditorUIController.isSupportEditFeature = () => { return false }
  #   2. EditorUIController.isSupportEditFeature = () => false;
  #   3. isSupportEditFeature: function () { return false; }
  #   4. Minified variants: return!1 or =>!1
  python3 - "${mfile}" << 'PYEOF'
import re, sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    content = f.read()

orig = content

# Replace arrow/normal function body returning false / !1 (multi-line or single-line)
content = re.sub(
    r'(isSupportEditFeature\s*[:=]\s*(?:function\s*)?\([^)]*\)\s*(?:=>)?\s*\{\s*return\s+)(?:false|!1)(\s*;?\s*\})',
    r'\g<1>true\g<2>',
    content,
    flags=re.MULTILINE
)

# Replace direct arrow function expression: isSupportEditFeature = () => false
content = re.sub(
    r'(isSupportEditFeature\s*[:=]\s*\([^)]*\)\s*=>\s*)(?:false|!1)\b',
    r'\g<1>true',
    content,
    flags=re.MULTILINE
)

if content == orig and not re.search(r'isSupportEditFeature\s*[:=][\s\S]{0,60}\btrue\b', content):
    print(f"[FATAL] Pattern replacement did not match in {path}", file=sys.stderr)
    sys.exit(1)

with open(path, "w", encoding="utf-8") as f:
    f.write(content)
PYEOF

  # Validate with grep/python that false is gone and true is present on isSupportEditFeature
  if grep -Eq "isSupportEditFeature[[:space:]]*[:=].*(false|!1)" "${mfile}"; then
    echo "[FATAL] Post-patch check failed: 'isSupportEditFeature' still returns false in ${mfile}!" >&2
    exit 1
  fi

  if grep -A 3 -E "isSupportEditFeature[[:space:]]*[:=]" "${mfile}" | grep -Eq "true"; then
    PATCHED_MOBILE_COUNT=$((PATCHED_MOBILE_COUNT + 1))
    echo "[SUCCESS] Verified mobile edit feature enabled in: ${mfile}"
  else
    echo "[FATAL] Validation failed for 'isSupportEditFeature' in ${mfile} after replacement!" >&2
    exit 1
  fi
done < <(grep -RIlE "isSupportEditFeature[[:space:]]*[:=]" "${WEBAPPS_DIR}/apps" 2>/dev/null || true)

if [[ "${PATCHED_MOBILE_COUNT}" -lt 3 ]]; then
  echo "[FATAL] Expected at least 3 mobile editor apps (document, spreadsheet, presentation) to be patched, but only patched ${PATCHED_MOBILE_COUNT}." >&2
  exit 1
fi

# ------------------------------------------------------------------------------
# 5. Reclaim Disk Space by Removing Cloned .git Packfiles from Sub-Repositories
# ------------------------------------------------------------------------------
echo "[INFO] Cleaning .git/objects/pack from cloned sub-repositories to free disk space..."
for subrepo in core dictionaries core-fonts onlyoffice.github.io document-templates sdkjs web-apps server; do
  if [[ -d "${REPO_BASE}/${subrepo}/.git/objects/pack" ]]; then
    rm -rf "${REPO_BASE}/${subrepo}/.git/objects/pack"/*
    echo "       Cleaned packfiles in ${REPO_BASE}/${subrepo}/.git/objects/pack"
  fi
done
df -h

echo "=================================================================="
echo "[SUCCESS] All OnlyOffice patches applied and verified (${PATCHED_MOBILE_COUNT} mobile editors unlocked, LICENSE_CONNECTIONS=9999)."
echo "=================================================================="
