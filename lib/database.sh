#!/bin/bash

# Database setup and configuration

createDatabase() {
  echo "INFO Create MySQL DB"

  # Idempotency is handled by isStepComplete("database_setup") in install.sh.
  # No secondary guard needed here – avoids CWD-dependent .env.temp file.
  databaseUser='typo3'
  databasePassword=$(generatePassword)
  databaseName="${databaseUser}_1"
  databaseHost='localhost'
  encryptionKey="$(openssl rand -hex 48)"

  # Quoted identifiers prevent issues if variable values ever change
  mysql -e "CREATE DATABASE \`${databaseName}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
  mysql -e "CREATE USER '${databaseUser}'@'localhost' IDENTIFIED BY '${databasePassword}';"
  mysql -e "GRANT ALL PRIVILEGES ON \`${databaseName}\`.* TO '${databaseUser}'@'localhost';"
  mysql -e "FLUSH PRIVILEGES;"

  export databaseUser databasePassword databaseName databaseHost encryptionKey
}

cleanTargetDirectoryAndDatabase() {
  if [ -d "${composerDirectory}" ]; then
    read -rp "The directory ${composerDirectory} already exists. Are you sure you want to delete it? The database ${databaseName} will be dropped, too! [y/N] " response
    if [[ "$response" =~ ^([yY][eE][sS]|[yY])$ ]]; then
      rm -rf ${composerDirectory}
      echo "Directory ${composerDirectory} removed"

      mysql -e "DROP DATABASE IF EXISTS ${databaseName};"
      echo "Database ${databaseName} dropped"
    else
      echo "Operation cancelled"
      exit 0
    fi
  fi
}