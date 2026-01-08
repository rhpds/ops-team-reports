#!/usr/bin/env bash
# Diagnostic script to extract JIRA user profiles from projects
set -Eeuo pipefail

JIRA_BASE_URL="${JIRA_BASE_URL:-https://issues.redhat.com}"
PROJECT="${1:-RHDPOPS}"

if [[ -z "${JIRA_API_TOKEN:-}" ]]; then
    echo "ERROR: JIRA_API_TOKEN must be set"
    exit 1
fi

if [[ -z "${JIRA_EMAIL:-}" ]]; then
    echo "ERROR: JIRA_EMAIL must be set"
    exit 1
fi

# Create Basic Auth header (email:token encoded in base64)
# Use -w 0 on Linux to prevent line wrapping, ignore error on macOS
JIRA_AUTH=$(echo -n "${JIRA_EMAIL}:${JIRA_API_TOKEN}" | base64 -w 0 2>/dev/null || echo -n "${JIRA_EMAIL}:${JIRA_API_TOKEN}" | base64)

echo "Querying issues in $PROJECT..."
echo ""

# First, check if we can see ANY issues in the project at all
JQL_ALL="project = $PROJECT ORDER BY updated DESC"
RESPONSE_ALL=$(curl -s -X GET \
    -H "Authorization: Basic ${JIRA_AUTH}" \
    -H "Content-Type: application/json" \
    --data-urlencode "jql=$JQL_ALL" \
    --data-urlencode "maxResults=10" \
    --data-urlencode "fields=assignee,reporter,created,updated,key,summary" \
    "${JIRA_BASE_URL}/rest/api/2/search")

echo "DEBUG: Raw API response (first 500 chars):"
echo "$RESPONSE_ALL" | head -c 500
echo ""
echo ""

TOTAL_ALL=$(echo "$RESPONSE_ALL" | jq '.total // 0')
echo "Total issues in project (any time): $TOTAL_ALL"

# Check if there's an error in the response
if echo "$RESPONSE_ALL" | jq -e '.errorMessages' > /dev/null 2>&1; then
    echo "ERROR from JIRA API:"
    echo "$RESPONSE_ALL" | jq -r '.errorMessages[]'
    if echo "$RESPONSE_ALL" | jq -e '.errors' > /dev/null 2>&1; then
        echo "Error details:"
        echo "$RESPONSE_ALL" | jq '.errors'
    fi
fi

if [[ $TOTAL_ALL -gt 0 ]]; then
    echo ""
    echo "=== Sample Recent Issues (last 10) ==="
    echo "$RESPONSE_ALL" | jq -r '.issues[] | "[\(.key)] \(.fields.summary) | Assignee: \(.fields.assignee.displayName // "none") | Updated: \(.fields.updated[0:10])"'
    echo ""
fi

echo ""
echo "Now checking last 60 days specifically..."
echo ""

# Get recent issues from the project (last 60 days for better sample)
JQL="project = $PROJECT AND updated >= -60d ORDER BY updated DESC"

RESPONSE=$(curl -s -X GET \
    -H "Authorization: Basic ${JIRA_AUTH}" \
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
