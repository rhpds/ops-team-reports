#!/usr/bin/env bash
# Diagnostic script to extract JIRA user profiles from projects
set -Eeuo pipefail

JIRA_BASE_URL="${JIRA_BASE_URL:-https://issues.redhat.com}"
PROJECT="${1:-RHDPOPS}"

if [[ -z "${JIRA_API_TOKEN:-}" ]]; then
    echo "ERROR: JIRA_API_TOKEN must be set"
    exit 1
fi

echo "Querying recent issues in $PROJECT (last 60 days) to extract user profiles..."
echo ""

# Get recent issues from the project (last 60 days for better sample)
JQL="project = $PROJECT AND updated >= -60d ORDER BY updated DESC"

RESPONSE=$(curl -s -X GET \
    -H "Authorization: Bearer ${JIRA_API_TOKEN}" \
    -H "Content-Type: application/json" \
    --data-urlencode "jql=$JQL" \
    --data-urlencode "maxResults=100" \
    --data-urlencode "fields=assignee,reporter,created,updated" \
    "${JIRA_BASE_URL}/rest/api/2/search")

TOTAL=$(echo "$RESPONSE" | jq '.total // 0')
echo "Total issues found in last 60 days: $TOTAL"
echo ""

if [[ $TOTAL -gt 0 ]]; then
    echo "=== Unique Assignees ==="
    echo "$RESPONSE" | jq -r '.issues[].fields.assignee | select(. != null) | "\(.displayName)"' | sort -u
    echo ""
    
    echo "=== Unique Reporters ==="
    echo "$RESPONSE" | jq -r '.issues[].fields.reporter | select(. != null) | "\(.displayName)"' | sort -u
    echo ""
    
    echo "=== All Unique Users (Combined) ==="
    echo "$RESPONSE" | jq -r '.issues[] | [.fields.assignee, .fields.reporter] | .[] | select(. != null) | "\(.displayName)"' | sort -u
    echo ""
    
    echo "=== Sample Issues (first 5) ==="
    echo "$RESPONSE" | jq -r '.issues[0:5][] | "[\(.key)] Assignee: \(.fields.assignee.displayName // "none") | Reporter: \(.fields.reporter.displayName // "none") | Updated: \(.fields.updated)"'
else
    echo "No issues found in the last 60 days"
fi
