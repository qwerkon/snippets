#!/usr/bin/env bash

# Ensure that the script is run using Bash
if [ -z "$BASH_VERSION" ]; then
  echo "This script requires Bash. Please run it using bash."
  exit 1
fi

# Function to display the help message
function print_help() {
  cat << EOF
Usage: $0 [options]

This deployment script automates the process of putting a Laravel application into maintenance mode,
pulling the latest code from a Git repository, updating dependencies, running migrations, clearing caches,
adjusting permissions, and finally bringing the application back online.

Available options:
  -d                Dry-run mode. Commands will be printed but not executed.
  -b <git_branch>   Specify the Git branch to check out before pulling updates.
  -l <log_file>     Specify a custom log file path.
  -f                Force execution even if another instance is running.
  -h, --help       Display this help message and exit.
  --no-ansi        Disable ANSI color output.

Additional functionalities:
  - Logs all operations to a specified log file (default location: /var/logs/publication).
  - Measures and displays the total execution time.
  - Checks if the CLI user is part of the "www-data" group and warns if not.
  - Checks the status of "cron", "supervisor", and "apache2" services before and after deployment.
  - Prevents race conditions by default (using a lock file), but can be bypassed with -f.
EOF
}

# Check for help flag before processing other arguments
for arg in "$@"; do
  if [[ "$arg" == "-h" || "$arg" == "--help" ]]; then
    print_help
    exit 0
  fi
done

# Parse the --no-ansi flag manually from the arguments and remove it
NO_ANSI=0
TEMP=()
for arg in "$@"; do
  if [ "$arg" == "--no-ansi" ]; then
    NO_ANSI=1
  else
    TEMP+=("$arg")
  fi
done
set -- "${TEMP[@]}"

# Define color variables based on the NO_ANSI flag
if [ "$NO_ANSI" -eq 1 ]; then
  GREEN=""
  RED=""
  YELLOW=""
  RESET=""
else
  GREEN="\e[32m"
  RED="\e[31m"
  YELLOW="\e[33m"
  RESET="\e[0m"
fi

# Parameterization: default values
DRY_RUN=0
GIT_BRANCH=""
FORCE=0

# Parsing command-line options (short options)
while getopts "fdb:l:" opt; do
    case "$opt" in
        f) FORCE=1 ;;
        d) DRY_RUN=1 ;;
        b) GIT_BRANCH="$OPTARG" ;;
        l) LOG_FILE="$OPTARG" ;;
        *) echo "Usage: $0 [-f force] [-d dry-run] [-b git_branch] [-l log_file] [--no-ansi]" ; exit 1 ;;
    esac
done
shift $((OPTIND-1))

# Define the log directory and file path
LOG_DIR="/var/logs/publication"
# Create the log directory if it doesn't exist
if [ ! -d "$LOG_DIR" ]; then
  mkdir -p "$LOG_DIR"
fi
# If LOG_FILE not already set via option, use default name
if [ -z "$LOG_FILE" ]; then
  LOG_FILE="$LOG_DIR/deploy_$(date +%Y%m%d_%H%M%S).log"
fi

# Prevent race conditions by creating a lock file (unless force mode is enabled)
if [ "$FORCE" -eq 0 ]; then
  LOCK_FILE="/tmp/deploy.lock"
  exec 200>"$LOCK_FILE"
  flock -n 200 || { echo -e "${RED}[ERROR] Another instance of deployment is already running. Exiting.${RESET}" | tee -a "$LOG_FILE"; exit 1; }
else
  echo -e "${YELLOW}[WARNING] Force mode enabled: skipping lock check. Be aware of possible race conditions.${RESET}" | tee -a "$LOG_FILE"
fi

# Start measuring execution time
START_TIME=$(date +%s)

# Initialize logging – record the start date
echo -e "${GREEN}=== Deployment started at $(date)${RESET}" | tee -a "$LOG_FILE"

set -e  # Terminate the script on the first error
trap 'echo -e "${RED}[ERROR] An error occurred at line $LINENO. Aborting execution.${RESET}" | tee -a "$LOG_FILE"' ERR

# Function info() – displays messages in color and logs them
function info() {
  echo -e "${GREEN}=== $1${RESET}" | tee -a "$LOG_FILE"
}

# Function log_message() – logs a message with a timestamp to the log file
function log_message() {
  echo "$(date +'%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

# Function run_command() – executes a command; in dry-run mode, it only displays what would be executed,
# and in case of an error, it displays the output.
function run_command() {
  local cmd="$*"
  if [ $DRY_RUN -eq 1 ]; then
    info "[DRY RUN] $cmd"
    log_message "[DRY RUN] $cmd"
  else
    log_message "Running command: $cmd"
    local start_cmd=$(date +%s)
    local output
    if ! output=$($cmd 2>&1); then
      echo -e "${RED}[ERROR] Command '$cmd' failed with error:\n$output${RESET}" | tee -a "$LOG_FILE"
      # exit 1
    fi
    local end_cmd=$(date +%s)
    local elapsed=$((end_cmd - start_cmd))
    log_message "Command '$cmd' executed in ${elapsed}s."
  fi
}

# Function check_service() – checks the status of a service (using the service command)
# and displays a message only if the service is not running.
function check_service() {
  local service_name="$1"
  if ! service "$service_name" status > /dev/null 2>&1; then
    info "Service '$service_name' is not running."
    log_message "Service '$service_name' is not running."
  else
    log_message "Service '$service_name' is running."
  fi
}

# Check if the CLI user belongs to the www-data group
if groups $(whoami) | grep -q '\bwww-data\b'; then
    info "User $(whoami) is a member of the www-data group."
    log_message "User $(whoami) is in group www-data."
else
    echo -e "\n${YELLOW}[WARNING] User $(whoami) is not a member of the www-data group.${RESET}" | tee -a "$LOG_FILE"
    echo -e "Add the user to the www-data group with the following command:\n  sudo usermod -a -G www-data $(whoami)" | tee -a "$LOG_FILE"
    log_message "Warning: User $(whoami) is not in group www-data."
fi

# Check the status of services before stopping them
check_service cron
check_service supervisor

info "Putting application into maintenance mode..."
run_command php artisan down --no-ansi

info "Pulling latest changes from the Git repository..."
# If a branch is provided, switch to it
if [ -n "$GIT_BRANCH" ]; then
  run_command git checkout "$GIT_BRANCH"
fi
run_command git pull

info "Stopping processes managed by supervisor..."
run_command supervisorctl stop all

info "Stopping the cron service..."
run_command service cron stop

info "Installing production dependencies (excluding development packages)..."
run_command composer install --no-dev

info "Running database migrations..."
run_command php artisan migrate --force --step --no-ansi

info "Clearing cache and views..."
run_command php artisan optimize:clear --no-ansi
run_command php artisan view:clear --no-ansi

info "Optimizing configuration and building view cache..."
run_command php artisan optimize --no-ansi
run_command php artisan view:cache --no-ansi

info "Adjusting permissions for directories: storage/framework, storage/logs, and bootstrap/cache..."
run_command chown -R :www-data storage/framework storage/logs bootstrap/cache
run_command chmod -R 775 storage/framework storage/logs bootstrap/cache

info "Bringing application out of maintenance mode..."
run_command php artisan up --no-ansi

info "Restarting processes managed by supervisor..."
run_command supervisorctl restart all

info "Restarting the cron service..."
run_command service cron restart

info "Reloading the apache2 service..."
run_command service apache2 reload

# Check the status of services after restart
check_service cron
check_service supervisor
check_service apache2

info "Deployment completed successfully!"

# Calculate and display the total execution time
end_time=$(date +%s)
elapsed_time=$((end_time - START_TIME))
info "Execution time: ${elapsed_time} seconds."
log_message "Deployment finished in ${elapsed_time} seconds."

# (Optional) Release the lock file if used
if [ "$FORCE" -eq 0 ]; then
  flock -u 200
  exec 200>&-
fi
