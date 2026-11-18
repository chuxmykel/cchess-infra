# pg_dump of the same major version as the database, and rclone for copying
# the dumps off the box.
FROM postgres:18-alpine
RUN apk add --no-cache rclone tzdata
COPY backup.sh restore.sh restore-drill.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/backup.sh /usr/local/bin/restore.sh /usr/local/bin/restore-drill.sh
WORKDIR /backups
