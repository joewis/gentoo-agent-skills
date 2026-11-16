#!/bin/bash
# Emerge Steward - Safe package installer with audit logging
# All installations are logged to package_history.log

LOG_FILE="/var/lib/openclaw/.openclaw/workspace/package_history.log"
PACKAGE="$1"
ACTION="${2:-install}"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

if [ -z "$PACKAGE" ]; then
    echo "Usage: $0 <package> [install|update|sync]"
    exit 1
fi

log_entry() {
    local status="$1"
    local details="$2"
    echo "{\"timestamp\":\"$TIMESTAMP\",\"package\":\"$PACKAGE\",\"action\":\"$ACTION\",\"status\":\"$status\",\"details\":\"$details\"}" >> "$LOG_FILE"
}

echo "[emerge-steward] Starting: $ACTION on $PACKAGE"

case "$ACTION" in
    sync)
        log_entry "STARTED" "Beginning emerge --sync"
        emerge --sync 2>&1
        result=$?
        if [ $result -eq 0 ]; then
            log_entry "SUCCESS" "Portage tree synced successfully"
        else
            log_entry "FAILED" "emerge --sync failed with exit code $result"
        fi
        ;;
    install|update)
        # Preview first
        log_entry "PREVIEW" "Running emerge -pv $PACKAGE"
        if ! emerge -pv "$PACKAGE" > /dev/null 2>&1; then
            echo "[emerge-steward] Package '$PACKAGE' not found or invalid."
            log_entry "FAILED" "Package not found in tree"
            exit 1
        fi

        # Confirm with user (this script is meant to be called by the agent which handles confirmation)
        # Execute actual installation
        log_entry "STARTED" "Running emerge -av $PACKAGE"
        emerge -av "$PACKAGE" 2>&1
        result=$?

        if [ $result -eq 0 ]; then
            log_entry "SUCCESS" "Package $PACKAGE installed/updated successfully"
        else
            log_entry "FAILED" "emerge failed with exit code $result"
        fi
        ;;
    *)
        echo "[emerge-steward] Unknown action: $ACTION"
        log_entry "FAILED" "Unknown action: $ACTION"
        exit 1
        ;;
esac

exit $result