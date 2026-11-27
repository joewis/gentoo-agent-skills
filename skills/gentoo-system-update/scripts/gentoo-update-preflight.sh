#!/bin/bash
# Gentoo weekly update — PREFLIGHT PHASE.
#
# Runs the bounded steps (sync + portage self-update + pretend @world + pending
# config candidates + news count),
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
echo "[step 1/5] emaint -a sync"
sudo emaint -a sync
SYNC_EXIT=$?
echo "sync exit: $SYNC_EXIT"
echo

# --- 2. Portage self-update ---
echo "[step 2/5] emerge --oneshot sys-apps/portage"
sudo emerge --oneshot --verbose sys-apps/portage
PORTAGE_EXIT=$?
echo "portage exit: $PORTAGE_EXIT"
echo

# --- 3. Pretend @world (the agent will read this file to see what would change) ---
echo "[step 3/5] emerge -pv @world"
sudo emerge --pretend --verbose --update --deep --changed-use @world 2>&1 \
  | tee "$PRETEND_LOG" | tail -50
PRETEND_COUNT=$(grep -c '^\[ebuild' "$PRETEND_LOG" 2>/dev/null || true)
echo "would update: $PRETEND_COUNT packages"
echo

# --- 4. Protected config candidates (NEVER auto-merged) ---
echo "[step 4/5] protected config candidates (._cfg????_*)"
CFG_LOG="$WORKSPACE/config-candidates.log"
CFG_RAW="$WORKSPACE/.config-candidates.raw"
# Keep find's own status: "we could not look" must never read as "nothing to see".
sudo find /etc -name '._cfg????_*' 2>/dev/null > "$CFG_RAW"
CFG_FIND_EXIT=$?
sort "$CFG_RAW" > "$CFG_LOG" 2>/dev/null || true
rm -f "$CFG_RAW"
if [ "$CFG_FIND_EXIT" -ne 0 ]; then
  echo "!! find exited $CFG_FIND_EXIT -- this list is INCOMPLETE, not empty"
fi
CFG_COUNT=$(grep -c . "$CFG_LOG" 2>/dev/null || true)
echo "pending config candidates: ${CFG_COUNT:-0}"
cat "$CFG_LOG"
# Candidates are named <target>._cfg0000_<name> INSIDE the target's own directory,
# so the file that matters is /etc/._cfg0000_sudoers, not "/etc/sudoers". Judge the
# real filename after stripping the prefix, and judge drop-in dirs by the parent.
CFG_SENSITIVE=""
while IFS= read -r cand; do
  [ -z "$cand" ] && continue
  base=${cand##*/}
  name=${base#._cfg????_}
  parent=${cand%/*}; parent=${parent##*/}
  case "$name" in
    sudoers|sshd_config|shadow|gshadow|passwd|group|fstab)
      CFG_SENSITIVE+="$cand"$'\n' ;;
    *)
      case "$parent" in
        pam.d|init.d|sudoers.d) CFG_SENSITIVE+="$cand"$'\n' ;;
      esac ;;
  esac
done < "$CFG_LOG"
CFG_SENSITIVE_COUNT=$(printf '%s' "$CFG_SENSITIVE" | grep -c . 2>/dev/null || true)
if [ "${CFG_SENSITIVE_COUNT:-0}" -gt 0 ]; then
  echo
  echo "!! ACCESS-GOVERNING CONFIG CANDIDATES -- review each in full before writing:"
  printf '%s' "$CFG_SENSITIVE"
  echo "!! sudoers: sudo grep -nE 'NOPASSWD|%wheel|env_keep' /etc/sudoers   # what can be lost?"
  echo "!! visudo -cf proves syntax only, never that privileges survive"
  echo "!! keep privileged grants in /etc/sudoers.d/ so upstream replacements cannot erase them"
fi
echo

# --- 5. News count (the agent reads each unread item) ---
echo "[step 5/5] eselect news list"
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
  "config_candidates": ${CFG_COUNT:-0},
  "config_candidates_sensitive": ${CFG_SENSITIVE_COUNT:-0},
  "config_find_exit": ${CFG_FIND_EXIT:-1},
  "config_candidates_log": "$CFG_LOG",
  "phase": "preflight_complete",
  "log_file": "$LOG_FILE",
  "pretend_log": "$PRETEND_LOG"
}
EOF

echo "[state] preliminary state written to $STATE_FILE"
echo "=== preflight complete at $(date -Iseconds) — agent will now proceed with @world + cleanup ==="
