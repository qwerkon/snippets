#!/bin/bash

set -euo pipefail

BACKUP_ROOT="[backup_dir]"
DATE=$(date +%Y-%m-%d_%H-%M-%S)

MYSQL_CONTAINER="mysql"
MYSQL_ROOT_PASSWORD="[password]"

HOME_BACKUP_DIR="${BACKUP_ROOT}/home"
MYSQL_BACKUP_DIR="${BACKUP_ROOT}/mysql"
VOLUME_BACKUP_DIR="${BACKUP_ROOT}/volumes"
META_BACKUP_DIR="${BACKUP_ROOT}/metadata"
LOG_DIR="${BACKUP_ROOT}/logs"

mkdir -p "${HOME_BACKUP_DIR}"
mkdir -p "${MYSQL_BACKUP_DIR}"
mkdir -p "${VOLUME_BACKUP_DIR}"
mkdir -p "${META_BACKUP_DIR}"
mkdir -p "${LOG_DIR}"

LOG_FILE="${LOG_DIR}/backup-${DATE}.log"

exec > >(tee -a "${LOG_FILE}")
exec 2>&1

echo "================================================="
echo "Backup started: $(date)"
echo "================================================="

#
# 1. MariaDB
#
echo
echo "[1/5] MariaDB backup"

docker exec "${MYSQL_CONTAINER}" sh -c '
mariadb-dump \
    -u root \
    -p"${MYSQL_ROOT_PASSWORD}" \
    --single-transaction \
    --routines \
    --triggers \
    --events \
    --all-databases
' | gzip > "${MYSQL_BACKUP_DIR}/mysql-${DATE}.sql.gz"

echo "MariaDB backup completed"

#
# 2. HOME
#
echo
echo "[2/5] Home backup"

tar \
    --ignore-failed-read \
    --acls \
    --xattrs \
    --numeric-owner \
    --exclude='*/vendor' \
    --exclude='*/node_modules' \
    --exclude='*/storage/logs' \
    --exclude='*/storage/framework/cache' \
    --exclude='*/storage/framework/sessions' \
    --exclude='*/storage/framework/views' \
    --exclude='*/.cache' \
    --exclude='*/.npm' \
    --exclude='*/.composer/cache' \
    --exclude='*/.local/share/Trash' \
    -czpf "${HOME_BACKUP_DIR}/home-${DATE}.tar.gz" \
    /home/kb6286

echo "Home backup completed"

#
# 3. Docker volumes
#
echo
echo "[3/5] Docker volumes backup"

docker volume ls -q | while read -r volume
do
    [ -z "$volume" ] && continue

    echo "Backing up volume: ${volume}"

    docker run --rm \
        -v "${volume}":/source:ro \
        -v "${VOLUME_BACKUP_DIR}":/backup \
        alpine \
        sh -c "
            tar czf \
            /backup/${volume}-${DATE}.tar.gz \
            -C /source .
        "
done

echo "Docker volumes backup completed"

#
# 4. Docker metadata
#
echo
echo "[4/5] Docker metadata"

docker ps -a > "${META_BACKUP_DIR}/docker-containers-${DATE}.txt"
docker image ls > "${META_BACKUP_DIR}/docker-images-${DATE}.txt"
docker volume ls > "${META_BACKUP_DIR}/docker-volumes-${DATE}.txt"
docker network ls > "${META_BACKUP_DIR}/docker-networks-${DATE}.txt"

echo "Docker metadata completed"

#
# 5. Cleanup
#
echo
echo "[5/5] Cleanup"

echo "Removing backups older than 7 days..."

find "${HOME_BACKUP_DIR}"   -type f -mtime +7 -delete
find "${MYSQL_BACKUP_DIR}"  -type f -mtime +7 -delete
find "${VOLUME_BACKUP_DIR}" -type f -mtime +7 -delete
find "${META_BACKUP_DIR}"   -type f -mtime +7 -delete

echo "Removing logs older than 30 days..."

find "${LOG_DIR}" -type f -mtime +30 -delete

echo
echo "Backup sizes:"

du -sh "${HOME_BACKUP_DIR}" 2>/dev/null || true
du -sh "${MYSQL_BACKUP_DIR}" 2>/dev/null || true
du -sh "${VOLUME_BACKUP_DIR}" 2>/dev/null || true
du -sh "${META_BACKUP_DIR}" 2>/dev/null || true

echo
echo "Recent backup files:"

find "${BACKUP_ROOT}" \
    -type f \
    -newermt "1 day ago" \
    | sort

echo
echo "================================================="
echo "Backup finished: $(date)"
echo "Log file: ${LOG_FILE}"
echo "=================================================
