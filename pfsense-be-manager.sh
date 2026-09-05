#!/bin/sh
#
# pfsense-be-manager - Boot Environment Manager for pfSense CE
#
# Menu-driven ZFS boot environment and snapshot management for pfSense CE.
# It creates a CE-compatible boot environment by cloning a BE using bectl,
# then copying /cf into the clone (pfSense configuration is in /cf/conf).
#
# Run as root: ./pfsense-be-manager.sh
#
# IMPORTANT:
#   Prefer boot-environment activation for ordinary upgrade recovery.
#   Full recursive ZFS rollback is destructive and is a last-resort action.
#
# Version: 2.1.0
# Date: 2026-09-05
#

set -o pipefail

POOL_NAME="pfSense"
MOUNT_BASE="${MOUNT_BASE:-/mnt}"
LOG_FILE="/var/log/pfsense-be-manager.log"
LOCK_FILE="/var/run/pfsense-be-manager.lock"
MIN_DISK_SPACE=$((1073741824))  # 1GB in bytes
CONFIG_BACKUP_DIR="/root/pfsense-config-backups"
RETENTION_CONF_DIR="/etc/pfsense-be-manager"
RETENTION_CONF_FILE="${RETENTION_CONF_DIR}/retention.conf"
DRY_RUN=0

# Color support: green=success, yellow=warning, red=error, blue=info.
# Disabled automatically when not attached to a TTY, or if
# PFSENSE_BE_NO_COLOR is set to any non-empty value.
if [ -t 1 ] && [ -z "${PFSENSE_BE_NO_COLOR:-}" ]; then
    COLOR_RED="$(printf '\033[31m')"
    COLOR_GREEN="$(printf '\033[32m')"
    COLOR_YELLOW="$(printf '\033[33m')"
    COLOR_BLUE="$(printf '\033[34m')"
    COLOR_RESET="$(printf '\033[0m')"
else
    COLOR_RED=""
    COLOR_GREEN=""
    COLOR_YELLOW=""
    COLOR_BLUE=""
    COLOR_RESET=""
fi

# format_size <bytes>
# Converts a raw byte count into a human-readable value (e.g. 1.2GiB)
# using numfmt when available, falling back to raw bytes otherwise.
format_size() {
    local bytes="$1"
    if [ -z "$bytes" ] || ! echo "$bytes" | grep -qE '^[0-9]+$'; then
        echo "$bytes"
        return 0
    fi
    if command -v numfmt >/dev/null 2>&1; then
        numfmt --to=iec-i --suffix=B "$bytes" 2>/dev/null || echo "${bytes} bytes"
    else
        echo "${bytes} bytes"
    fi
}

log_info() { 
    local msg="$1"
    echo "${COLOR_BLUE}[INFO]${COLOR_RESET} $msg"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $msg" >> "$LOG_FILE" 2>/dev/null || true
}

log_success() { 
    local msg="$1"
    echo "${COLOR_GREEN}[SUCCESS]${COLOR_RESET} $msg"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [SUCCESS] $msg" >> "$LOG_FILE" 2>/dev/null || true
}

log_warning() { 
    local msg="$1"
    echo "${COLOR_YELLOW}[WARNING]${COLOR_RESET} $msg"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARNING] $msg" >> "$LOG_FILE" 2>/dev/null || true
}

log_error() { 
    local msg="$1"
    echo "${COLOR_RED}[ERROR]${COLOR_RESET} $msg" >&2
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $msg" >> "$LOG_FILE" 2>/dev/null || true
}

cleanup() {
    rm -f "$LOCK_FILE"
}

acquire_lock() {
    if [ -e "$LOCK_FILE" ]; then
        log_error "Another instance is already running. Lock file: $LOCK_FILE"
        exit 1
    fi
    touch "$LOCK_FILE" 2>/dev/null || {
        log_error "Failed to create lock file: $LOCK_FILE"
        exit 1
    }
    trap cleanup EXIT
}

show_header() {
    echo ""
    echo "========================================"
    echo "  pfSense Boot Environment Manager"
    echo "  Version 2.1.0"
    echo "========================================"
    echo ""
}

pause() {
    echo "Press Enter to continue..."
    read -r DUMMY
}

validate_pool() {
    if ! zpool list "$POOL_NAME" >/dev/null 2>&1; then
        log_error "ZFS pool '$POOL_NAME' not found or inaccessible."
        exit 1
    fi
}

check_disk_space() {
    local available
    available=$(zfs get -Ho value available "$POOL_NAME" 2>/dev/null)
    
    if [ -z "$available" ]; then
        log_warning "Could not determine available disk space."
        return 0
    fi
    
    if [ "$available" -lt "$MIN_DISK_SPACE" ]; then
        log_warning "Low disk space: only $(format_size "$available") available"
        log_warning "Recommended minimum: 1GB"
        return 1
    fi
    return 0
}

# backup_config
# Creates a timestamped backup of /cf/conf/config.xml under
# CONFIG_BACKUP_DIR. Intended to be called before create_be and before
# snapshot creation to provide an extra, ZFS-independent recovery point.
backup_config() {
    if [ ! -f /cf/conf/config.xml ]; then
        log_warning "/cf/conf/config.xml not found; skipping config backup."
        return 1
    fi

    if ! mkdir -p "$CONFIG_BACKUP_DIR" 2>/dev/null; then
        log_error "Failed to create config backup directory: $CONFIG_BACKUP_DIR"
        return 1
    fi

    local backup_file
    backup_file="$CONFIG_BACKUP_DIR/config-$(date +%Y%m%d-%H%M%S).xml"
    if cp /cf/conf/config.xml "$backup_file" 2>/dev/null; then
        log_success "Config backup created: $backup_file"
        return 0
    else
        log_error "Failed to create config backup at $backup_file"
        return 1
    fi
}

validate_be_name() {
    local name="$1"
    
    if ! echo "$name" | grep -qE '^[a-zA-Z0-9._-]+$'; then
        log_error "Boot environment name contains invalid characters."
        log_error "Use only: a-z, A-Z, 0-9, . _ -"
        return 1
    fi
    return 0
}

validate_snapshot_name() {
    local name="$1"
    
    if ! echo "$name" | grep -qE '^[a-zA-Z0-9._:-]+$'; then
        log_error "Snapshot name contains invalid characters."
        log_error "Use only: a-z, A-Z, 0-9, . _ : -"
        return 1
    fi
    return 0
}

current_be() {
    bectl list -H 2>/dev/null | awk '$2 ~ /N/ {print $1; exit}'
}

show_current_be() {
    local current_be
    current_be=$(current_be)
    if [ -n "$current_be" ]; then
        echo "Current boot environment: $current_be"
        echo ""
    fi
}

be_exists() {
    local be_name="$1"
    bectl list -H 2>/dev/null | awk '{print $1}' | grep -Fx "$be_name" >/dev/null 2>&1
}

pool_snapshot_list() {
    zfs list -H -t snapshot -o name 2>/dev/null | grep -E "^${POOL_NAME}@" || true
}

pool_snapshot_count() {
    pool_snapshot_list | sed '/^$/d' | wc -l | tr -d ' '
}

# load_retention_policy
# Reads RETENTION_MODE (count|days|none) and RETENTION_VALUE from
# RETENTION_CONF_FILE. Defaults to "none" (no automatic cleanup) when the
# file is missing or unreadable.
load_retention_policy() {
    RETENTION_MODE="none"
    RETENTION_VALUE=""
    if [ -f "$RETENTION_CONF_FILE" ]; then
        # shellcheck disable=SC1090
        . "$RETENTION_CONF_FILE" 2>/dev/null || true
    fi
}

# save_retention_policy <mode> <value>
save_retention_policy() {
    local mode="$1" value="$2"
    if ! mkdir -p "$RETENTION_CONF_DIR" 2>/dev/null; then
        log_error "Failed to create config directory: $RETENTION_CONF_DIR"
        return 1
    fi
    {
        echo "# pfsense-be-manager snapshot retention policy"
        echo "# mode: count = keep last N pool-level snapshot sets"
        echo "#       days  = delete pool-level snapshot sets older than N days"
        echo "#       none  = no automatic cleanup"
        echo "RETENTION_MODE=\"$mode\""
        echo "RETENTION_VALUE=\"$value\""
    } > "$RETENTION_CONF_FILE" 2>/dev/null
    if [ $? -ne 0 ]; then
        log_error "Failed to write retention policy to $RETENTION_CONF_FILE"
        return 1
    fi
    log_success "Retention policy saved to $RETENTION_CONF_FILE"
    return 0
}

configure_retention_policy() {
    show_header
    log_info "Configure snapshot retention policy"
    echo ""
    load_retention_policy
    echo "Current policy: mode=$RETENTION_MODE value=${RETENTION_VALUE:-n/a}"
    echo ""
    echo "Choose a retention mode:"
    echo "  1) Keep only the last N pool-level snapshot sets"
    echo "  2) Delete pool-level snapshot sets older than X days"
    echo "  3) Disable automatic cleanup"
    echo "  q) Cancel"
    printf "Selection: "
    read -r mode_choice

    case "$mode_choice" in
        1)
            printf "Number of most recent snapshot sets to keep: "
            read -r value
            if ! echo "$value" | grep -qE '^[0-9]+$' || [ "$value" -lt 1 ]; then
                log_error "Please enter a positive integer."
                return 1
            fi
            save_retention_policy "count" "$value"
            ;;
        2)
            printf "Delete snapshot sets older than how many days: "
            read -r value
            if ! echo "$value" | grep -qE '^[0-9]+$' || [ "$value" -lt 1 ]; then
                log_error "Please enter a positive integer."
                return 1
            fi
            save_retention_policy "days" "$value"
            ;;
        3)
            save_retention_policy "none" ""
            ;;
        q|Q) return 0 ;;
        *) log_error "Invalid selection."; return 1 ;;
    esac
    echo ""
}

# cleanup_old_snapshots
# Enforces the configured retention policy against pool-level (recursive)
# snapshot sets. Runs automatically when new snapshots are created, and
# reports what (if anything) was removed.
cleanup_old_snapshots() {
    load_retention_policy

    if [ "$RETENTION_MODE" = "none" ] || [ -z "$RETENTION_MODE" ]; then
        return 0
    fi

    local snap_tags removed_count=0 freed_total=0
    snap_tags=$(pool_snapshot_list | sed -E "s/^${POOL_NAME}@//" | sort -u)
    if [ -z "$snap_tags" ]; then
        return 0
    fi

    if [ "$RETENTION_MODE" = "count" ]; then
        local total keep skip
        total=$(printf '%s\n' "$snap_tags" | sed '/^$/d' | wc -l | tr -d ' ')
        keep="$RETENTION_VALUE"
        if [ "$total" -le "$keep" ]; then
            log_info "Retention policy: $total snapshot set(s) present, keeping last $keep. No cleanup needed."
            return 0
        fi
        skip=$((total - keep))
        # Oldest first: sort snapshot tags by the creation time of the pool-level snapshot.
        local ordered
        ordered=$(zfs list -H -p -t snapshot -o name,creation -s creation 2>/dev/null | awk -v p="^${POOL_NAME}@" '$1 ~ p {print $1}' | sed -E "s/^${POOL_NAME}@//")
        local to_remove
        to_remove=$(printf '%s\n' "$ordered" | head -n "$skip")
        local tag
        for tag in $to_remove; do
            [ -z "$tag" ] && continue
            local snap_used
            snap_used=$(zfs get -Hp -o value used "${POOL_NAME}@${tag}" 2>/dev/null)
            if [ "$DRY_RUN" -eq 1 ]; then
                log_info "[DRY-RUN] Would destroy snapshot set '@${tag}' (retention policy: keep last $keep)"
            else
                if zfs destroy -r "${POOL_NAME}@${tag}" 2>/dev/null; then
                    removed_count=$((removed_count + 1))
                    [ -n "$snap_used" ] && freed_total=$((freed_total + snap_used))
                    log_success "Retention policy removed old snapshot set '@${tag}'"
                else
                    log_warning "Retention policy failed to remove snapshot set '@${tag}'"
                fi
            fi
        done
    elif [ "$RETENTION_MODE" = "days" ]; then
        local now cutoff tag created
        now=$(date +%s)
        cutoff=$((now - (RETENTION_VALUE * 86400)))
        for tag in $snap_tags; do
            [ -z "$tag" ] && continue
            created=$(zfs get -Hp -o value creation "${POOL_NAME}@${tag}" 2>/dev/null)
            [ -z "$created" ] && continue
            if [ "$created" -lt "$cutoff" ]; then
                local snap_used
                snap_used=$(zfs get -Hp -o value used "${POOL_NAME}@${tag}" 2>/dev/null)
                if [ "$DRY_RUN" -eq 1 ]; then
                    log_info "[DRY-RUN] Would destroy snapshot set '@${tag}' (older than $RETENTION_VALUE days)"
                else
                    if zfs destroy -r "${POOL_NAME}@${tag}" 2>/dev/null; then
                        removed_count=$((removed_count + 1))
                        [ -n "$snap_used" ] && freed_total=$((freed_total + snap_used))
                        log_success "Retention policy removed old snapshot set '@${tag}' (older than $RETENTION_VALUE days)"
                    else
                        log_warning "Retention policy failed to remove snapshot set '@${tag}'"
                    fi
                fi
            fi
        done
    fi

    if [ "$DRY_RUN" -ne 1 ]; then
        if [ "$removed_count" -gt 0 ]; then
            log_success "Retention cleanup removed $removed_count snapshot set(s), freeing approximately $(format_size "$freed_total")."
        else
            log_info "Retention cleanup: no snapshot sets required removal."
        fi
    fi
    return 0
}

list_bes() {
    show_header
    log_info "Boot environments:"
    echo ""
    bectl list
    echo ""
    show_current_be
}

create_pool_snapshot_named() {
    local snap_name="$1"

    if [ -z "$snap_name" ]; then
        log_error "Snapshot name cannot be empty."
        return 1
    fi

    if ! validate_snapshot_name "$snap_name"; then
        return 1
    fi

    if zfs list -H -t snapshot -o name 2>/dev/null | grep -Fx "${POOL_NAME}@${snap_name}" >/dev/null 2>&1; then
        log_error "Snapshot '${POOL_NAME}@${snap_name}' already exists."
        return 1
    fi

    backup_config || true

    log_info "Creating recursive pool snapshot: ${POOL_NAME}@${snap_name}"
    if ! zfs snapshot -r "${POOL_NAME}@${snap_name}"; then
        log_error "Failed to create pool snapshot."
        return 1
    fi
    log_success "Pool snapshot created."
    cleanup_old_snapshots
    return 0
}

create_be() {
    show_header
    log_info "Create a pre-upgrade boot environment"
    echo ""
    echo "A BE is a bootable clone of the currently running root environment."
    echo "On this pfSense CE layout, /cf is copied into the new BE so it contains"
    echo "the current pfSense configuration under conf/config.xml."
    echo ""

    if ! check_disk_space; then
        log_warning "Proceeding despite low disk space. This operation may fail."
    fi

    local suggested_name be_name mount_path
    suggested_name="pre-upgrade-$(date +%Y%m%d-%H%M%S)"
    echo "Suggested BE name: $suggested_name"
    printf "Enter BE name (or press Enter to use suggested): "
    read -r be_name

    if [ -z "$be_name" ]; then
        be_name="$suggested_name"
    fi

    if ! validate_be_name "$be_name"; then
        return 1
    fi

    if be_exists "$be_name"; then
        log_error "Boot environment '$be_name' already exists."
        return 1
    fi

    backup_config || true

    log_info "Creating boot environment: $be_name"
    if ! bectl create "$be_name"; then
        log_error "Failed to create boot environment (bectl create failed)."
        return 1
    fi

    if [ ! -d /cf ]; then
        log_error "/cf does not exist. Removing incomplete BE '$be_name'."
        bectl destroy "$be_name" >/dev/null 2>&1
        return 1
    fi

    log_info "Mounting BE and copying /cf configuration..."
    mount_path=$(bectl mount "$be_name" 2>&1)
    if [ -z "$mount_path" ] || [ ! -d "$mount_path" ]; then
        log_error "Failed to mount boot environment '$be_name'."
        bectl destroy "$be_name" >/dev/null 2>&1
        return 1
    fi

    if ! cp -R /cf "$mount_path/"; then
        log_error "Failed to copy /cf. Unmounting and destroying incomplete BE."
        bectl umount "$be_name" >/dev/null 2>&1 || true
        bectl destroy "$be_name" >/dev/null 2>&1
        return 1
    fi

    if ! bectl umount "$be_name"; then
        log_error "Failed to unmount '$be_name' from $mount_path."
        return 1
    fi

    log_success "Boot environment '$be_name' created."
    echo ""

    printf "Also create a recursive pool snapshot now? (y/n): "
    read -r create_snap
    if [ "$create_snap" = "y" ] || [ "$create_snap" = "Y" ]; then
        local snap_name custom_snap_name
        snap_name="pre-upgrade-$(date +%Y%m%d-%H%M%S)"
        printf "Snapshot name [%s]: " "$snap_name"
        read -r custom_snap_name
        if [ -n "$custom_snap_name" ]; then
            snap_name="$custom_snap_name"
        fi
        create_pool_snapshot_named "$snap_name" || true
    fi

    echo ""
    log_info "Normal rollback method after a failed upgrade:"
    echo "  bectl activate $be_name"
    echo "  reboot"
    echo ""
}

create_pool_snapshot() {
    show_header
    log_info "Create a pool-level ZFS snapshot"
    echo ""
    echo "This creates a recursive snapshot of all datasets under '$POOL_NAME'."
    echo "Use it as an additional, destructive full-pool rollback point."
    echo ""

    if ! check_disk_space; then
        log_warning "Proceeding despite low disk space. This operation may fail."
    fi

    local suggested_name snap_name
    suggested_name="manual-$(date +%Y%m%d-%H%M%S)"
    printf "Snapshot name [%s]: " "$suggested_name"
    read -r snap_name
    if [ -z "$snap_name" ]; then
        snap_name="$suggested_name"
    fi

    if create_pool_snapshot_named "$snap_name"; then
        echo ""
        log_info "Created snapshot set (first 20 entries):"
        zfs list -H -t snapshot -o name 2>/dev/null | grep "@${snap_name}$" | head -20
        echo ""
        log_info "Use Option 7 only if a full destructive rollback is required."
    fi
    echo ""
}

activate_be() {
    show_header
    log_info "Select boot environment for next boot"
    echo ""
    echo "Available boot environments:"
    echo ""
    bectl list -H 2>/dev/null | nl -ba
    echo ""
    show_current_be

    printf "Enter BE number to activate (or q to cancel): "
    read -r selection
    case "$selection" in
        q|Q) return 0 ;;
        *[!0-9]*|'') log_error "Invalid selection."; return 1 ;;
    esac

    local be_name current_be_name
    be_name=$(bectl list -H 2>/dev/null | sed -n "${selection}p" | awk '{print $1}')
    if [ -z "$be_name" ]; then
        log_error "Invalid selection."
        return 1
    fi

    current_be_name=$(current_be)
    if [ "$be_name" = "$current_be_name" ]; then
        log_info "'$be_name' is already the running boot environment."
        return 0
    fi

    log_info "Setting '$be_name' as the next boot environment..."
    if bectl activate "$be_name"; then
        log_success "'$be_name' will be used at the next reboot."
        log_warning "Reboot is required to switch environments."
        echo "  reboot"
    else
        log_error "Failed to activate boot environment '$be_name'."
        return 1
    fi
    echo ""
}

destroy_be() {
    show_header
    log_warning "Destroy a boot environment"
    echo ""
    echo "This permanently deletes the selected BE. The currently running BE is excluded."
    echo ""

    local current_be_name candidates be_name selection confirm
    current_be_name=$(current_be)
    candidates=$(bectl list -H 2>/dev/null | awk -v current="$current_be_name" '$1 != current {print}')
    if [ -z "$candidates" ]; then
        log_info "No non-current boot environments are available to delete."
        return 0
    fi

    echo "$candidates" | nl -ba
    echo ""
    printf "Enter BE number to destroy (or q to cancel): "
    read -r selection
    case "$selection" in
        q|Q) return 0 ;;
        *[!0-9]*|'') log_error "Invalid selection."; return 1 ;;
    esac

    be_name=$(echo "$candidates" | sed -n "${selection}p" | awk '{print $1}')
    if [ -z "$be_name" ]; then
        log_error "Invalid selection."
        return 1
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        log_info "[DRY-RUN] Would destroy boot environment: $be_name"
        zfs list -r "${POOL_NAME}/ROOT/${be_name}" 2>/dev/null || true
        log_info "[DRY-RUN] No changes made."
        echo ""
        return 0
    fi

    log_warning "About to permanently destroy BE: $be_name"
    printf "Type DELETE to confirm: "
    read -r confirm
    if [ "$confirm" != "DELETE" ]; then
        log_info "Operation cancelled."
        return 0
    fi

    if bectl destroy "$be_name"; then
        log_success "Boot environment '$be_name' destroyed."
    else
        log_error "Failed to destroy boot environment '$be_name'."
        return 1
    fi
    echo ""
}

view_be_details() {
    show_header
    log_info "View boot environment details"
    echo ""
    bectl list -H 2>/dev/null | nl -ba
    echo ""
    printf "Enter BE number to inspect (or q to cancel): "
    read -r selection
    case "$selection" in
        q|Q) return 0 ;;
        *[!0-9]*|'') log_error "Invalid selection."; return 1 ;;
    esac

    local be_name mount_path
    be_name=$(bectl list -H 2>/dev/null | sed -n "${selection}p" | awk '{print $1}')
    if [ -z "$be_name" ]; then
        log_error "Invalid selection."
        return 1
    fi

    echo ""
    log_info "Boot environment: $be_name"
    bectl list 2>/dev/null | awk -v be="$be_name" '$1 == be {print}'
    echo ""
    echo "ZFS dataset:"
    zfs list -r "${POOL_NAME}/ROOT/${be_name}" 2>/dev/null || echo "  Dataset details unavailable."
    echo ""
    echo "Snapshots for this BE:"
    zfs list -t snapshot -r "${POOL_NAME}/ROOT/${be_name}" 2>/dev/null || echo "  No snapshots found."
    echo ""

    printf "Mount and verify conf/config.xml? (y/n): "
    read -r inspect
    if [ "$inspect" = "y" ] || [ "$inspect" = "Y" ]; then
        mount_path=$(bectl mount "$be_name" 2>&1)
        if [ -n "$mount_path" ] && [ -d "$mount_path" ]; then
            if [ -f "$mount_path/conf/config.xml" ]; then
                log_success "Found: $mount_path/conf/config.xml"
                ls -lh "$mount_path/conf/config.xml"
            else
                log_error "conf/config.xml NOT found. Boot environment may be corrupted."
            fi
            if bectl umount "$be_name"; then
                :
            else
                log_warning "Failed to unmount '$be_name'; check mount state manually."
            fi
        else
            log_error "Failed to mount boot environment '$be_name'."
        fi
    fi
    echo ""
}

show_snapshots() {
    show_header
    log_info "ZFS snapshots for pool: $POOL_NAME"
    echo ""

    local pool_snaps dataset_count pool_count
    pool_snaps=$(pool_snapshot_list)
    dataset_count=$(zfs list -H -t snapshot -o name 2>/dev/null | grep -c "^${POOL_NAME}/" || true)
    pool_count=$(pool_snapshot_count)

    echo "Pool-level snapshots: $pool_count (eligible for Option 7 full-pool rollback)"
    echo "Dataset-level snapshots: $dataset_count"
    echo ""

    echo "Pool-level snapshots:"
    if [ -n "$pool_snaps" ]; then
        zfs list -t snapshot -o name,creation,used,refer 2>/dev/null | awk -v p="${POOL_NAME}@" '$1 ~ "^" p {print}'
    else
        echo "  (none)"
    fi
    echo ""

    echo "Dataset-level snapshots (first 30):"
    zfs list -t snapshot 2>/dev/null | awk -v p="${POOL_NAME}/" '$1 ~ "^" p {print}' | head -30
    if [ "$dataset_count" -gt 30 ]; then
        log_info "Only the first 30 dataset snapshots are shown."
    fi
    echo ""
    echo "Note: A snapshot's USED value is space uniquely retained by that snapshot,"
    echo "not the size of data it can restore. Recursive snapshots include matching"
    echo "snapshots for the descendant datasets at the same point in time."
    echo ""
}

destroy_pool_snapshot() {
    show_header
    log_warning "Destroy a pool-level ZFS snapshot"
    echo ""
    echo "This removes the selected recursive snapshot set from '$POOL_NAME'."
    echo "The pool-level snapshot and its descendant dataset snapshots with the same"
    echo "name will be destroyed. This cannot be undone."
    echo ""
    echo "Do NOT remove your only known-good pre-upgrade recovery snapshot."
    echo ""

    local pool_snaps snapshot snap_tag descendant_count confirm1 confirm2 error_msg
    pool_snaps=$(pool_snapshot_list)
    if [ -z "$pool_snaps" ]; then
        log_info "No pool-level snapshots are available."
        return 0
    fi

    echo "Eligible pool-level snapshots:"
    echo ""
    zfs list -t snapshot -o name,creation,used,refer 2>/dev/null | awk -v p="${POOL_NAME}@" '$1 ~ "^" p {print}' | nl -ba
    echo ""
    printf "Enter snapshot number to destroy (or q to cancel): "
    read -r selection
    case "$selection" in
        q|Q) return 0 ;;
        *[!0-9]*|'') log_error "Invalid selection."; return 1 ;;
    esac

    snapshot=$(printf '%s\n' "$pool_snaps" | sed -n "${selection}p")
    if [ -z "$snapshot" ]; then
        log_error "Invalid selection."
        return 1
    fi

    snap_tag=${snapshot#*@}
    descendant_count=$(zfs list -H -t snapshot -o name 2>/dev/null | grep -c "@${snap_tag}$" || true)

    local total_used
    total_used=$(zfs list -H -p -t snapshot -o name,used 2>/dev/null | awk -v tag="@${snap_tag}$" '$1 ~ tag {s+=$2} END{print s+0}')

    if [ "$DRY_RUN" -eq 1 ]; then
        echo ""
        log_info "[DRY-RUN] Would destroy snapshot set: $snapshot"
        echo "Snapshots that would be destroyed:"
        zfs list -H -t snapshot -o name,used 2>/dev/null | awk -v tag="@${snap_tag}$" '$1 ~ tag {print "  " $0}'
        log_info "[DRY-RUN] Approximately $descendant_count snapshot(s) would be destroyed."
        log_info "[DRY-RUN] Approximate space that would be freed: $(format_size "$total_used")"
        log_info "[DRY-RUN] No changes made."
        echo ""
        return 0
    fi

    echo ""
    log_warning "Selected snapshot set: $snapshot"
    echo "This will remove approximately $descendant_count snapshots tagged '@$snap_tag'."
    echo ""
    printf "Type DELETE to permanently destroy this snapshot set: "
    read -r confirm1
    if [ "$confirm1" != "DELETE" ]; then
        log_info "Operation cancelled."
        return 0
    fi

    printf "Type YES to confirm deletion of '$snap_tag': "
    read -r confirm2
    if [ "$confirm2" != "YES" ]; then
        log_info "Operation cancelled."
        return 0
    fi

    echo ""
    log_info "Destroying recursive snapshot set: $snapshot"
    error_msg=$(zfs destroy -r "$snapshot" 2>&1)
    if [ $? -eq 0 ]; then
        log_success "Snapshot set '$snapshot' destroyed."
    else
        log_error "Failed to destroy snapshot set '$snapshot':"
        log_error "$error_msg"
        return 1
    fi
    echo ""
}

show_disk_information() {
    show_header
    log_info "ZFS pool and disk-space information"
    echo ""

    echo "Pool health and capacity:"
    zpool list "$POOL_NAME"
    echo ""

    echo "Pool properties:"
    zpool get -H -o property,value size,allocated,free,capacity,fragmentation,health "$POOL_NAME" 2>/dev/null || true
    echo ""

    echo "ZFS space accounting for pool root:"
    zfs get -H -o property,value used,available,referenced,usedbysnapshots,usedbydataset,usedbychildren,usedbyrefreservation "$POOL_NAME" 2>/dev/null || true
    echo ""

    echo "Largest datasets under $POOL_NAME:"
    zfs list -r -o name,used,avail,refer,mountpoint "$POOL_NAME" 2>/dev/null | head -30
    echo ""

    echo "Snapshot space summary:"
    local pool_snap_count all_snap_count
    pool_snap_count=$(pool_snapshot_count)
    all_snap_count=$(zfs list -H -t snapshot -o name 2>/dev/null | grep -c "^${POOL_NAME}" || true)
    echo "  Pool-level recursive snapshot sets: $pool_snap_count"
    echo "  All snapshots in this pool:          $all_snap_count"
    echo ""
    echo "Top 15 snapshots by retained space (USED):"
    zfs list -H -p -t snapshot -o name,used -s used 2>/dev/null | awk -v p="^${POOL_NAME}" '$1 ~ p {print}' | tail -15 | while read -r snap_name snap_used; do
        printf "  %-65s %s\n" "$snap_name" "$(format_size "$snap_used")"
    done
    echo ""

    echo "How to read this:"
    echo "  - zpool ALLOC/FREE: physical pool space currently allocated/free."
    echo "  - usedbysnapshots: blocks retained only because snapshots still reference them."
    echo "  - A snapshot USED value is per-snapshot retained-block space, not its full"
    echo "    restore capacity. A small or 0B value is normal immediately after creation."
    echo ""
}

full_zfs_rollback() {
    show_header
    log_warning "Full ZFS rollback (DESTRUCTIVE)"
    echo ""
    echo "This rolls back every dataset in pool '$POOL_NAME' to a selected recursive"
    echo "pool-level snapshot. It is a last-resort recovery path."
    echo ""
    log_warning "It can permanently remove all changes made after that snapshot, including:"
    echo "  - Boot environments and snapshots created later"
    echo "  - Package, system, and configuration changes"
    echo "  - Logs, state, and other changes in datasets under the pool"
    echo ""
    echo "Preferred recovery for a failed upgrade: Option 3, activate a known-good BE."
    echo ""

    local pool_snaps snapshot snap_tag confirm1 confirm2 error_msg
    pool_snaps=$(pool_snapshot_list)
    if [ -z "$pool_snaps" ]; then
        log_error "No pool-level snapshots exist. Use Option 8 to create one first."
        return 1
    fi

    echo "Eligible pool-level snapshots:"
    echo ""
    printf '%s\n' "$pool_snaps" | nl -ba
    echo ""
    echo "Note: Small USED sizes are normal. USED is retained changed-block space,"
    echo "not the amount of data recoverable from the recursive snapshot set."
    echo ""

    printf "Enter snapshot number to roll back to (or q to cancel): "
    read -r selection
    case "$selection" in
        q|Q) return 0 ;;
        *[!0-9]*|'') log_error "Invalid selection."; return 1 ;;
    esac

    snapshot=$(printf '%s\n' "$pool_snaps" | sed -n "${selection}p")
    if [ -z "$snapshot" ]; then
        log_error "Invalid selection."
        return 1
    fi

    snap_tag=${snapshot#*@}
    echo ""
    log_warning "Selected rollback point: $snapshot"
    log_warning "The command to be executed is: zfs rollback -r $snapshot"
    echo ""

    if [ "$DRY_RUN" -eq 1 ]; then
        log_info "[DRY-RUN] Would roll back the following datasets to '$snapshot':"
        zfs list -H -t snapshot -o name 2>/dev/null | grep "@${snap_tag}$" | sed 's/^/  /'
        log_info "[DRY-RUN] Would run: zfs rollback -r $snapshot"
        log_info "[DRY-RUN] No changes made."
        echo ""
        return 0
    fi

    printf "Type ROLLBACK to continue: "
    read -r confirm1
    if [ "$confirm1" != "ROLLBACK" ]; then
        log_info "Operation cancelled."
        return 0
    fi

    printf "Type YES to permanently roll back to '$snap_tag': "
    read -r confirm2
    if [ "$confirm2" != "YES" ]; then
        log_info "Operation cancelled."
        return 0
    fi

    echo ""
    log_info "Performing rollback..."
    error_msg=$(zfs rollback -r "$snapshot" 2>&1)
    if [ $? -eq 0 ]; then
        log_success "Rollback completed. Reboot now before relying on the restored system."
        echo "  reboot"
    else
        log_error "Rollback failed:"
        log_error "$error_msg"
        log_error "ZFS may require dependent snapshots to be removed."
        log_error "Do not retry with -R unless you have reviewed exactly what will be destroyed."
        return 1
    fi
    echo ""
}

prepare_for_upgrade() {
    show_header
    log_info "One-click pre-upgrade checklist"
    echo ""
    echo "This automates the full pre-upgrade workflow:"
    echo "  1. Create a boot environment"
    echo "  2. Create a recursive pool snapshot"
    echo "  3. Back up /cf/conf/config.xml"
    echo "  4. Verify everything is in place"
    echo ""

    local be_name snap_name mount_path overall_ok=1

    if ! check_disk_space; then
        log_warning "Proceeding despite low disk space. This operation may fail."
    fi

    be_name="pre-upgrade-$(date +%Y%m%d-%H%M%S)"
    snap_name="$be_name"

    if ! validate_be_name "$be_name"; then
        return 1
    fi

    if be_exists "$be_name"; then
        log_error "Boot environment '$be_name' already exists. Aborting checklist."
        return 1
    fi

    log_info "Step 1/4: Backing up configuration..."
    backup_config || overall_ok=0

    log_info "Step 2/4: Creating boot environment '$be_name'..."
    if ! bectl create "$be_name"; then
        log_error "Failed to create boot environment (bectl create failed)."
        return 1
    fi

    if [ ! -d /cf ]; then
        log_error "/cf does not exist. Removing incomplete BE '$be_name'."
        bectl destroy "$be_name" >/dev/null 2>&1
        return 1
    fi

    mount_path=$(bectl mount "$be_name" 2>&1)
    if [ -z "$mount_path" ] || [ ! -d "$mount_path" ]; then
        log_error "Failed to mount boot environment '$be_name'."
        bectl destroy "$be_name" >/dev/null 2>&1
        return 1
    fi

    if ! cp -R /cf "$mount_path/"; then
        log_error "Failed to copy /cf. Unmounting and destroying incomplete BE."
        bectl umount "$be_name" >/dev/null 2>&1 || true
        bectl destroy "$be_name" >/dev/null 2>&1
        return 1
    fi

    local config_ok=1
    if [ ! -f "$mount_path/conf/config.xml" ]; then
        log_warning "conf/config.xml not found in new BE mount."
        config_ok=0
        overall_ok=0
    fi

    if ! bectl umount "$be_name"; then
        log_error "Failed to unmount '$be_name' from $mount_path."
        overall_ok=0
    fi
    log_success "Boot environment '$be_name' created."

    echo ""
    log_info "Step 3/4: Creating recursive pool snapshot '$snap_name'..."
    if create_pool_snapshot_named "$snap_name"; then
        :
    else
        log_warning "Snapshot creation reported an issue; see messages above."
        overall_ok=0
    fi

    echo ""
    log_info "Step 4/4: Verifying results..."
    local be_ok=0 snap_ok=0
    if be_exists "$be_name"; then
        be_ok=1
        log_success "Boot environment '$be_name' is present."
    else
        log_error "Boot environment '$be_name' was not found."
        overall_ok=0
    fi

    if zfs list -H -t snapshot -o name 2>/dev/null | grep -Fx "${POOL_NAME}@${snap_name}" >/dev/null 2>&1; then
        snap_ok=1
        log_success "Pool snapshot '${POOL_NAME}@${snap_name}' is present."
    else
        log_error "Pool snapshot '${POOL_NAME}@${snap_name}' was not found."
        overall_ok=0
    fi

    if mount | grep -q "on / "; then
        log_success "Root filesystem mount looks sane."
    else
        log_warning "Could not confirm root filesystem mount state."
    fi

    echo ""
    echo "========================================"
    echo "  Pre-Upgrade Checklist Summary"
    echo "========================================"
    echo "  Boot environment:  $be_name  $([ "$be_ok" -eq 1 ] && echo "OK" || echo "FAILED")"
    echo "  Pool snapshot:      ${POOL_NAME}@${snap_name}  $([ "$snap_ok" -eq 1 ] && echo "OK" || echo "FAILED")"
    echo "  Config backup:      $([ "$overall_ok" -eq 1 ] && echo "OK" || echo "See warnings above")"
    echo "  config.xml in BE:   $([ "$config_ok" -eq 1 ] && echo "OK" || echo "MISSING")"
    echo ""
    echo "Next steps:"
    echo "  1. Export a pfSense configuration backup from:"
    echo "       Diagnostics > Backup & Restore > Backup Configuration."
    echo "  2. Proceed with the upgrade while booted into the current BE."
    echo "  3. If the upgrade fails but pfSense still boots, activate '$be_name'"
    echo "     (Option 3) and reboot."
    echo "  4. If the system is badly broken, use Option 7 with"
    echo "     '${POOL_NAME}@${snap_name}' as a last resort."
    echo ""

    if [ "$overall_ok" -eq 1 ]; then
        log_success "Pre-upgrade checklist completed successfully."
    else
        log_warning "Pre-upgrade checklist completed with warnings. Review the output above."
    fi
    echo ""
}

generate_report() {
    show_header
    log_info "BE / snapshot summary report"
    echo ""

    local export_choice export_file
    printf "Export this report to a file? (y/n): "
    read -r export_choice

    {
        echo "pfSense Boot Environment Manager - Summary Report"
        echo "Generated: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "Pool: $POOL_NAME"
        echo ""

        echo "== Boot Environments =="
        local be_list
        be_list=$(bectl list -H 2>/dev/null)
        if [ -z "$be_list" ]; then
            echo "  (none found)"
        else
            printf '%s\n' "$be_list" | while read -r name active mountpoint space created rest; do
                [ -z "$name" ] && continue
                local ds_name used_bytes creation_epoch last_access
                ds_name="${POOL_NAME}/ROOT/${name}"
                used_bytes=$(zfs get -Hp -o value used "$ds_name" 2>/dev/null)
                creation_epoch=$(zfs get -Hp -o value creation "$ds_name" 2>/dev/null)
                last_access=$(zfs get -H -o value atime "$ds_name" 2>/dev/null)
                echo "  Name:      $name"
                echo "    Active:      $active"
                echo "    Created:     $(date -r "${creation_epoch:-0}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "unknown")"
                echo "    Size:        $(format_size "${used_bytes:-0}")"
                echo "    atime prop:  ${last_access:-unknown}"
            done
        fi
        echo ""

        echo "== Snapshots =="
        local snap_list total_snap_used=0 oldest_snap="" newest_snap=""
        snap_list=$(zfs list -H -p -t snapshot -o name,used,creation -s creation 2>/dev/null | awk -v p="^${POOL_NAME}" '$1 ~ p {print}')
        if [ -z "$snap_list" ]; then
            echo "  (none found)"
        else
            printf '%s\n' "$snap_list" | while read -r name used creation; do
                [ -z "$name" ] && continue
                echo "  $name  size=$(format_size "$used")  created=$(date -r "$creation" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "unknown")"
            done
            total_snap_used=$(printf '%s\n' "$snap_list" | awk '{s+=$2} END{print s+0}')
            oldest_snap=$(printf '%s\n' "$snap_list" | head -1 | awk '{print $1}')
            newest_snap=$(printf '%s\n' "$snap_list" | tail -1 | awk '{print $1}')
            echo ""
            echo "  Total space retained by snapshots: $(format_size "$total_snap_used")"
            echo "  Oldest snapshot: ${oldest_snap:-n/a}"
            echo "  Newest snapshot: ${newest_snap:-n/a}"
        fi
        echo ""

        echo "== Boot Environment Age Range =="
        local be_creations oldest_be newest_be
        be_creations=$(printf '%s\n' "$be_list" | while read -r name rest; do
            [ -z "$name" ] && continue
            c=$(zfs get -Hp -o value creation "${POOL_NAME}/ROOT/${name}" 2>/dev/null)
            echo "$c $name"
        done | sort -n)
        if [ -n "$be_creations" ]; then
            oldest_be=$(printf '%s\n' "$be_creations" | head -1 | awk '{print $2}')
            newest_be=$(printf '%s\n' "$be_creations" | tail -1 | awk '{print $2}')
            echo "  Oldest BE: ${oldest_be:-n/a}"
            echo "  Newest BE: ${newest_be:-n/a}"
        else
            echo "  (no boot environments found)"
        fi
        echo ""

        echo "== Disk Usage =="
        zpool list "$POOL_NAME" 2>/dev/null
        echo ""
        echo "  Used by snapshots (pool-wide): $(format_size "$(zfs get -Hp -o value usedbysnapshots "$POOL_NAME" 2>/dev/null)")"
        echo ""
        if [ -f "$LOG_FILE" ]; then
            echo "== Disk Usage Trend (from log file) =="
            grep -c "Low disk space" "$LOG_FILE" 2>/dev/null | xargs -I{} echo "  Low disk space warnings recorded in log: {}"
        fi
    } > /tmp/pfsense-be-report.$$ 2>/dev/null

    cat /tmp/pfsense-be-report.$$

    if [ "$export_choice" = "y" ] || [ "$export_choice" = "Y" ]; then
        export_file="/root/pfsense-be-report-$(date +%Y%m%d-%H%M%S).txt"
        if cp /tmp/pfsense-be-report.$$ "$export_file" 2>/dev/null; then
            log_success "Report exported to: $export_file"
        else
            log_error "Failed to export report to: $export_file"
        fi
    fi
    rm -f /tmp/pfsense-be-report.$$
    echo ""
}

show_help() {
    show_header
    echo "pfSense CE Boot Environment Manager - Help"
    echo ""
    echo "IMPORTANT CONCEPTS"
    echo "  Boot Environment (BE): A bootable clone of the pfSense root filesystem."
    echo "  Snapshot: A read-only point-in-time ZFS recovery point."
    echo ""
    echo "NORMAL PRE-UPGRADE WORKFLOW"
    echo "  1. Select Option 2: Create new boot environment."
    echo "  2. Use a meaningful name, e.g. pre-290-upg-YYYYMMDD."
    echo "  3. Choose 'y' when asked to create a recursive pool snapshot."
    echo "  4. Export a pfSense configuration backup from:"
    echo "       Diagnostics > Backup & Restore > Backup Configuration."
    echo "  5. Perform the upgrade while booted into the current BE."
    echo ""
    echo "IF THE UPGRADE FAILS BUT PFSENSE STILL BOOTS"
    echo "  1. Select Option 3: Activate/select boot environment."
    echo "  2. Select the pre-upgrade BE."
    echo "  3. Reboot."
    echo ""
    echo "IF THE SYSTEM IS BADLY BROKEN OR BE ROLLBACK IS NOT ENOUGH"
    echo "  1. Use Option 7: Full ZFS rollback."
    echo "  2. Select a pool-level snapshot, shown as:"
    echo "       ${POOL_NAME}@snapshot-name"
    echo "  3. Confirm carefully, then reboot."
    echo ""
    echo "DESTROYING SNAPSHOTS"
    echo "  Option 9 deletes a pool-level snapshot recursively, including matching"
    echo "  descendant snapshots with the same tag. Do not delete your only recovery"
    echo "  point. Deleting a snapshot usually frees blocks retained by that snapshot."
    echo ""
    echo "DISK INFORMATION"
    echo "  Option 10 shows pool capacity, health, ZFS used-by-snapshot accounting,"
    echo "  datasets, and the snapshots retaining the most space."
    echo ""
    echo "WARNING ABOUT FULL ZFS ROLLBACK"
    echo "  Full rollback is destructive. It reverts every dataset in the"
    echo "  ${POOL_NAME} pool and removes changes made after the selected snapshot."
    echo "  Prefer BE activation whenever possible."
    echo ""
    echo "SNAPSHOT SIZE NOTE"
    echo "  A pool-level snapshot can show USED = 0B or a very small value."
    echo "  That is normal: ZFS snapshots consume additional space only as blocks"
    echo "  change. The matching recursive child snapshots hold the restore point."
    echo ""
    echo "CONFIGURATION ON THIS INSTALL"
    echo "  pfSense runtime configuration is held under /cf/conf."
    echo "  When creating a CE boot environment, this tool copies /cf into the"
    echo "  new BE, resulting in conf/config.xml within the mounted BE."
    echo ""
    echo "LOGGING"
    echo "  All operations are logged to: $LOG_FILE"
    echo ""
    echo "CLEANUP"
    echo "  Do not delete the only known-good BE or only pre-upgrade snapshot."
    echo "  Keep at least one proven-good BE and an external pfSense config backup."
    echo ""
    echo "ONE-CLICK PRE-UPGRADE CHECKLIST"
    echo "  Option 11 automates the full pre-upgrade workflow: create a BE, create"
    echo "  a pool snapshot, back up config.xml, verify everything, and show a"
    echo "  summary with next steps."
    echo ""
    echo "SNAPSHOT RETENTION POLICY"
    echo "  Option 12 configures automatic cleanup of old pool-level snapshot sets,"
    echo "  either by keeping the last N sets or deleting sets older than X days."
    echo "  Cleanup runs automatically whenever a new snapshot is created."
    echo "  Policy is stored in: $RETENTION_CONF_FILE"
    echo ""
    echo "SUMMARY REPORT"
    echo "  Option 13 generates a report of all BEs and snapshots, including sizes,"
    echo "  creation dates, and total space retained by snapshots, with an option"
    echo "  to export it to a file."
    echo ""
    echo "CONFIG BACKUPS"
    echo "  A timestamped copy of /cf/conf/config.xml is saved to"
    echo "  $CONFIG_BACKUP_DIR before creating a BE or a snapshot."
    echo ""
    echo "DRY-RUN MODE"
    echo "  Run this script with --dry-run to preview destructive operations"
    echo "  (destroy BE, destroy snapshot, full rollback) without making changes."
    echo ""
    echo "COLOR OUTPUT"
    echo "  Output is colorized automatically on an interactive terminal. Set"
    echo "  PFSENSE_BE_NO_COLOR to any non-empty value to disable colors."
    echo ""
}

show_menu() {
    show_header
    show_current_be
    if [ "$DRY_RUN" -eq 1 ]; then
        log_warning "DRY-RUN MODE is active: destructive operations will only be previewed."
        echo ""
    fi
    echo "Menu:"
    echo "  1) List all boot environments"
    echo "  2) Create new boot environment (pre-upgrade)"
    echo "  3) Activate/select boot environment"
    echo "  4) Destroy boot environment"
    echo "  5) View boot environment details"
    echo "  6) Show ZFS snapshots"
    echo "  7) Full ZFS rollback (DESTRUCTIVE)"
    echo "  8) Create pool-level ZFS snapshot"
    echo "  9) Destroy pool-level ZFS snapshot (DESTRUCTIVE)"
    echo " 10) Display disk and ZFS space information"
    echo " 11) One-click pre-upgrade checklist"
    echo " 12) Configure snapshot retention policy"
    echo " 13) Generate BE/snapshot summary report"
    echo " 14) Help: workflows and recovery guidance"
    echo " 15) Exit"
    echo ""
}

main() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --dry-run)
                DRY_RUN=1
                ;;
            *)
                log_error "Unknown argument: $1"
                exit 1
                ;;
        esac
        shift
    done

    if [ "$(id -u)" -ne 0 ]; then
        log_error "This script must be run as root."
        exit 1
    fi

    if ! command -v bectl >/dev/null 2>&1; then
        log_error "bectl was not found. This script requires a ZFS pfSense/FreeBSD installation."
        exit 1
    fi

    if ! command -v zfs >/dev/null 2>&1; then
        log_error "zfs was not found. This script requires ZFS."
        exit 1
    fi

    if ! command -v zpool >/dev/null 2>&1; then
        log_error "zpool was not found. This script requires ZFS."
        exit 1
    fi

    acquire_lock
    validate_pool

    log_info "pfsense-be-manager started"
    if [ "$DRY_RUN" -eq 1 ]; then
        log_warning "Running in --dry-run mode. Destructive operations will only be previewed."
    fi

    while true; do
        show_menu
        printf "Enter your choice [1-15]: "
        read -r choice

        case "$choice" in
            1) list_bes; pause ;;
            2) create_be; pause ;;
            3) activate_be; pause ;;
            4) destroy_be; pause ;;
            5) view_be_details; pause ;;
            6) show_snapshots; pause ;;
            7) full_zfs_rollback; pause ;;
            8) create_pool_snapshot; pause ;;
            9) destroy_pool_snapshot; pause ;;
            10) show_disk_information; pause ;;
            11) prepare_for_upgrade; pause ;;
            12) configure_retention_policy; pause ;;
            13) generate_report; pause ;;
            14) show_help; pause ;;
            15) log_info "pfsense-be-manager exiting normally"; exit 0 ;;
            *) log_error "Invalid choice. Enter a number between 1 and 15."; pause ;;
        esac
    done
}

main "$@"
