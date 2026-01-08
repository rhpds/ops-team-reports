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
GITHUB_ORGS="${6:-rhpds}"
MONITORED_REPOS="${7:-}"  # Comma-separated list of repos to monitor for ALL PRs
MONITORED_BRANCHES="${8:-}"  # JSON array of branch configs to monitor for commits

mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/gather_github_$(date -u +%Y-%m-%dT%H-%M-%S).log"

log() {
    echo "[$(date -u +%Y-%m-%dT%H:%M:%S)] $1" | tee -a "$LOG_FILE"
}

log "Starting GitHub data gathering..."
log "Date range: $START_DATE to $END_DATE"
log "Users: $GITHUB_USERS"
log "Organizations: $GITHUB_ORGS"

# Verify required environment variables
if [[ -z "${GITHUB_TOKEN:-}" ]]; then
    log "ERROR: GITHUB_TOKEN must be set"
    echo '{"raw_text": "No GitHub data - missing token", "source": "github", "error": "missing_credentials"}' > "$OUTPUT_FILE"
    exit 1
fi

# Convert comma-separated users and orgs to arrays
IFS=',' read -ra USERS <<< "$GITHUB_USERS"
IFS=',' read -ra ORGS <<< "$GITHUB_ORGS"

# Build org query part
ORG_QUERY=""
for ORG in "${ORGS[@]}"; do
    if [[ -n "$ORG_QUERY" ]]; then
        ORG_QUERY="${ORG_QUERY} org:${ORG}"
    else
        ORG_QUERY="org:${ORG}"
    fi
done

# Collect all PRs
ALL_PRS=""
TOTAL_PRS=0

for USER in "${USERS[@]}"; do
    log "Fetching PRs for user: $USER"

    # Search for PRs by author in the date range across all configured orgs
    SEARCH_QUERY="author:$USER created:${START_DATE}..${END_DATE} is:pr ${ORG_QUERY}"

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

log "Total PRs collected from users: $TOTAL_PRS"

# Collect PRs from monitored repos (regardless of author)
if [[ -n "$MONITORED_REPOS" ]]; then
    IFS=',' read -ra REPOS <<< "$MONITORED_REPOS"
    for REPO in "${REPOS[@]}"; do
        log "Fetching ALL PRs from monitored repo: $REPO"

        SEARCH_QUERY="repo:$REPO created:${START_DATE}..${END_DATE} is:pr"

        RESPONSE=$(curl -s -X GET \
            -H "Authorization: Bearer ${GITHUB_TOKEN}" \
            -H "Accept: application/vnd.github+json" \
            -H "X-GitHub-Api-Version: 2022-11-28" \
            "https://api.github.com/search/issues?q=$(echo "$SEARCH_QUERY" | jq -sRr @uri)&per_page=100" 2>&1)

        if echo "$RESPONSE" | jq empty 2>/dev/null; then
            PR_COUNT=$(echo "$RESPONSE" | jq '.total_count // 0')
            log "  Found $PR_COUNT PRs in $REPO"

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
            log "  WARNING: Failed to fetch PRs from $REPO"
        fi

        sleep 1
    done
fi

# Collect commits from monitored branches
COMMIT_SUMMARY=""
TOTAL_COMMITS=0

if [[ -n "$MONITORED_BRANCHES" ]]; then
    BRANCH_COUNT=$(echo "$MONITORED_BRANCHES" | jq 'length')
    for ((i=0; i<$BRANCH_COUNT; i++)); do
        REPO=$(echo "$MONITORED_BRANCHES" | jq -r ".[$i].repo")
        BRANCH=$(echo "$MONITORED_BRANCHES" | jq -r ".[$i].branch")
        AUTHOR=$(echo "$MONITORED_BRANCHES" | jq -r ".[$i].author")

        log "Fetching commits from $REPO:$BRANCH by $AUTHOR"

        # Convert dates to ISO format for API
        START_ISO="${START_DATE}T00:00:00Z"
        END_ISO="${END_DATE}T23:59:59Z"

        # Fetch commits
        COMMITS=$(curl -s -X GET \
            -H "Authorization: Bearer ${GITHUB_TOKEN}" \
            -H "Accept: application/vnd.github+json" \
            -H "X-GitHub-Api-Version: 2022-11-28" \
            "https://api.github.com/repos/${REPO}/commits?sha=${BRANCH}&since=${START_ISO}&until=${END_ISO}&per_page=100" 2>&1)

        if echo "$COMMITS" | jq empty 2>/dev/null; then
            COMMIT_COUNT=$(echo "$COMMITS" | jq 'length')
            log "  Found $COMMIT_COUNT commits"

            if [[ $COMMIT_COUNT -gt 0 ]]; then
                COMMITS_TEXT=$(echo "$COMMITS" | jq -r --arg author "$AUTHOR" '
                    map(select(.commit.author.name == $author)) |
                    "## Branch: '$BRANCH' ($REPO)\n" +
                    "Total commits by \($author): \(length)\n\n" +
                    (map(
                        "[\(.sha[0:7])](\(.html_url)) - \(.commit.message | split("\n")[0])\n" +
                        "  Date: \(.commit.author.date)\n"
                    ) | join("\n")) + "\n"
                ' 2>/dev/null)

                # Count commits by this author
                AUTHOR_COMMIT_COUNT=$(echo "$COMMITS" | jq --arg author "$AUTHOR" '[.[] | select(.commit.author.name == $author)] | length')

                if [[ $AUTHOR_COMMIT_COUNT -gt 0 ]]; then
                    COMMIT_SUMMARY="${COMMIT_SUMMARY}${COMMITS_TEXT}"
                    TOTAL_COMMITS=$((TOTAL_COMMITS + AUTHOR_COMMIT_COUNT))
                fi
            fi
        else
            log "  WARNING: Failed to fetch commits from $REPO:$BRANCH"
        fi

        sleep 1
    done
fi

log "Total items collected: $TOTAL_PRS PRs, $TOTAL_COMMITS commits"

# Create output JSON combining PRs and commits
COMBINED_TEXT="${ALL_PRS}"
if [[ -n "$COMMIT_SUMMARY" ]]; then
    COMBINED_TEXT="${COMBINED_TEXT}\n\n## Direct Branch Commits\n\n${COMMIT_SUMMARY}"
fi

jq -n \
    --arg text "$COMBINED_TEXT" \
    --arg pr_count "$TOTAL_PRS" \
    --arg commit_count "$TOTAL_COMMITS" \
    '{
        raw_text: $text,
        source: "github",
        pr_count: ($pr_count | tonumber),
        commit_count: ($commit_count | tonumber),
        date_range: {
            start: "'$START_DATE'",
            end: "'$END_DATE'"
        }
    }' > "$OUTPUT_FILE"

log "✅ GitHub data saved to $OUTPUT_FILE"
