#!/bin/bash

# Set the working directory to the script's location
# This ensures relative paths work as expected
# Export for use in excludes.txt
export DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Debug mode for detailed logging, disabled by default
DEBUG=false  # Set true to enable debugging, false to disable

# Log variables during execution if DEBUG mode is enabled
# This could help trace issues during execution
debug_log() {
    if [ "$DEBUG" = true ]; then
        echo "$1 = $2"
    fi
}

# Create a logs directory if it doesn't already exist
# TODO: Add log tuning controls (e.g., log level or retention policy)
mkdir -p "$DIR/logs"

# The log file will always be named backup.log
LOG_FILE="$DIR/logs/backup.log"

# Keep at most 30 log files, to prevent excessive file buildup
MAX_LOGS=30

# If the log file exists, rotate it by renaming with a timestamp
if [ -f "$LOG_FILE" ]; then
    TIMESTAMP=$(date '+%Y-%m-%d_%H-%M-%S')
    mv "$LOG_FILE" "$DIR/logs/backup_$TIMESTAMP.log"
fi

# Use the find command to list and remove older logs
# Only keep the most recent $MAX_LOGS log files
find "$DIR/logs" -name 'backup_*.log' -type f | sort -r | tail -n +$((MAX_LOGS + 1)) | xargs -r rm -f

# Redirect stdout and stderr to the log file
# TODO: Add options for tuning control in future (e.g., output verbosity)
exec > >(tee -a "$LOG_FILE") 2>&1

# Initial log entry to mark when the backup started
echo "Backup started at: $(date '+%Y-%m-%d %H:%M:%S')"

# Source environment variables from the .env file
# TODO: Add checks for mandatory environment variables (e.g., DB credentials)
source "$DIR/.env"

# Path to the YAML file containing service configurations
config_yaml="$DIR/config.yaml"
debug_log "config_yaml" "$config_yaml"

# Function to encode strings for URLs (useful for status updates)
# This ensures special characters in the status messages are URL-safe
urlencode() {
    printf '%s' "$1" | jq -sRr @uri
}

# Function to send a status update via the PUSH_URL
# Now it also checks and logs if the push was successful
send_status() {
    # Send the status update and capture the response code
    response=$(curl -fsS -m 30 --retry 5 "${PUSH_URL}?status=$1&msg=$(urlencode "$2")" -w "%{http_code}" -o /dev/null)

    if [ "$response" -eq 200 ]; then
        echo "Status update for $1 was successful."
    else
        echo "Status update for $1 failed with response code $response."
    fi

    debug_log "send_status_response_code" "$response"
}

# Compare and move new backup if changes are detected
compare_and_move_backup() {
    local temp_backup_path=$1
    local backup_path=$2
    local service_name=$3

    echo "Backup created at $temp_backup_path. Comparing hashes..."

    # Log variables for debugging purposes
    debug_log "temp_backup_path" "$temp_backup_path"
    debug_log "backup_path" "$backup_path"
    debug_log "service_name" "$service_name"

    # Check if there is an existing backup file to compare
    if [ -f "$backup_path" ]; then
        # Compare the current and previous backup by their hashes
        local old_hash=$(md5sum "$backup_path" | awk '{ print $1 }')
        local new_hash=$(md5sum "$temp_backup_path" | awk '{ print $1 }')

        # Log the computed hash values
        debug_log "old_hash" "$old_hash"
        debug_log "new_hash" "$new_hash"

        # If hashes are the same, discard the new backup
        if [ "$old_hash" == "$new_hash" ]; then
            echo "No changes detected in $service_name db."
            rm -f "$temp_backup_path"
            echo "Temporary backup $temp_backup_path has been deleted."
        else
            # If there are changes, save the new backup
            echo "Changes detected, saving new backup."
            mv "$temp_backup_path" "$backup_path"
        fi
    else
        # If no previous backup exists, save the new one
        echo "No previous backup found, saving new backup."
        mv "$temp_backup_path" "$backup_path"
    fi

    echo "$service_name db backup completed."
    echo  # Insert a blank line for readability
}

# Function to back up databases of different types (SQLite, MariaDB, PostgreSQL)
# Handles retries, backup naming, and validation of backup files
backup_db() {
    local db_type=$1         # The type of the database (sqlite, mariadb, postgres)
    local container=$2       # Container name (used for Docker)
    local db_user=$3         # Database user (for MariaDB/Postgres)
    local db_password=$4     # Database password (for MariaDB/Postgres)
    local db_name="$5"       # Database name or path (depending on type)
    local backup_dir="$6"    # Directory to store the backup
    local service_name=$7    # Service name for logging and backup file naming
    local retries=5          # Number of retry attempts in case of failure
    local wait_time=10       # Wait time between retry attempts
    local dump_cmd           # Command to execute the backup
    local db_backup_name     # Name of the backup file

    # Log input variables for debugging purposes
    debug_log "db_type" "$db_type"
    debug_log "container" "$container"
    debug_log "db_user" "$db_user"
    debug_log "db_password" "$db_password"
    debug_log "db_name" "$db_name"
    debug_log "backup_dir" "$backup_dir"
    debug_log "service_name" "$service_name"

    # Generate the backup file name based on db_type and appropriate file extension
    local parent_dir=$(basename "$(dirname "$db_name")")
    local base_db_name="$(basename "$db_name" | sed 's/\.[^.]*$//')"

    # Based on the database type, define the backup file name and command
    case $db_type in
        sqlite)
            db_backup_name="${backup_dir}/${service_name}_${parent_dir}_${base_db_name}$(echo "$db_name" | sed 's/.*\(\.[^.]*\)$/\1/').bak"
            # SQLite backup command using the .backup method
            dump_cmd="sqlite3 \"$db_name\" \".backup '$db_backup_name.tmp'\""
            ;;
        mariadb | postgres)
            db_backup_name="${backup_dir}/${service_name}_${base_db_name}.sql"
            if [ "$db_type" == "mariadb" ]; then
                # MariaDB backup command using mysqldump
                dump_cmd="docker exec $container mysqldump -u \"$db_user\" --password=\"$db_password\" \
                    \"$db_name\" --skip-comments > \"$db_backup_name.tmp\""
            elif [ "$db_type" == "postgres" ]; then
                # PostgreSQL backup command using pg_dump
                dump_cmd="docker exec $container pg_dump -U \"$db_user\" \"$db_name\" --no-comments \
                    > \"$db_backup_name.tmp\""
            fi
            ;;
        *)
            echo "Error: Unknown DB type for $service_name"
            return 1
            ;;
    esac

    # Log the backup file name and command for debugging
    debug_log "db_backup_name" "$db_backup_name"
    debug_log "dump_cmd" "$dump_cmd"

    # Retry loop to attempt the backup multiple times if it fails
    local attempt=1
    while [ $attempt -le $retries ]; do
        # Execute the backup command
        eval $dump_cmd

        if [ $? -eq 0 ]; then
            # For SQLite, validate that the backup is not empty (4096 bytes)
            if [ "$db_type" == "sqlite" ] && [ "$(stat --format=%s "$db_backup_name.tmp")" -eq 4096 ]; then
                echo "Error: Backup for $service_name is 4096 bytes, likely invalid."
                rm -f "$db_backup_name.tmp"
                log_failure_and_exit "$service_name"
            fi

            # Move the backup to its final location if successful
            compare_and_move_backup "$db_backup_name.tmp" "$db_backup_name" "$service_name"
            return 0  # Success, exit the function
        else
            # If the backup fails, retry after a delay
            echo "Retry $attempt of $retries for $service_name db."
            attempt=$((attempt + 1))
            sleep $wait_time
        fi
    done

    # If all retry attempts fail, log failure and exit
    echo "Backup failed for $db_type database after $retries retries."
    log_failure_and_exit "$service_name"
}

# Backup files and directories using restic
backup_service() {
    local service_name=$1
    shift 1  # Skip the service_name argument

    # Array to store paths, including expanded wildcards
    local expanded_paths=()

    # Loop through each path to handle wildcards and quoting
    for path in "$@"; do
        if [[ "$path" == *"*"* ]]; then
            # Expand wildcard paths using eval, and store the results
            eval "expanded_paths+=(\"$path\")"
        else
            # Directly store paths without wildcards, quoting them
            expanded_paths+=("\"$path\"")
        fi
    done

    # Log expanded paths for debugging purposes
    debug_log "expanded_paths" "${expanded_paths[*]}"

    # Combine all expanded paths into a single restic command
    local restic_command="restic backup --tag \"$service_name\" --exclude-file=\"$DIR/excludes.txt\" ${expanded_paths[@]}"

    # Log the restic command for debugging purposes
    debug_log "restic_command" "$restic_command"

    # Run the combined command using eval
    eval $restic_command 2>&1

    # Check if the restic command was successful
    if [ $? -eq 0 ]; then
        echo "Backup for $service_name completed successfully."
        echo # Blank line for readability
    else
        # Log failure and send a status update if the backup fails
        echo "Backup for $service_name failed."
        send_status "down" "restic backup FAILED"
        return 1
    fi
}

# Check if it's time to run the prune operation (every 30 days)
should_prune() {
    local prune_interval_days=30  # Prune interval in days
    local last_prune_file="$DIR/.last_prune"  # Location of the prune timestamp file

    # TODO: Add finer control over the pruning interval (e.g., configurable through .env)

    # Log the prune interval and file for debugging
    debug_log "prune_interval_days" "$prune_interval_days"
    debug_log "last_prune_file" "$last_prune_file"

    # Check if the prune file exists
    if [ ! -f "$last_prune_file" ]; then
        echo "Prune has never been run. Proceeding with prune."
        return 0
    fi

    # Read the last prune timestamp and compare with the current date
    local last_prune_date=$(cat "$last_prune_file")
    local current_date=$(date +%s)
    local prune_interval_sec=$((prune_interval_days * 24 * 60 * 60))

    # Log prune dates and intervals for debugging
    debug_log "last_prune_date" "$last_prune_date"
    debug_log "current_date" "$current_date"
    debug_log "prune_interval_sec" "$prune_interval_sec"

    # Check if the current date exceeds the prune interval
    if (( current_date - last_prune_date >= prune_interval_sec )); then
        echo "Prune interval met. Proceeding with prune."
        return 0
    else
        # Calculate how many days are left until the next prune
        local time_diff=$((last_prune_date + prune_interval_sec - current_date))
        local time_left=$((time_diff / 86400))
        echo "$time_left days until the next prune."
        return 1
    fi
}

# Update the last prune timestamp after a successful prune
update_last_prune_time() {
    # Update the last prune file with the current timestamp
    echo "$(date +%s)" > "$DIR/.last_prune"
    
    # Log the update for debugging purposes
    debug_log "Updated last prune time" "$(cat "$DIR/.last_prune")"
}

# Main function to perform backups for each service defined in the YAML file
perform_backup() {
    # Extract the base path for services from the YAML file
    # Export for use in excludes.txt
    BASE_PATH=$(yq eval '.base_path' "$config_yaml")
    export BASE_PATH

    # TODO: Consider adding validation or logging if the base path is empty or undefined

    # Exit if the BASE_PATH is not defined in the YAML
    if [ -z "$BASE_PATH" ]; then
        echo "Error: BASE_PATH is not defined in config.yaml"
        exit 1
    fi

    # Log base path for debugging
    debug_log "BASE_PATH" "$BASE_PATH"

    # Extract the list of services from the YAML configuration
    local services_list=$(yq eval -r '.services | keys[]' "$config_yaml")

    # Iterate through each service in the list
    for service_name in $services_list; do
        # Skip if service_name is empty
        [ -z "$service_name" ] && continue

        # Define the service directory based on BASE_PATH and service name
        local service_dir="$BASE_PATH/$service_name"

        # Log service information for debugging
        debug_log "service_name" "$service_name"
        debug_log "service_dir" "$service_dir"

        # Check if the service directory exists, exit with error if not
        if [ ! -d "$service_dir" ]; then
            echo "Error: Service directory $service_dir does not exist"
            exit 1
        fi

        # Start the backup for the service
        echo "Starting backup for $service_name..."

        # Extract database-related variables from the YAML file
        local db_type=$(yq eval ".services.$service_name.db_type // null" "$config_yaml")
        local db_names=$(yq eval ".services.$service_name.db_names[]" "$config_yaml")
        local container=$(yq eval ".services.$service_name.container // null" "$config_yaml")
        local db_user=$(yq eval ".services.$service_name.db_user // null" "$config_yaml")
        local db_password=$(yq eval ".services.$service_name.db_password // null" "$config_yaml")
        local paths=$(yq eval ".services.$service_name.paths[]" "$config_yaml")

        # Log extracted variables for debugging purposes
        debug_log "db_type" "$db_type"
        debug_log "db_names" "$db_names"
        debug_log "container" "$container"
        debug_log "db_user" "$db_user"
        debug_log "db_password" "$db_password"
        debug_log "paths" "$paths"

        # Create a backup directory within the service's folder if it doesn't exist
        local backup_dir="$service_dir/backup"
        mkdir -p "$backup_dir"
        local db_backup_paths=()

        # If the service has a defined db_type, handle database backup accordingly
        if [ "$db_type" != "null" ]; then
            case $db_type in
                sqlite)
                    # Handle multiple SQLite databases
                    while IFS= read -r db_name; do
                        # If the db_name is a relative path, prepend the service_dir
                        [[ "$db_name" != /* ]] && db_name="$service_dir/$db_name"

                        # Extract the parent directory and base name of the database
                        local parent_dir=$(basename "$(dirname "$db_name")")
                        local base_db_name="$(basename "$db_name" | sed 's/\.[^.]*$//')"

                        # Define the backup file name with appropriate extension
                        local db_backup_name="${backup_dir}/${service_name}_${parent_dir}_${base_db_name}.sqlite3"

                        # Log the constructed backup file name for debugging
                        debug_log "db_backup_name" "$db_backup_name"

                        # Add the backup file name to the array of backup paths
                        db_backup_paths+=("$db_backup_name")

                        # Perform the database backup
                        backup_db "$db_type" "$container" "$db_user" "$db_password" "$db_name" "$backup_dir" "$service_name" || return 1
                    done <<< "$db_names"
                    ;;
                mariadb|postgres)
                    # Handle MariaDB and PostgreSQL databases
                    local db_name=$(yq eval ".services.$service_name.db_name" "$config_yaml")

                    # Log the database name for debugging
                    debug_log "db_name" "$db_name"

                    # Perform the database backup
                    backup_db "$db_type" "$container" "$db_user" "$db_password" "$db_name" "$backup_dir" "$service_name" || return 1
                    ;;
            esac
        fi

        # If paths are defined, perform file backups using restic
        if [ -n "$paths" ]; then
            local full_paths=""
            for path in $paths; do
                # If the path is a relative path, prepend the service_dir
                if [[ "$path" != /* ]]; then
                    full_paths="$full_paths \"$service_dir/$path\""
                else
                    full_paths="$full_paths \"$path\""
                fi
            done

            # Perform the file backup using restic
            backup_service "$service_name" $full_paths "${db_backup_paths[@]}" || return 1
        elif [ "${#db_backup_paths[@]}" -gt 0 ]; then
            # If there are no paths but there are database backups, back them up
            backup_service "$service_name" "${db_backup_paths[@]}" || return 1
        else
            # If no paths are defined for this service, skip the file backup
            echo "No paths specified for $service_name, skipping file backup."
        fi
    done
}

# Function to back up system files specified in the YAML config
perform_system_file_backup() {
    echo "Backing up system files..."

    # Extract the list of system files paths from the YAML file
    local system_files_paths=$(yq eval '.system_files.paths[]' "$config_yaml")

    # Log the extracted paths for debugging
    debug_log "system_files_paths" "$system_files_paths"

    # If system files are defined, back them up using restic
    if [ -n "$system_files_paths" ]; then
        # Pass the paths to backup_service for the actual backup process
        backup_service "system_files" $system_files_paths
    else
        # If no system files are defined, print a message and skip
        echo "No system files specified."
    fi
}

# Execute the system file backup first
perform_system_file_backup

# Run the backup for services defined in the config
perform_backup
backup_status=$?

# If the backup process completes successfully, run the forget step
if [ $backup_status -eq 0 ]; then
    echo "Running forget step..."

    # Execute restic forget with defined retention policy and show output
    restic forget --group-by host,tag --keep-daily 3 --keep-weekly 2 --keep-monthly 6 --keep-yearly 1 > /dev/null 2>&1
    
    # Log the forget exit status for debugging
    forget_status=$?
    debug_log "restic forget exit status" "$forget_status"

    # If forget fails, send failure status and log the failure
    if [ $forget_status -ne 0 ]; then
        echo "restic forget FAILED, refer to logs"
        send_status "down" "restic forget FAILED"
        exit 1
    else
        echo "restic forget completed successfully."
    fi
else
    # If the backup itself fails, send failure status and log the failure
    echo "restic backup FAILED, refer to logs"
    send_status "down" "restic backup FAILED"
    exit 1
fi

# Prune backups every 30 days (conditional on the should_prune function)
should_prune && {
    echo "Running prune operation..."
    
    # Execute restic prune and show output
    restic prune

    # Log the prune exit status for debugging
    prune_status=$?
    debug_log "restic prune exit status" "$prune_status"

    # If prune fails, send failure status
    [ $prune_status -ne 0 ] && send_status "down" "restic prune FAILED" && exit 1

    # Update the prune time after successful prune
    update_last_prune_time
}

# Send final success message once all tasks are completed
send_status "up" "OK"
echo "All operations completed successfully."
