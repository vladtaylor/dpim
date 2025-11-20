# Use a lightweight Debian image as a base
FROM debian:bookworm-slim

# Set non-interactive mode for installation
ENV DEBIAN_FRONTEND=noninteractive

# Install necessary packages:
# 1. cron: To schedule the recurring task
# 2. iperf3: The network testing tool
# 3. jq: To parse the JSON output from iperf3
# 4. curl: To send the data to InfluxDB via HTTP
# 5. bash: Required for the script
# 6. bc: Basic Calculator for floating-point math
# 7. iputils-ping: **ADDED** Required for the 'ping' command in entrypoint.sh
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        cron \
        iperf3 \
        jq \
        curl \
        bash \
        bc \
        iputils-ping \
    && apt-get clean \
    && rm -rf /var/lib/apt-get/lists/*

# Set the working directory
WORKDIR /app

# Copy scripts and set permissions
COPY run_speedtest.sh /usr/local/bin/run_speedtest.sh
COPY crontab.txt /etc/cron.d/iperf-cronjob
COPY entrypoint.sh /usr/local/bin/entrypoint.sh

# Give execute permission to the scripts
RUN chmod +x /usr/local/bin/run_speedtest.sh \
    && chmod +x /usr/local/bin/entrypoint.sh \
    # Apply the crontab file and ensure permissions are correct
    && crontab /etc/cron.d/iperf-cronjob \
    # Create the log file location and set permissions
    && touch /var/log/iperf_monitor.log \
    && chmod 644 /var/log/iperf_monitor.log

# Command to run: Execute the custom entrypoint script.
CMD ["/usr/local/bin/entrypoint.sh"]
