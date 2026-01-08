#!/usr/bin/env bash
# Gather JIRA data using direct REST API (no MCP server needed)

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
OUTPUT_FILE="${3:-/tmp/jira.json}"
LOG_DIR="${4:-logs}"
JIRA_PROJECT="${5:-RHDPOPS}"
TEAM_MEMBERS="${6:-}"  # Comma-separated list of JIRA display names

mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/gather_jira_$(date -u +%Y-%m-%dT%H-%M-%S).log"

log() {
    echo "[$(date -u +%Y-%m-%dT%H:%M:%S)] $1" | tee -a "$LOG_FILE"
}

log "Starting JIRA data gathering..."
log "Project: $JIRA_PROJECT"
log "Date range: $START_DATE to $END_DATE"

# Verify required environment variables
if [[ -z "${JIRA_API_TOKEN:-}" ]]; then
    log "ERROR: JIRA_API_TOKEN must be set"
    echo '{"raw_text": "No JIRA data - missing credentials", "source": "jira", "error": "missing_credentials"}' > "$OUTPUT_FILE"
    exit 1
fi

JIRA_BASE_URL="${JIRA_BASE_URL:-https://issues.redhat.com}"

# Build team member filter if provided
TEAM_FILTER=""
if [[ -n "$TEAM_MEMBERS" ]]; then
    IFS=',' read -ra MEMBERS <<< "$TEAM_MEMBERS"
    MEMBER_CONDITIONS=""
    for MEMBER in "${MEMBERS[@]}"; do
        if [[ -n "$MEMBER_CONDITIONS" ]]; then
            MEMBER_CONDITIONS="$MEMBER_CONDITIONS OR assignee = \"$MEMBER\" OR reporter = \"$MEMBER\""
        else
            MEMBER_CONDITIONS="assignee = \"$MEMBER\" OR reporter = \"$MEMBER\""
        fi
    done
    if [[ -n "$MEMBER_CONDITIONS" ]]; then
        TEAM_FILTER=" AND ($MEMBER_CONDITIONS)"
    fi
fi

# JQL query for issues with any activity (created, updated, or resolved) in date range
JQL="project = $JIRA_PROJECT AND ((created >= '$START_DATE' AND created <= '$END_DATE') OR (updated >= '$START_DATE' AND updated <= '$END_DATE') OR (resolutiondate >= '$START_DATE' AND resolutiondate <= '$END_DATE'))${TEAM_FILTER} ORDER BY updated DESC"

log "Executing JQL: $JQL"

# Call JIRA REST API using Bearer token (Personal Access Token)
RESPONSE=$(curl -s -X GET \
    -H "Authorization: Bearer ${JIRA_API_TOKEN}" \
    -H "Content-Type: application/json" \
    --data-urlencode "jql=$JQL" \
    --data-urlencode "maxResults=100" \
    --data-urlencode "fields=summary,status,assignee,priority,updated,created,resolutiondate,description,comment" \
    "${JIRA_BASE_URL}/rest/api/2/search" 2>&1)

# Check if request was successful
if echo "$RESPONSE" | jq empty 2>/dev/null; then
    ISSUE_COUNT=$(echo "$RESPONSE" | jq '.total // 0')
    log "Found $ISSUE_COUNT issues"

    # Transform to simplified format
    ISSUES_TEXT=$(echo "$RESPONSE" | jq -r '
        .issues[] |
        "[\(.key)](https://issues.redhat.com/browse/\(.key)) - \(.fields.summary)\n" +
        "  Status: \(.fields.status.name)\n" +
        "  Assignee: \(.fields.assignee.displayName // "Unassigned")\n" +
        "  Priority: \(.fields.priority.name // "None")\n" +
        "  Created: \(.fields.created)\n" +
        "  Updated: \(.fields.updated)\n" +
        (if .fields.resolutiondate then "  Resolved: \(.fields.resolutiondate)\n" else "" end) +
        "  Description: \(.fields.description // "No description" | .[0:200])...\n"
    ' 2>/dev/null || echo "Error parsing JIRA response")

    # Create output JSON
    jq -n \
        --arg text "$ISSUES_TEXT" \
        --arg count "$ISSUE_COUNT" \
        '{
            raw_text: $text,
            source: "jira",
            issue_count: ($count | tonumber),
            project: "'$JIRA_PROJECT'",
            date_range: {
                start: "'$START_DATE'",
                end: "'$END_DATE'"
            }
        }' > "$OUTPUT_FILE"

    log "✅ JIRA data saved to $OUTPUT_FILE"
else
    log "ERROR: Failed to fetch JIRA data"
    log "Response: $RESPONSE"
    echo '{"raw_text": "No JIRA data - API error", "source": "jira", "error": "api_failure"}' > "$OUTPUT_FILE"
    exit 1
fi
