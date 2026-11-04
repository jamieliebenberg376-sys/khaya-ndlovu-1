# Encrypted backups

Every Sunday the "Keep map awake and back it up" job saves the whole map database here as a locked `.asc` file.
The newest 12 are kept. They are useless without the private key `KHAYA-BACKUP-PRIVATE-KEY.asc` (Jamie keeps it, never put it in this repo).

To restore: give Claude the backup file and the private key file and ask it to open and restore the backup.
