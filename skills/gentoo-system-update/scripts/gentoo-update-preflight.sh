#!/bin/bash
# Gentoo weekly update — PREFLIGHT PHASE.
#
# Runs the bounded steps (sync + portage self-update + pretend @world + news count),
# writes a structured state file, and exits. The LLM agent reads the state and
# runs the long step (real @world emerge, depclean, eclean, npm, flatpak, kernel).
#
# Why split: preflight has predictable runtime; the long step is where reasoning
# (slot conflicts, masked packages, news, npm symlink drift) is needed. Doing the
# short bits in bash and the long bits in the agent is cheaper and more robust
# than a single monolithic bash script.
#
# Cron setup that pairs with this script:
#   - LLM-driven (no_agent=false)
#   - Schedule: 0 23 * * 5 (Fri 23:00 SGT)  — standard cron, NOT English names
#   - enabled_toolsets: ["terminal", "file"]
#   - skills: ["gentoo-system-update"]  (this skill)
#   - script: gentoo-update.sh  (this file)
#   - The agent's prompt tells it: cd to WORKSPACE, read state.json, then run
#     @world + depclean + eclean + npm + flatpak + eselect kernel under sudo.

set -u

WORKSPACE="/home/carl/.hermes/work/gentoo-update"
STATE_FILE="$WORKSPACE/state.json"
LOG_FILE="$WORKSPACE/run.log"
PRETEND_LOG="$WORKSPACE/pretend.log"
mkdir -p "$WORKSPACE"
: > "$LOG_FILE"

# Script-level redirect (NOT invocation-level). Survives launch via
# terminal(background=true), nohup, at, systemd, anything.
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=== gentoo-update preflight started at $(date -Iseconds) ==="
echo "user: $(whoami), host: $(hostname)"

# --- 0. Pre-flight: disk space (bail early if /var or /var/tmp/portage is full) ---
echo
echo "[preflight] disk space:"
df -h /var /usr /var/tmp/portage 2>/dev/null
echo

# --- 1. Sync repos ---
echo "[step 1/4] emaint -a sync"
sudo emaint -a sync
SYNC_EXIT=$?
echo "sync exit: $SYNC_EXIT"
echo

# --- 2. Portage self-update ---
echo "[step 2/4] emerge --oneshot sys-apps/portage"
sudo emerge --oneshot --verbose sys-apps/portage
PORTAGE_EXIT=$?
echo "portage exit: $PORTAGE_EXIT"
echo

# --- 3. Pretend @world (the agent will read this file to see what would change) ---
echo "[step 3/4] emerge -pv @world"
sudo emerge --pretend --verbose --update --deep --changed-use @world 2>&1 \
  | tee "$PRETEND_LOG" | tail -50
PRETEND_COUNT=$(grep -c '^\[ebuild' "$PRETEND_LOG" 2>/dev/null || echo 0)
echo "would update: $PRETEND_COUNT packages"
echo

# --- 4. News count (the agent reads each unread item) ---
echo "[step 4/4] eselect news list"
NEWS_LIST=$(sudo eselect news list 2>&1)
echo "$NEWS_LIST"
NEWS_UNREAD=$(echo "$NEWS_LIST" | grep -c '^\*')
echo "unread news items: $NEWS_UNREAD"
echo

# --- Write preliminary state for the agent ---
cat > "$STATE_FILE" <<EOF
{
  "started_at": "$(date -Iseconds)",
  "sync_exit": $SYNC_EXIT,
  "portage_exit": $PORTAGE_EXIT,
  "would_update_count": $PRETEND_COUNT,
  "news_unread": $NEWS_UNREAD,
  "phase": "preflight_complete",
  "log_file": "$LOG_FILE",
  "pretend_log": "$PRETEND_LOG"
}
EOF

echo "[state] preliminary state written to $STATE_FILE"
echo "=== preflight complete at $(date -Iseconds) — agent will now proceed with @world + cleanup ==="
