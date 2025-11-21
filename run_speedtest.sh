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

# Retry configuration for the iperf3 test
MAX_TEST_RETRIES=3
TEST_RETRY_DELAY=10
TEST_PASSED=0

# 1. Determine the speed value to use
if [ "$DEBUG_MODE" = "true" ]; then
    # --- DEBUG MODE: Use fake data ---
    DOWNLOAD_RATE_MBPS="500.5"
    echo "$(date): DEBUG MODE ACTIVE. Using fake speed: ${DOWNLOAD_RATE_MBPS} Mbps" >> /var/log/iperf_monitor.log
    TEST_PASSED=1 # Mark as passed in debug mode
else
    # --- LIVE MODE: Run iperf3 test with RETRIES ---
    
    for attempt in $(seq 1 $MAX_TEST_RETRIES); do
        echo "$(date): Starting iperf3 test against ${IDNET_SERVER} (Attempt $attempt/$MAX_TEST_RETRIES)..." >> /var/log/iperf_monitor.log
        
        # FIX: Redirect STDERR (errors/warnings) to /dev/null to keep IPERF_OUTPUT clean JSON.
        IPERF_OUTPUT=$(iperf3 -c "$IDNET_SERVER" -R -P "$PARALLEL_STREAMS" -t "$TEST_DURATION" -J 2>/dev/null)
        EXIT_CODE=$?

        if [ $EXIT_CODE -eq 0 ]; then
            # --- CRITICAL FIX: Clean the JSON input before passing to jq ---
            # 1. Remove all newlines/carriage returns (tr -d '\n\r')
            # 2. Remove non-printable characters (tr -cd '[:print:]')
            # 3. Pipe to jq using the direct path.
            CLEAN_JSON=$(echo "$IPERF_OUTPUT" | tr -d '\n\r' | tr -cd '[:print:]')
            
            # Attempt to extract BPS using the direct path
            DOWNLOAD_RATE_BPS=$(echo "$CLEAN_JSON" | jq -r '.end.sum_received.bits_per_second' 2>/dev/null)
            
            # --- BEGIN ROBUST VALIDATION ---
            
            # Check if the extracted value is non-empty and starts with a digit (simple validation)
            if [ -n "$DOWNLOAD_RATE_BPS" ] && [[ "$DOWNLOAD_RATE_BPS" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
                
                # Check if the value is greater than zero (using 'bc' for float comparison)
                if echo "$DOWNLOAD_RATE_BPS > 0" | bc -l | grep -q 1; then
                    TEST_PASSED=1
                    echo "$(date): Test successful on attempt $attempt. BPS extracted: $DOWNLOAD_RATE_BPS" >> /var/log/iperf_monitor.log
                    break # Exit retry loop on success
                fi
            fi
            # --- END ROBUST VALIDATION ---
        fi

        echo "$(date): Test failed or reported zero speed. Raw exit code: $EXIT_CODE." >> /var/log/iperf_monitor.log
        
        if [ $attempt -lt $MAX_TEST_RETRIES ]; then
            echo "$(date): Waiting $TEST_RETRY_DELAY seconds before retrying..." >> /var/log/iperf_monitor.log
            sleep $TEST_RETRY_DELAY
        fi
    done

    # Final check after the loop to ensure a good value was found
    if [ "$TEST_PASSED" -eq 0 ]; then
        echo "$(date): FINAL FAILURE: iperf3 failed after all retries. Aborting script to avoid writing bad data." >> /var/log/iperf_monitor.log
        exit 1 # Exit the script
    fi
    
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
