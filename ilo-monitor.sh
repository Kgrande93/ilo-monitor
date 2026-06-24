#!/bin/bash
# ============================================================
# iLO Monitor - Monitors HP iLO via IPMI and sends ntfy alerts
# Supports: iLO G9 (iLO 4)
# Checks: Temperatures, fans, PSU, SEL
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${SCRIPT_DIR}/config.env"
STATE_DIR="/var/lib/ilo-monitor"
LOG_FILE="/var/log/ilo-monitor.log"

if [[ ! -f "$CONFIG" ]]; then
    echo "ERROR: Config file not found: $CONFIG"
    exit 1
fi
source "$CONFIG"

mkdir -p "$STATE_DIR"

# ============================================================
# Helper functions
# ============================================================
log() {
    local LEVEL="$1"
    local MSG="$2"
    echo "$(date '+%Y-%m-%d %H:%M:%S') [$LEVEL] $MSG" >> "$LOG_FILE"
}

send_ntfy() {
    local MSG="$1"
    curl -s -X POST "${NTFY_URL}" \
        -d "$MSG" \
        -o /dev/null
}

check_cooldown() {
    local KEY="$1"
    local STATE_FILE="${STATE_DIR}/${KEY}.last"
    local NOW
    NOW=$(date +%s)

    if [[ -f "$STATE_FILE" ]]; then
        local LAST
        LAST=$(cat "$STATE_FILE")
        local DIFF=$(( NOW - LAST ))
        if [[ $DIFF -lt $ALERT_COOLDOWN ]]; then
            return 1
        fi
    fi
    echo "$NOW" > "$STATE_FILE"
    return 0
}

clear_cooldown() {
    local KEY="$1"
    rm -f "${STATE_DIR}/${KEY}.last"
}

# ============================================================
# SDR check G9 (iLO 4 - DL380 G9)
# Sensor names: Inlet Ambient, CPU, etc.
# ============================================================
check_sdr_g9() {
    local ILO_IP="$1"
    local ILO_USER="$2"
    local ILO_PASS="$3"
    local ILO_NAME="$4"

    local SDR_OUT
    SDR_OUT=$(ipmitool -I lanplus -H "$ILO_IP" -U "$ILO_USER" -P "$ILO_PASS" \
        -N 5 -R 2 sdr 2>/dev/null)

    if [[ -z "$SDR_OUT" ]]; then
        log "WARN" "[$ILO_NAME] SDR data empty - skipping sensor check"
        return
    fi

    while IFS= read -r LINE; do
        [[ "$LINE" =~ DutyCycle|Presence ]] && continue
        if echo "$LINE" | grep -qE "^0[1-9]|^1[0-9]|^2[0-9]|^Inlet|^CPU|^Ambient"; then
            local STATUS
            STATUS=$(echo "$LINE" | awk -F'|' '{print $3}' | xargs)
            local VALUE
            VALUE=$(echo "$LINE" | awk -F'|' '{print $2}' | xargs)
            local SENSOR
            SENSOR=$(echo "$LINE" | awk -F'|' '{print $1}' | xargs)

            if echo "$STATUS" | grep -qi "critical\|non-recoverable"; then
                local KEY
                KEY="g9_temp_$(echo "$SENSOR" | tr ' ' '_')"
                if check_cooldown "$KEY"; then
                    send_ntfy "[TEMP] Temperature alert - ${ILO_NAME}
Server: ${ILO_NAME}
Sensor: ${SENSOR}
Value: ${VALUE}
Status: ${STATUS}"
                    log "WARN" "[$ILO_NAME] Temperature alert: $SENSOR = $VALUE ($STATUS)"
                fi
            fi
        fi
    done <<< "$SDR_OUT"
}

# ============================================================
# SEL check - Shared across all iLOs
# ============================================================
check_sel() {
    local ILO_IP="$1"
    local ILO_USER="$2"
    local ILO_PASS="$3"
    local ILO_PROTO="$4"
    local ILO_NAME="$5"
    local SEL_KEY="$6"

    local SEL_FILE="${STATE_DIR}/${SEL_KEY}_sel_last_id"
    local LAST_ID=0
    [[ -f "$SEL_FILE" ]] && LAST_ID=$(cat "$SEL_FILE")

    local SEL_OUT
    SEL_OUT=$(ipmitool -I "$ILO_PROTO" -H "$ILO_IP" -U "$ILO_USER" -P "$ILO_PASS" \
        -N 5 -R 2 sel elist 2>/dev/null)

    if [[ -z "$SEL_OUT" ]]; then
        log "WARN" "[$ILO_NAME] SEL empty or unavailable"
        return
    fi

    local NEW_LAST_ID=0
    local ALERTS=""

    while IFS= read -r LINE; do
        local SEL_ID_HEX
        SEL_ID_HEX=$(echo "$LINE" | awk '{print $1}')
        local SEL_ID_DEC
        SEL_ID_DEC=$(printf "%d" "0x${SEL_ID_HEX}" 2>/dev/null) || continue

        [[ $SEL_ID_DEC -gt $NEW_LAST_ID ]] && NEW_LAST_ID=$SEL_ID_DEC
        [[ $SEL_ID_DEC -le $LAST_ID ]] && continue

        echo "$LINE" | grep -qi "System ACPI Power State" && continue
        echo "$LINE" | grep -qi "Drive Present Deasserted" && continue
        echo "$LINE" | grep -qi "Pre-Init" && continue
        echo "$LINE" | grep -qi "Drive Inserted" && continue

        if echo "$LINE" | grep -qiE "Fault|Fail|Assert|Error|Critical|Degraded|Array|Power Unit"; then
            ALERTS+="${LINE}\n"
        fi
    done <<< "$SEL_OUT"

    [[ $NEW_LAST_ID -gt $LAST_ID ]] && echo "$NEW_LAST_ID" > "$SEL_FILE"

    if [[ -n "$ALERTS" ]]; then
        send_ntfy "[SEL] SEL error - ${ILO_NAME}
Server: ${ILO_NAME}

$(echo -e "$ALERTS")"
        log "WARN" "[$ILO_NAME] New SEL events:\n${ALERTS}"
    fi
}

# ============================================================
# Main check per iLO
# ============================================================
check_ilo() {
    local ILO_IP="$1"
    local ILO_USER="$2"
    local ILO_PASS="$3"
    local ILO_PROTO="$4"
    local ILO_NAME="$5"
    local SDR_FUNC="$6"
    local SEL_KEY
    SEL_KEY=$(echo "$ILO_NAME" | tr ' ()' '_' | tr -s '_' | tr '[:upper:]' '[:lower:]')

    log "INFO" "[$ILO_NAME] Starting check"

    if ! ipmitool -I "$ILO_PROTO" -H "$ILO_IP" -U "$ILO_USER" -P "$ILO_PASS" \
            -N 5 -R 2 chassis status &>/dev/null; then

        log "WARN" "[$ILO_NAME] IPMI did not respond - waiting 60 sec and retrying..."
        sleep 60

        if ! ipmitool -I "$ILO_PROTO" -H "$ILO_IP" -U "$ILO_USER" -P "$ILO_PASS" \
                -N 5 -R 2 chassis status &>/dev/null; then

            local KEY="${SEL_KEY}_ipmi_down"
            if check_cooldown "$KEY"; then
                send_ntfy "[ERROR] iLO Monitor - No response
${ILO_NAME} (${ILO_IP})
No IPMI response after double-check - manual check required."
                log "ERROR" "[$ILO_NAME] No IPMI response after double-check"
            fi
            return
        else
            log "INFO" "[$ILO_NAME] IPMI OK on second attempt - transient hang, no alert sent"
            clear_cooldown "${SEL_KEY}_ipmi_down"
        fi
    else
        clear_cooldown "${SEL_KEY}_ipmi_down"
    fi

    "$SDR_FUNC" "$ILO_IP" "$ILO_USER" "$ILO_PASS" "$ILO_NAME"
    check_sel "$ILO_IP" "$ILO_USER" "$ILO_PASS" "$ILO_PROTO" "$ILO_NAME" "$SEL_KEY"

    log "INFO" "[$ILO_NAME] Check complete"
}

# ============================================================
# Special commands
# ============================================================
case "$1" in
    test)
        send_ntfy "[OK] iLO Monitor - Test
Ntfy integration is working!
Monitoring: ${ILO_G9_NAME}"
        echo "Test message sent."
        exit 0
        ;;
    sel)
        echo "=== Raw SEL - $ILO_G9_NAME ==="
        ipmitool -I lanplus -H "$ILO_G9_IP" -U "$ILO_G9_USER" -P "$ILO_G9_PASS" \
            -N 5 -R 2 sel elist 2>/dev/null | tail -40
        exit 0
        ;;
    sdr)
        echo "=== Raw SDR - $ILO_G9_NAME ==="
        ipmitool -I lanplus -H "$ILO_G9_IP" -U "$ILO_G9_USER" -P "$ILO_G9_PASS" \
            -N 5 -R 2 sdr 2>/dev/null
        exit 0
        ;;
    status)
        echo "=== Active state files ==="
        ls -la "$STATE_DIR/" 2>/dev/null || echo "(none)"
        echo ""
        echo "=== SEL markers ==="
        for f in "$STATE_DIR"/*_sel_last_id; do
            [[ -f "$f" ]] && echo "  $(basename "$f"): ID $(cat "$f")"
        done
        echo ""
        echo "=== Last 30 log lines ==="
        tail -30 "$LOG_FILE" 2>/dev/null || echo "(no log yet)"
        exit 0
        ;;
    reset-alerts)
        rm -f "${STATE_DIR}"/*.last
        echo "Alert cooldowns reset (SEL markers kept)."
        exit 0
        ;;
    reset-sel)
        rm -f "${STATE_DIR}"/*_sel_last_id
        echo "SEL markers reset - all historical events will be alerted on again."
        exit 0
        ;;
    help|--help|-h)
        echo "Usage: $0 [command]"
        echo ""
        echo "  (none)         Full check: SDR + SEL"
        echo "  test           Send test message to ntfy"
        echo "  sel            Show raw SEL"
        echo "  sdr            Show raw SDR"
        echo "  status         Show state files, SEL markers, and log"
        echo "  reset-alerts   Reset cooldown states"
        echo "  reset-sel      Reset SEL markers"
        echo "  help           This help"
        exit 0
        ;;
esac

# ============================================================
# Run iLO G9
# ============================================================
check_ilo "$ILO_G9_IP" "$ILO_G9_USER" "$ILO_G9_PASS" "lanplus" "$ILO_G9_NAME" "check_sdr_g9"

log "INFO" "Full check complete"
