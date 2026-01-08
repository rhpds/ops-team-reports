#!/usr/bin/env bash
# Gather Slack data from multiple channels using Claude CLI + Slack MCP
# Filters messages to only show activity from specified GitHub users

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Arguments
CHANNEL_IDS="${1:-}"  # Comma-separated channel IDs
GITHUB_USERS="${2:-}"  # Comma-separated GitHub usernames
OUTPUT_FILE="${3:-/tmp/slack.json}"
LOG_DIR="${4:-logs}"

mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/gather_slack_$(date -u +%Y-%m-%dT%H-%M-%S).log"

log() {
    echo "[$(date -u +%Y-%m-%dT%H:%M:%S)] $1" | tee -a "$LOG_FILE"
}

log "Starting Slack data gathering..."
log "Channels: $CHANNEL_IDS"
log "Filter by users: $GITHUB_USERS"

# Verify required environment variables
if [[ -z "${X_SLACK_WEB_TOKEN:-}" ]] || [[ -z "${X_SLACK_COOKIE_TOKEN:-}" ]]; then
    log "WARNING: Slack credentials not configured, skipping Slack data"
    echo '{"raw_text": "No Slack data - credentials not configured", "source": "slack", "error": "missing_credentials"}' > "$OUTPUT_FILE"
    exit 0  # Non-fatal - continue without Slack data
fi

# Setup Slack MCP server
log "Configuring Slack MCP server..."
claude mcp add slack-remote "https://slack-mcp.mcp-playground-poc.devshift.net/sse" \
    --transport sse \
    --header "X-Slack-Web-Token: $X_SLACK_WEB_TOKEN" \
    --header "X-Slack-Cookie-Token: $X_SLACK_COOKIE_TOKEN" \
    --header "User-Agent: MCP-Server/1.0" >/dev/null 2>&1 || {
        log "ERROR: Failed to setup Slack MCP server"
        echo '{"raw_text": "No Slack data - MCP setup failed", "source": "slack", "error": "mcp_setup_failed"}' > "$OUTPUT_FILE"
        exit 1
    }

# Convert comma-separated values to arrays
IFS=',' read -ra CHANNELS <<< "$CHANNEL_IDS"

# Calculate date range (last 7 days)
START_TS=$(date -u -d '7 days ago' +%s)
END_TS=$(date -u +%s)

log "Date range: $(date -u -d @$START_TS) to $(date -u -d @$END_TS)"

# Create temporary prompt file
PROMPT_FILE=$(mktemp)
cat > "$PROMPT_FILE" << EOF
Gather Slack messages from the following channels for the past 7 days:

Channels to monitor:
$(for ch in "${CHANNELS[@]}"; do echo "- $ch"; done)

Filter messages to only include activity from these GitHub users (match by display name or real name if possible):
$(echo "$GITHUB_USERS" | tr ',' '\n' | sed 's/^/- /')

For each relevant message:
1. Include the sender's name
2. Include the message text (summarize if very long)
3. Include timestamp
4. Include thread link if available
5. Note which channel it came from

Format as a readable text summary with links.
If a message has replies, include a note about the thread.

Time range: Last 7 days (timestamp range: $START_TS to $END_TS)

Return the data as formatted text suitable for report generation.
EOF

log "Executing Slack data gathering via Claude..."

# Execute via Claude CLI with Slack MCP
SLACK_DATA=$(claude --mcp-server slack-remote < "$PROMPT_FILE" 2>&1 || echo "Error gathering Slack data")

rm -f "$PROMPT_FILE"

# Check if we got data
if [[ "$SLACK_DATA" == *"Error"* ]] || [[ -z "$SLACK_DATA" ]]; then
    log "WARNING: Failed to gather Slack data"
    echo '{"raw_text": "No Slack data available", "source": "slack", "error": "gathering_failed"}' > "$OUTPUT_FILE"
else
    log "✅ Slack data gathered successfully"

    # Create output JSON
    jq -n \
        --arg text "$SLACK_DATA" \
        --arg channels "$CHANNEL_IDS" \
        '{
            raw_text: $text,
            source: "slack",
            channels: $channels,
            date_range: {
                start_ts: '$START_TS',
                end_ts: '$END_TS'
            }
        }' > "$OUTPUT_FILE"
fi

log "✅ Slack data saved to $OUTPUT_FILE"
