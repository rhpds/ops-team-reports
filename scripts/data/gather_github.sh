#!/usr/bin/env bash
# Gather GitHub PR data using REST API

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Arguments with macOS/Linux compatibility
if date -v-1d > /dev/null 2>&1; then
    # macOS/BSD date
    START_DATE="${1:-$(date -u -v-7d +%Y-%m-%d)}"
else
    # GNU date (Linux)
    START_DATE="${1:-$(date -u -d '7 days ago' +%Y-%m-%d)}"
fi
END_DATE="${2:-$(date -u +%Y-%m-%d)}"
OUTPUT_FILE="${3:-/tmp/github.json}"
LOG_DIR="${4:-logs}"
GITHUB_USERS="${5:-}"

mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/gather_github_$(date -u +%Y-%m-%dT%H-%M-%S).log"

log() {
    echo "[$(date -u +%Y-%m-%dT%H:%M:%S)] $1" | tee -a "$LOG_FILE"
}

log "Starting GitHub data gathering..."
log "Date range: $START_DATE to $END_DATE"
log "Users: $GITHUB_USERS"

# Verify required environment variables
if [[ -z "${GITHUB_TOKEN:-}" ]]; then
    log "ERROR: GITHUB_TOKEN must be set"
    echo '{"raw_text": "No GitHub data - missing token", "source": "github", "error": "missing_credentials"}' > "$OUTPUT_FILE"
    exit 1
fi

# Convert comma-separated users to array
IFS=',' read -ra USERS <<< "$GITHUB_USERS"

# Collect all PRs
ALL_PRS=""
TOTAL_PRS=0

for USER in "${USERS[@]}"; do
    log "Fetching PRs for user: $USER"

    # Search for PRs by author in the date range
    SEARCH_QUERY="author:$USER created:${START_DATE}..${END_DATE} is:pr org:rhpds"

    RESPONSE=$(curl -s -X GET \
        -H "Authorization: Bearer ${GITHUB_TOKEN}" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "https://api.github.com/search/issues?q=$(echo "$SEARCH_QUERY" | jq -sRr @uri)&per_page=100" 2>&1)

    if echo "$RESPONSE" | jq empty 2>/dev/null; then
        PR_COUNT=$(echo "$RESPONSE" | jq '.total_count // 0')
        log "  Found $PR_COUNT PRs for $USER"

        if [[ $PR_COUNT -gt 0 ]]; then
            PRS_TEXT=$(echo "$RESPONSE" | jq -r '
                .items[] |
                "[#\(.number)](\(.html_url)) - \(.title)\n" +
                "  Repo: \(.repository_url | split("/") | .[-1])\n" +
                "  Author: \(.user.login)\n" +
                "  State: \(.state)\n" +
                "  Created: \(.created_at)\n" +
                "  Updated: \(.updated_at)\n\n"
            ' 2>/dev/null)

            ALL_PRS="${ALL_PRS}${PRS_TEXT}"
            TOTAL_PRS=$((TOTAL_PRS + PR_COUNT))
        fi
    else
        log "  WARNING: Failed to fetch PRs for $USER"
        log "  Response: $RESPONSE"
    fi

    # Rate limiting: wait 1 second between requests
    sleep 1
done

log "Total PRs collected: $TOTAL_PRS"

# Create output JSON
jq -n \
    --arg text "$ALL_PRS" \
    --arg count "$TOTAL_PRS" \
    '{
        raw_text: $text,
        source: "github",
        pr_count: ($count | tonumber),
        date_range: {
            start: "'$START_DATE'",
            end: "'$END_DATE'"
        }
    }' > "$OUTPUT_FILE"

log "✅ GitHub data saved to $OUTPUT_FILE"
