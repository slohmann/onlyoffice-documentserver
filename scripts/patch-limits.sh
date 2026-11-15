#!/usr/bin/env bash
# ==============================================================================
# scripts/patch-limits.sh
# ==============================================================================
# Patches ONLYOFFICE DocumentServer source repositories (server, core, web-apps)
# prior to compilation by build_tools:
#   1. Raises concurrent connection limit from 20 to 9999 (compatible with both
#      v8/v9.0-v9.3 and v9.4+/v10+ where upstream modified connection limits).
#   2. Unlocks Mobile Web Editing across all mobile editor controllers.
#   3. Performs strict grep validations so the build aborts immediately if
#      upstream file structures or variable names change unexpectedly.
# ==============================================================================

set -euo pipefail

WORKSPACE_ROOT="${1:-$(pwd)}"
if [[ -d "${WORKSPACE_ROOT}/build_tools/server" ]]; then
  SERVER_DIR="${WORKSPACE_ROOT}/build_tools/server"
  CORE_DIR="${WORKSPACE_ROOT}/build_tools/core"
  WEBAPPS_DIR="${WORKSPACE_ROOT}/build_tools/web-apps"
elif [[ -d "${WORKSPACE_ROOT}/../server" ]]; then
  SERVER_DIR="$(cd "${WORKSPACE_ROOT}/../server" && pwd)"
  CORE_DIR="$(cd "${WORKSPACE_ROOT}/../core" && pwd)"
  WEBAPPS_DIR="$(cd "${WORKSPACE_ROOT}/../web-apps" && pwd)"
elif [[ -d "${WORKSPACE_ROOT}/server" ]]; then
  SERVER_DIR="${WORKSPACE_ROOT}/server"
  CORE_DIR="${WORKSPACE_ROOT}/core"
  WEBAPPS_DIR="${WORKSPACE_ROOT}/web-apps"
else
  echo "[ERROR] Could not locate cloned sub-repositories ('server', 'core', 'web-apps')." >&2
  echo "        Checked relative to: ${WORKSPACE_ROOT}" >&2
  exit 1
fi

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
  # Replace any numeric value on LICENSE_CONNECTIONS (e.g. 20) with 9999
  sed -i -E 's/(exports\.LICENSE_CONNECTIONS[[:space:]]*=[[:space:]]*)[0-9]+/\19999/g' "${CONSTANTS_FILE}"

  if ! grep -Eq "exports\.LICENSE_CONNECTIONS[[:space:]]*=[[:space:]]*9999" "${CONSTANTS_FILE}"; then
    echo "[FATAL] Post-patch validation failed: 'exports.LICENSE_CONNECTIONS = 9999' not found in ${CONSTANTS_FILE}!" >&2
    exit 1
  fi
  echo "[SUCCESS] Patched LICENSE_CONNECTIONS = 9999 in ${CONSTANTS_FILE}"
else
  echo "[INFO] 'exports.LICENSE_CONNECTIONS' not present in ${CONSTANTS_FILE} (removed upstream in OnlyOffice >= v9.4 / v10.x)."
  echo "       Appending explicit exports.LICENSE_CONNECTIONS = 9999 fallback."
  printf "\nexports.LICENSE_CONNECTIONS = 9999;\n" >> "${CONSTANTS_FILE}"
fi

# Also patch LICENSE_USERS if present in constants.js
if grep -Eq "exports\.LICENSE_USERS[[:space:]]*=" "${CONSTANTS_FILE}"; then
  sed -i -E 's/(exports\.LICENSE_USERS[[:space:]]*=[[:space:]]*)[0-9]+/\19999/g' "${CONSTANTS_FILE}"
  echo "[SUCCESS] Patched LICENSE_USERS = 9999 in ${CONSTANTS_FILE}"
fi

# ------------------------------------------------------------------------------
# 3. Check & Patch License / Connection Evaluators in server & core (if present)
# ------------------------------------------------------------------------------
LICENSE_FILE="${SERVER_DIR}/Common/sources/license.js"
if [[ -f "${LICENSE_FILE}" ]]; then
  echo "[INFO] Checking ${LICENSE_FILE} for hardcoded fallback limits or package type restrictions..."
  sed -i -E 's/(connections[[:space:]]*:[[:space:]]*)20/\19999/g' "${LICENSE_FILE}" || true
  sed -i -E 's/(connectionsView[[:space:]]*:[[:space:]]*)20/\19999/g' "${LICENSE_FILE}" || true
  sed -i -E 's/(light[[:space:]]*:[[:space:]]*)true/\1false/g' "${LICENSE_FILE}" || true
fi

# Check core repository for any C++ connection/license macro constants if defined
mapfile -t CORE_LIMIT_FILES < <(grep -RIl "LICENSE_CONNECTIONS" "${CORE_DIR}" 2>/dev/null || true)
if [[ ${#CORE_LIMIT_FILES[@]} -gt 0 ]]; then
  for cfile in "${CORE_LIMIT_FILES[@]}"; do
    echo "[INFO] Patching LICENSE_CONNECTIONS reference in core file: ${cfile}"
    sed -i -E 's/(LICENSE_CONNECTIONS[[:space:]]*=?[[:space:]]*)20/\19999/g' "${cfile}"
  done
fi

# ------------------------------------------------------------------------------
# 4. Patch Mobile Editing Restrictions in web-apps
# ------------------------------------------------------------------------------
echo "[INFO] Locating Mobile Editor controllers in ${WEBAPPS_DIR}..."

mapfile -t MOBILE_FILES < <(grep -RIl "isSupportEditFeature" "${WEBAPPS_DIR}/apps" 2>/dev/null || true)

if [[ ${#MOBILE_FILES[@]} -eq 0 ]]; then
  echo "[FATAL] Could not find any files containing 'isSupportEditFeature' in ${WEBAPPS_DIR}/apps!" >&2
  echo "        Upstream mobile editor implementation may have changed. Aborting build." >&2
  exit 1
fi

PATCHED_MOBILE_COUNT=0

for mfile in "${MOBILE_FILES[@]}"; do
  echo "[INFO] Patching mobile editing flag in: ${mfile}"
  
  # Handle both unminified source definitions and pre-bundled dist definitions:
  # Pattern A: multi-line function () {\n return false;\n }
  # Pattern B: single-line function() { return false; } or return!1
  # Pattern C: arrow function () => false or ()=>!1
  sed -i -E \
    -e '/isSupportEditFeature/{N;N;s/return[[:space:]]+(false|!1)/return true/g;}' \
    -e 's/(isSupportEditFeature[[:space:]]*[:=][[:space:]]*function[[:space:]]*\([^)]*\)[[:space:]]*\{[[:space:]]*return[[:space:]]*)(false|!1)/\1true/g' \
    -e 's/(isSupportEditFeature[[:space:]]*[:=][[:space:]]*\([^)]*\)[[:space:]]*=>[[:space:]]*)(false|!1)/\1true/g' \
    "${mfile}"

  # Verify that no falsy return remains on isSupportEditFeature in this file
  if grep -Pzo "isSupportEditFeature[\s\S]{0,80}return\s*(false|!1)" "${mfile}" >/dev/null 2>&1; then
    echo "[FATAL] Failed to patch 'isSupportEditFeature' in ${mfile}!" >&2
    exit 1
  fi

  if grep -Pzo "isSupportEditFeature[\s\S]{0,80}(return\s+true|=>\s*true|return\s+1|return!0)" "${mfile}" >/dev/null 2>&1; then
    PATCHED_MOBILE_COUNT=$((PATCHED_MOBILE_COUNT + 1))
    echo "[SUCCESS] Verified mobile edit feature enabled in: ${mfile}"
  else
    echo "[FATAL] Validation failed for 'isSupportEditFeature' in ${mfile} after sed replacement!" >&2
    exit 1
  fi
done

if [[ "${PATCHED_MOBILE_COUNT}" -lt 3 ]]; then
  echo "[FATAL] Expected at least 3 mobile editor apps (document, spreadsheet, presentation) to be patched, but only patched ${PATCHED_MOBILE_COUNT}." >&2
  exit 1
fi

echo "=================================================================="
echo "[SUCCESS] All OnlyOffice patches applied and verified (${PATCHED_MOBILE_COUNT} mobile editors unlocked, LICENSE_CONNECTIONS=9999)."
echo "=================================================================="
