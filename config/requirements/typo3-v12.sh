#!/bin/bash

# PHP requirements for TYPO3 v12 LTS
# Source: https://get.typo3.org/version/12

TYPO3_PHP_MIN="8.1"
TYPO3_PHP_MAX="8.3"
TYPO3_PHP_RECOMMENDED="8.3"

# Warn if the selected PHP version is below this value
TYPO3_PHP_WARN_BELOW="8.3"
TYPO3_PHP_WARN_MSG="PHP 8.1 and 8.2 are end-of-life. PHP 8.3 is strongly recommended for TYPO3 v12."

# Image processing: TYPO3 recommends GraphicsMagick, but this installer uses ImageMagick.
# Reason: ImageMagick supports AVIF (via libheif) and HEIC; GraphicsMagick does not.
# TYPO3 is configured explicitly via additional.php to use ImageMagick as the processor.
TYPO3_IMAGE_PROCESSOR="ImageMagick"
TYPO3_IMAGE_PROCESSOR_REASON="AVIF and HEIC support via libheif (GraphicsMagick does not support these formats)"