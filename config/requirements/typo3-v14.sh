#!/bin/bash

# PHP requirements for TYPO3 v14 LTS
# LTS release: 2026-04-21
# Source: https://get.typo3.org/version/14

TYPO3_PHP_MIN="8.2"
TYPO3_PHP_MAX="8.5"
TYPO3_PHP_RECOMMENDED="8.4"

# Warn if the selected PHP version is below this value.
# PHP < 8.4 may cause dependency conflicts with Symfony components used by TYPO3 v14
# and misses security fixes available in PHP 8.4.
TYPO3_PHP_WARN_BELOW="8.4"
TYPO3_PHP_WARN_MSG="PHP < 8.4 may cause dependency conflicts with Symfony components used by TYPO3 v14. PHP 8.4 is strongly recommended."