# Self-Hosted Services Backup Script

This script is designed to back up **self-hosted services**, including **system files**, **databases** (SQLite, MariaDB, PostgreSQL), and associated data directories. It leverages `restic` for backups and supports **any type of restic repository**.

## Features

- **System file backups**: Includes essential system configurations like crontabs, SSH settings, etc.
- **Database backups**: Supports SQLite, MariaDB, and PostgreSQL, whether running locally or in Docker containers.
- **Supports any restic repository**: Works with S3-compatible storage, local storage, Backblaze B2, Rclone, and more.
- **Optional status push**: Integrates with monitoring tools (e.g., Uptime Kuma) to report success or failure of backups.

## Requirements

Make sure the following software is installed:

- **[restic](https://restic.net/)**: For handling the backup process.
- **[jq](https://stedolan.github.io/jq/)**: For JSON parsing (used for URL encoding in the script).
- **[yq](https://github.com/mikefarah/yq)**: For parsing and manipulating YAML files.
- **sqlite3**: Required if you’re backing up SQLite databases (usually pre-installed on most Linux distributions).

## Configuration

### 1. Set Up `.env`

The `.env` file is used to configure your `restic` repository and optional push notifications. The script supports **any restic repository**, so you can uncomment the relevant section or add your own configuration.

To get started:

```bash
cp .env.example .env
nano .env
```

Configure your repository credentials and optional `PUSH_URL`. Here’s an example for an S3-compatible storage setup:

```bash
AWS_ACCESS_KEY_ID="your-access-key-id"
AWS_SECRET_ACCESS_KEY="your-secret-access-key"
RESTIC_REPOSITORY="s3:s3.amazonaws.com/your-bucket-name"
RESTIC_PASSWORD="your-restic-repository-password"
```

### 2. Define Your Services and System Files in `config.yaml`

The `config.yaml` file defines the services, paths, and databases to be backed up, as well as any additional system files that aren’t related to a specific service.

- **System Files**: Use the `system_files` section to define any non-service related files you want to back up, such as crontabs, SSH configurations, or user scripts.
  
- **Service Paths**: The script assumes that paths are located inside a folder named after the service inside the `base_path`.

#### Example:
If your `base_path` is `/opt` and your service is `vaultwarden`, the following configuration:

```yaml
base_path: "/opt"

system_files:
  paths:
    - /etc/crontab
    - /etc/ssh/sshd_config
    - /home/user/scripts

services:
  vaultwarden:
    db_type: "sqlite"
    db_names:
      - data/db.sqlite3
    paths:
      - data/attachments
      - data/config.json
```

This will back up:
- `/etc/crontab`
- `/etc/ssh/sshd_config`
- `/home/user/scripts`
  
And for the `vaultwarden` service:
- `/opt/vaultwarden/data/db.sqlite3`
- `/opt/vaultwarden/data/attachments`
- `/opt/vaultwarden/data/config.json`

#### Important Note:
If any path in `config.yaml` starts with `/` (e.g., `/absolute/path/to/file`), this logic **will not apply** and the script will use the absolute path as specified.

### 3. Exclude Files with `excludes.txt`

The `excludes.txt` file is used to define which files and directories should be excluded from the backup. You can use variables like `$DIR` (the script’s directory) and `$BASE_PATH` (the base path defined in `config.yaml`), along with common environment variables like `$HOME`.

To set it up:

```bash
cp excludes.txt.example excludes.txt
nano excludes.txt
```

Here’s an example of what your `excludes.txt` might look like:

```bash
# Exclude SQLite temporary files
*.sqlite
*.db-shm
*.db-wal

# Exclude the active backup log
$DIR/logs/backup.log

# Example: Exclude cache directories
$BASE_PATH/vaultwarden/cache
```

You can customize the exclusions to fit your specific needs, including excluding logs, cache directories, or any temporary files you don’t need to back up.

### 4. Running the Script

Once you’ve configured the `.env`, `config.yaml`, and `excludes.txt` files, you’re ready to run the script. You can either run it manually or set it up to run automatically with a cron job.

To run the script manually:

```bash
./backup.sh
```

To automate the backup process, you can add it to your crontab:

```bash
crontab -e
```

Here’s an example of how to set it up to run every day at midnight:

```bash
0 0 * * * /path/to/backup.sh
```

Make sure to replace `/path/to/backup.sh` with the actual path to the script.

## Notes

- **Retention Policy**: The script uses `restic`'s built-in retention policies. By default, it will:
  - Keep 3 daily backups
  - Keep 2 weekly backups
  - Keep 6 monthly backups
  - Keep 1 yearly backup
  You can adjust these settings inside the script as needed.

- **Log Retention**: By default, the script keeps logs of the last 30 runs. This is adjustable inside the script if you want to keep more or fewer logs.

- **PUSH_URL (Optional)**: The script can send success or failure notifications to monitoring tools like Uptime Kuma via the `PUSH_URL` configured in your `.env` file. If you don’t set `PUSH_URL`, the script will run without sending any notifications.

- **Customizing**: Feel free to modify the `.env`, `config.yaml`, and `excludes.txt` files to suit your needs. The script is flexible and works with **any type of restic repository**.

## License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.