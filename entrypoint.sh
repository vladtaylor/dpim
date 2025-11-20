#!/bin/bash

# Configuration for initial checks
DNS_SERVER="8.8.8.8"
IDNET_SERVER="speedtest.idnet.net"
MAX_RETRIES=5
RETRY_DELAY=10

# --- Function to check connectivity with retries ---
check_connection() {
    local host=$1
    local name=$2
    local command=$3
    local url=$4
    local retries=0

    echo "--- Checking connectivity to $name ($host) ---"
    
    while [ $retries -lt $MAX_RETRIES ]; do
        if [ "$command" = "ping" ]; then
            # Use ping for basic IP connectivity
            ping -c 1 -W 5 "$host" > /dev/null 2>&1
            exit_code=$?
        elif [ "$command" = "curl" ]; then
            # Use curl for HTTP/API service check
            # Checks for 200 (OK), 301/302 (Redirects), which often indicate a service is up
            curl -s -o /dev/null -w "%{http_code}" "$url" | grep -E '200|301|302' > /dev/null 2>&1
            exit_code=$?
        fi

        if [ $exit_code -eq 0 ]; then
            echo "$name check PASSED."
            return 0
        fi

        retries=$((retries + 1))
        echo "Check failed. Retrying in $RETRY_DELAY seconds... (Attempt $retries/$MAX_RETRIES)"
        sleep $RETRY_DELAY
    done

    echo "ERROR: Failed to establish connectivity to $name after $MAX_RETRIES attempts." >&2
    return 1
}

# Clear any previous environment variables file
rm -f /etc/container_environment

# Capture the environment variables passed via 'docker run -e'
# This is the FIX for cron not having environment variables
env | grep INFLUX_ >> /etc/container_environment
env | grep IDNET_ >> /etc/container_environment
env | grep HOST_TAG >> /etc/container_environment
env | grep DEBUG_MODE >> /etc/container_environment
env | grep TEST_ >> /etc/container_environment

# --- Perform Initial Connectivity Checks ---

# 1. Check DNS/Internet connectivity (Ping)
check_connection "$DNS_SERVER" "Google DNS" "ping"
if [ $? -ne 0 ]; then exit 1; fi

# 2. Check iPerf Server connectivity (Ping)
check_connection "$IDNET_SERVER" "IDNET Speedtest Server" "ping"
if [ $? -ne 0 ]; then exit 1; fi

# 3. Check InfluxDB API health (Curl - uses the INFLUX_HOST from env)
check_connection "${INFLUX_HOST}" "InfluxDB API" "curl" "${INFLUX_HOST}/health"
if [ $? -ne 0 ]; then exit 1; fi

echo "--- All initial checks passed. ---"

# Execute the cron daemon in the foreground and start tailing the log.
echo "Starting cron service and monitoring logs..."
cron -f & tail -f /var/log/iperf_monitor.log
