#!/bin/bash

# check-image-processing.sh – verify TYPO3 image processing and WebP conversion health
#
# WHY: A settings.php brought along by a site migration can reference a graphics
# processor (e.g. GraphicsMagick) that is not installed on this server. TYPO3
# then fails every NEW image processing silently — existing _processed_ files
# keep working, so the breakage stays invisible until an editor uploads a new
# image. plan2net/webp additionally leaves 0-byte .webp files behind, which
# nginx serves as broken images to WebP-capable browsers.
#
# Checks performed:
#   1. GFX processor from settings.php exists as a binary on this server
#   2. The processor can actually convert an image to WebP (real conversion)
#   3. PHP GD has WebP support (fallback path used by some converters)
#   4. No 0-byte .webp files under fileadmin (leftovers of failed conversions)
#
# Usage:
#   bin/check-image-processing.sh                          # default: /var/www/typo3
#   bin/check-image-processing.sh --typo3-dir=/var/www/foo
#
# Exit code 0 = all healthy, 1 = at least one check failed.

set -eo pipefail

# Load shared utilities (colors, warn, die) — works both standalone and when called from install.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/utils.sh
source "${SCRIPT_DIR}/../lib/utils.sh"

# ── Parse arguments ───────────────────────────────────────────────────────────

typo3Directory="/var/www/typo3"
for arg in "$@"; do
  case $arg in
    --typo3-dir=*) typo3Directory="${arg#*=}" ;;
    *) echo "Unknown option: $arg"; exit 1 ;;
  esac
done

settingsFile="${typo3Directory}/config/system/settings.php"
fileadminDirectory="${typo3Directory}/public/fileadmin"

if [[ $EUID -ne 0 ]]; then
  die "This script must be run as root (reads ${settingsFile})"
fi

[ -f "${settingsFile}" ] || die "settings.php not found: ${settingsFile}"

failedChecks=0

echo "==============================================================="
echo "TYPO3 Image Processing Health Check"
echo "==============================================================="
echo ""

# ── 1. Processor configured in settings.php exists on this server ────────────

processor=$(php -r "\$s = require '${settingsFile}'; echo \$s['GFX']['processor'] ?? 'ImageMagick';")
processorPath=$(php -r "\$s = require '${settingsFile}'; echo \$s['GFX']['processor_path'] ?? '/usr/bin/';")
processorEnabled=$(php -r "\$s = require '${settingsFile}'; echo (\$s['GFX']['processor_enabled'] ?? true) ? 'true' : 'false';")

echo "Configured: processor=${processor}, processor_path=${processorPath}, enabled=${processorEnabled}"

case "${processor}" in
  GraphicsMagick) processorBinary="${processorPath}gm" ;;
  *)              processorBinary="${processorPath}convert" ;;
esac

if [ -x "${processorBinary}" ]; then
  echo "OK   Processor binary exists: ${processorBinary}"
else
  warn "Processor binary NOT FOUND: ${processorBinary}"
  echo "     TYPO3 fails every new image processing with this configuration."
  echo "     Fix in ${settingsFile}:"
  if [ -x "${processorPath}convert" ]; then
    echo "       'GFX' => 'processor' => 'ImageMagick'   (convert is installed)"
  elif [ -x "${processorPath}gm" ]; then
    echo "       'GFX' => 'processor' => 'GraphicsMagick'   (gm is installed)"
  else
    echo "       Install ImageMagick first: apt install imagemagick"
  fi
  echo "     Then clear the TYPO3 caches: vendor/bin/typo3 cache:flush"
  failedChecks=$((failedChecks + 1))
fi

# ── 2. Real conversion test: JPEG → WebP with the configured processor ───────

if [ -x "${processorBinary}" ]; then
  testDirectory=$(mktemp -d)
  trap 'rm -rf "${testDirectory}"' EXIT

  if [ "${processor}" = "GraphicsMagick" ]; then
    "${processorBinary}" convert -size 16x16 xc:white "${testDirectory}/test.jpg" 2>/dev/null || true
    "${processorBinary}" convert "${testDirectory}/test.jpg" "${testDirectory}/test.webp" 2>/dev/null || true
  else
    "${processorBinary}" -size 16x16 xc:white "${testDirectory}/test.jpg" 2>/dev/null || true
    "${processorBinary}" "${testDirectory}/test.jpg" "${testDirectory}/test.webp" 2>/dev/null || true
  fi

  if [ -s "${testDirectory}/test.webp" ]; then
    echo "OK   WebP conversion works ($(stat -c%s "${testDirectory}/test.webp") bytes test file)"
  else
    warn "WebP conversion FAILED or produced an empty file"
    echo "     plan2net/webp will leave 0-byte .webp files that nginx serves as broken images."
    failedChecks=$((failedChecks + 1))
  fi
fi

# ── 3. PHP GD WebP support ────────────────────────────────────────────────────

if php -r "exit(function_exists('imagewebp') ? 0 : 1);"; then
  echo "OK   PHP GD has WebP support (imagewebp)"
else
  warn "PHP GD lacks WebP support — converters using GD will fail"
  failedChecks=$((failedChecks + 1))
fi

# ── 4. 0-byte .webp leftovers under fileadmin ─────────────────────────────────

if [ -d "${fileadminDirectory}" ]; then
  emptyWebpCount=$(find "${fileadminDirectory}" -name "*.webp" -size 0 2>/dev/null | wc -l | tr -d ' ')
  if [ "${emptyWebpCount}" -eq 0 ]; then
    echo "OK   No 0-byte .webp files under fileadmin"
  else
    warn "${emptyWebpCount} empty .webp file(s) under fileadmin — leftovers of failed conversions"
    echo "     These are served as broken images to WebP-capable browsers. Clean up with:"
    echo "       find ${fileadminDirectory} -name '*.webp' -size 0 -delete"
    echo "     nginx then falls back to the original image (try_files)."
    failedChecks=$((failedChecks + 1))
  fi
else
  echo "INFO fileadmin not found (${fileadminDirectory}) — skipping 0-byte check"
fi

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
if [ "${failedChecks}" -eq 0 ]; then
  echo "All image processing checks passed."
else
  warn "${failedChecks} check(s) failed — see above"
  exit 1
fi
