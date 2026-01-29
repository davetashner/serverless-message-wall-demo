#!/bin/sh
# Microservice entrypoint - logs based on SERVICE_NAME
# Each service has a unique log pattern for visual distinction in kubectl logs

set -e

SERVICE_NAME="${SERVICE_NAME:-unknown}"
LOG_INTERVAL="${LOG_INTERVAL:-30}"
POD_NAME="${HOSTNAME:-pod}"

# Counters and state
counter=0
uptime_start=$(date +%s)

log_message() {
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    echo "[$SERVICE_NAME] $timestamp - $1"
}

# Service-specific log generators
log_heartbeat() {
    counter=$((counter + 1))
    log_message "pulse #${counter} - all systems nominal"
}

log_ticker() {
    log_message "tick"
}

log_greeter() {
    greetings="Hello|Hi there|Greetings|Hey|Welcome|Good day"
    greeting=$(echo "$greetings" | tr '|' '\n' | shuf -n 1 2>/dev/null || echo "Hello")
    log_message "${greeting} from pod ${POD_NAME}!"
}

log_counter() {
    counter=$((counter + 1))
    log_message "count=${counter}"
}

log_weather() {
    conditions="sunny|cloudy|rainy|windy|foggy|clear"
    temps="68|72|75|65|70|78|82"
    condition=$(echo "$conditions" | tr '|' '\n' | shuf -n 1 2>/dev/null || echo "sunny")
    temp=$(echo "$temps" | tr '|' '\n' | shuf -n 1 2>/dev/null || echo "72")
    log_message "Current: ${condition}, ${temp}F"
}

log_quoter() {
    quotes="The best way to predict the future is to invent it|Simplicity is the ultimate sophistication|Done is better than perfect|Make it work, make it right, make it fast|First, solve the problem. Then, write the code"
    quote=$(echo "$quotes" | tr '|' '\n' | shuf -n 1 2>/dev/null || echo "Hello, World!")
    log_message "\"${quote}\""
}

log_pinger() {
    latency=$((RANDOM % 50 + 5))
    log_message "upstream check: ${latency}ms latency, status=ok"
}

log_auditor() {
    events="config_read|health_check|metrics_scrape|auth_verify|cache_hit"
    resources="settings|pods|services|secrets|configmaps"
    event=$(echo "$events" | tr '|' '\n' | shuf -n 1 2>/dev/null || echo "config_read")
    resource=$(echo "$resources" | tr '|' '\n' | shuf -n 1 2>/dev/null || echo "settings")
    log_message "event=${event} user=system resource=${resource}"
}

log_reporter() {
    now=$(date +%s)
    uptime_secs=$((now - uptime_start))
    uptime_mins=$((uptime_secs / 60))
    log_message "summary: 10 pods running, 0 alerts, uptime ${uptime_mins}m"
}

log_sentinel() {
    log_message "watchdog healthy - no anomalies detected"
}

log_unknown() {
    log_message "running (SERVICE_NAME not recognized)"
}

# Main loop
log_message "starting (interval=${LOG_INTERVAL}s)"

while true; do
    case "$SERVICE_NAME" in
        heartbeat) log_heartbeat ;;
        ticker)    log_ticker ;;
        greeter)   log_greeter ;;
        counter)   log_counter ;;
        weather)   log_weather ;;
        quoter)    log_quoter ;;
        pinger)    log_pinger ;;
        auditor)   log_auditor ;;
        reporter)  log_reporter ;;
        sentinel)  log_sentinel ;;
        *)         log_unknown ;;
    esac
    sleep "$LOG_INTERVAL"
done
