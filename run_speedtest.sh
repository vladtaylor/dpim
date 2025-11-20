#!/bin/bash

# --- FIX: Load Environment Variables ---
# Cron's environment is minimal. This loads the variables captured by the entrypoint.
if [ -f /etc/container_environment ]; then
    source /etc/container_environment
fi
# ---------------------------------------

# --- Configuration (Pulled from Docker Environment Variables) ---
# Check if all necessary variables are set. We prioritize Token auth, but fall back to User/Pass.
if [ -z "$INFLUX_HOST" ] || [ -z "$INFLUX_BUCKET" ] || \
   ( [ -z "$INFLUX_TOKEN" ] && ( [ -z "$INFLUX_USER" ] || [ -z "$INFLUX_PASS" ] ) ); then
    echo "$(date): Error: Insufficient InfluxDB environment variables provided (Need Host/Bucket + Token OR User/Pass)." >> /var/log/iperf_monitor.log
    exit 1
fi

IDNET_SERVER="speedtest.idnet.net"
TEST_DURATION=10
PARALLEL_STREAMS=4

# 1. Determine the speed value to use
if [ "$DEBUG_MODE" = "true" ]; then
    # --- DEBUG MODE: Use fake data ---
    # Assign a static value for testing InfluxDB write integrity.
    DOWNLOAD_RATE_MBPS="500.5"
    echo "$(date): DEBUG MODE ACTIVE. Using fake speed: ${DOWNLOAD_RATE_MBPS} Mbps" >> /var/log/iperf_monitor.log
else
    # --- LIVE MODE: Run iperf3 test ---
    IPERF_OUTPUT=$(iperf3 -c "$IDNET_SERVER" -R -P "$PARALLEL_STREAMS" -t "$TEST_DURATION" -J)

    # Check for iperf3 error
    if [ $? -ne 0 ]; then
        echo "$(date): iperf3 download test failed with exit code $?. Skipping data write." >> /var/log/iperf_monitor.log
        exit 1
    fi

    # 2. Extract key metrics using 'jq'
    DOWNLOAD_RATE_BPS=$(echo "$IPERF_OUTPUT" | jq -r '.end.sum_received.bits_per_second')
    
    # Use 'bc' for floating point math: convert BPS to MBPS, maintaining 2 decimal places.
    DOWNLOAD_RATE_MBPS=$(echo "scale=2; $DOWNLOAD_RATE_BPS / 1000000" | bc)
fi

# 3. Create InfluxDB Line Protocol
HOST_TAG=${HOST_TAG:-"pi_server_docker"}
# Line Protocol Structure: measurement,tagset SPACE fieldset
LINE_PROTOCOL="network_speed,host=${HOST_TAG},direction=download speed_mbps=${DOWNLOAD_RATE_MBPS}"

# 4. Construct the CURL command (URL and Headers)
CURL_BASE_COMMAND="curl -s -w %{http_code} -X POST"
CURL_URL=""

if [ -n "$INFLUX_TOKEN" ]; then
    # --- Token Authentication (InfluxDB v2) ---
    CURL_URL="${INFLUX_HOST}/api/v2/write?org=${INFLUX_ORG}&bucket=${INFLUX_BUCKET}&precision=s"
    # Execute with Token header
    CURL_RESULT=$( ${CURL_BASE_COMMAND} "${CURL_URL}" -H "Authorization: Token ${INFLUX_TOKEN}" -H "Content-Type: text/plain; charset=utf-8" --data-binary "${LINE_PROTOCOL}" 2> /dev/null )
    
elif [ -z "$INFLUX_TOKEN" ] && [ -n "$INFLUX_USER" ]; then
    # --- Basic Authentication (InfluxDB v1.x) ---
    # Assumes v1.x if INFLUX_ORG is empty. INFLUX_BUCKET is used as the database name.
    CURL_URL="${INFLUX_HOST}/write?db=${INFLUX_BUCKET}&precision=s&u=${INFLUX_USER}&p=${INFLUX_PASS}"
    # Execute without special headers for V1.x
    CURL_RESULT=$( ${CURL_BASE_COMMAND} "${CURL_URL}" --data-binary "${LINE_PROTOCOL}" 2> /dev/null )
fi

# Check HTTP status code for success (204 is Success/No Content)
HTTP_CODE="$CURL_RESULT"

if [ "$HTTP_CODE" -eq "204" ]; then
    echo "$(date): Success. Download Speed: ${DOWNLOAD_RATE_MBPS} Mbps. InfluxDB HTTP Code: ${HTTP_CODE}" >> /var/log/iperf_monitor.log
else
    # For debugging non-204 codes, get the full response body
    # Run curl again to capture the error body.
    ERROR_BODY=$(curl -s -X POST "${CURL_URL}" --data-binary "${LINE_PROTOCOL}" 2>&1)
    
    echo "$(date): InfluxDB write FAILED. HTTP Code: ${HTTP_CODE}." >> /var/log/iperf_monitor.log
    echo "  Data: ${LINE_PROTOCOL}" >> /var/log/iperf_monitor.log
    echo "  Error Body: ${ERROR_BODY}" >> /var/log/iperf_monitor.log
fi
