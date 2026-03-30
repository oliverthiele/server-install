#!/bin/bash

# PHP requirements for TYPO3 v13 LTS
# Source: https://get.typo3.org/version/13

TYPO3_PHP_MIN="8.2"
TYPO3_PHP_MAX="8.5"
TYPO3_PHP_RECOMMENDED="8.4"

# Warn if the selected PHP version is below this value.
# PHP < 8.4 causes compatibility issues with Symfony dependencies used by TYPO3 v13
# (e.g. lcobusc/clock, firebase/php-jwt) and misses security fixes in newer PHP releases.
TYPO3_PHP_WARN_BELOW="8.4"
TYPO3_PHP_WARN_MSG="PHP < 8.4 may cause dependency conflicts with Symfony components used by TYPO3 v13 (e.g. firebase/php-jwt). PHP 8.4 is strongly recommended."

# Image processing: TYPO3 recommends GraphicsMagick, but this installer uses ImageMagick.
# Reason: ImageMagick supports AVIF (via libheif) and HEIC; GraphicsMagick does not.
# TYPO3 is configured explicitly via additional.php to use ImageMagick as the processor.
TYPO3_IMAGE_PROCESSOR="ImageMagick"
TYPO3_IMAGE_PROCESSOR_REASON="AVIF and HEIC support via libheif (GraphicsMagick does not support these formats)"