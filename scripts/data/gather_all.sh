#!/usr/bin/env bash
# Orchestrate gathering from all data sources (JIRA, Slack, GitHub)

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_ROOT"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m'

TEAM="${1:-rhpds}"
TIMESTAMP=$(date -u +%Y-%m-%dT%H-%M-%S)
OUTPUT_FILE="data/${TEAM}/team_data_${TIMESTAMP}.json"
mkdir -p "data/${TEAM}"

# Logging setup
LOG_DIR="logs"
mkdir -p "$LOG_DIR"
MAIN_LOG="$LOG_DIR/gather_all_${TIMESTAMP}.log"

log() {
    echo "[$(date -u +%Y-%m-%dT%H:%M:%S)] $1" | tee -a "$MAIN_LOG"
}

# Load team configuration from YAML
TEAM_CONFIG="config/teams/${TEAM}.yaml"
if [[ ! -f "$TEAM_CONFIG" ]]; then
    echo -e "${RED}ERROR: Team config not found: $TEAM_CONFIG${NC}"
    echo "Available team configs:"
    ls -1 config/teams/*.yaml 2>/dev/null || echo "  (none found)"
    exit 1
fi

# Check yq is installed
if ! command -v yq &> /dev/null; then
    echo -e "${RED}ERROR: yq is required but not installed.${NC}"
    echo "Install with: brew install yq"
    exit 1
fi

# Parse team config using yq
TEAM_KEY=$(yq -r '.key' "$TEAM_CONFIG")
TEAM_DISPLAY_NAME=$(yq -r '.display_name' "$TEAM_CONFIG")
GITHUB_USERNAMES=$(yq -r '.selectors.github.usernames | join(",")' "$TEAM_CONFIG")
GITHUB_ORGS=$(yq -r '.selectors.github.organizations | join(",")' "$TEAM_CONFIG")
JIRA_BASE_URL=$(yq -r '.selectors.jira.base_url // "https://issues.redhat.com"' "$TEAM_CONFIG")
SLACK_CHANNELS=$(yq -r '.selectors.slack.channel_ids | join(",")' "$TEAM_CONFIG")

# Get all JIRA project keys
JIRA_PROJECTS=$(yq -r '.selectors.jira.projects[] | .key' "$TEAM_CONFIG" | paste -sd "," -)

log "Loaded config for team: $TEAM_KEY ($TEAM_DISPLAY_NAME)"
log "GitHub usernames: $GITHUB_USERNAMES"
log "GitHub organizations: $GITHUB_ORGS"
log "JIRA projects: $JIRA_PROJECTS"
log "Slack channels: $SLACK_CHANNELS"

echo -e "${CYAN}╔═══════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║   Complete Data Gathering (All Sources)                   ║${NC}"
echo -e "${CYAN}╚═══════════════════════════════════════════════════════════╝${NC}"
echo ""

WEEK_END=$(date -u +"%Y-%m-%d")
# macOS compatible date command (use -v instead of -d)
if date -v-1d > /dev/null 2>&1; then
    # macOS/BSD date
    WEEK_START=$(date -u -v-7d +"%Y-%m-%d")
else
    # GNU date (Linux)
    WEEK_START=$(date -u -d "7 days ago" +"%Y-%m-%d")
fi
echo -e "${BLUE}Team: ${TEAM}${NC}"
echo -e "${BLUE}Period: ${WEEK_START} to ${WEEK_END}${NC}"
echo ""

log "Data gathering started for team $TEAM, period $WEEK_START to $WEEK_END"

# Temp files
JIRA_FILE="/tmp/jira_${TIMESTAMP}.json"
SLACK_FILE="/tmp/slack_${TIMESTAMP}.json"
GITHUB_FILE="/tmp/github_${TIMESTAMP}.json"

# 1. JIRA (Multiple Projects)
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}█ 1/3: Gathering JIRA Data                                 █${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
export JIRA_BASE_URL

# Loop through each JIRA project and gather data separately
TOTAL_JIRA_COUNT=0
PROJECT_COUNT=$(echo "$JIRA_PROJECTS" | tr ',' '\n' | wc -l | tr -d ' ')
PROJECT_INDEX=0

# Create array to hold project data
declare -a JIRA_PROJECT_DATA

for PROJECT_KEY in $(echo "$JIRA_PROJECTS" | tr ',' '\n'); do
    PROJECT_INDEX=$((PROJECT_INDEX + 1))
    JIRA_PROJECT_FILE="/tmp/jira_${PROJECT_KEY}_${TIMESTAMP}.json"

    echo "  [$PROJECT_INDEX/$PROJECT_COUNT] Fetching $PROJECT_KEY..."
    bash "$SCRIPT_DIR/gather_jira.sh" "$WEEK_START" "$WEEK_END" "$JIRA_PROJECT_FILE" "$LOG_DIR" "$PROJECT_KEY"

    PROJECT_COUNT_VAL=$(jq -r '.issue_count // 0' "$JIRA_PROJECT_FILE" 2>/dev/null || echo "0")
    TOTAL_JIRA_COUNT=$((TOTAL_JIRA_COUNT + PROJECT_COUNT_VAL))
    echo "    → $PROJECT_COUNT_VAL issues"

    # Store project data for later merging
    JIRA_PROJECT_DATA+=("$JIRA_PROJECT_FILE")
done

# Merge all project data into a single JIRA output
if [ ${#JIRA_PROJECT_DATA[@]} -eq 1 ]; then
    # Single project - just copy
    cp "${JIRA_PROJECT_DATA[0]}" "$JIRA_FILE"
else
    # Multiple projects - merge into structured format
    jq -n \
        --slurpfile projects <(cat "${JIRA_PROJECT_DATA[@]}") \
        '{
            raw_text: ($projects | map(.raw_text) | join("\n\n")),
            source: "jira",
            issue_count: ($projects | map(.issue_count) | add),
            projects: $projects,
            date_range: $projects[0].date_range
        }' > "$JIRA_FILE"
fi

echo "✅ JIRA: $TOTAL_JIRA_COUNT issues across $PROJECT_COUNT projects"
echo ""

# 2. SLACK
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}█ 2/3: Gathering Slack Data                                █${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
bash "$SCRIPT_DIR/gather_slack.sh" "$SLACK_CHANNELS" "$GITHUB_USERNAMES" "$SLACK_FILE" "$LOG_DIR"
echo "✅ Slack: Data collected"
echo ""

# 3. GITHUB
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}█ 3/3: Gathering GitHub Data                               █${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
bash "$SCRIPT_DIR/gather_github.sh" "$WEEK_START" "$WEEK_END" "$GITHUB_FILE" "$LOG_DIR" "$GITHUB_USERNAMES" "$GITHUB_ORGS"
GITHUB_COUNT=$(jq -r '.pr_count // 0' "$GITHUB_FILE" 2>/dev/null || echo "0")
echo "✅ GitHub: $GITHUB_COUNT PRs"
echo ""

# 4. MERGE ALL DATA
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}█ Merging All Data Sources                                 █${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

# Read the individual data files and merge them
JIRA_DATA=$(cat "$JIRA_FILE")
SLACK_DATA=$(cat "$SLACK_FILE")
GITHUB_DATA=$(cat "$GITHUB_FILE")

jq -n \
  --argjson jira "$JIRA_DATA" \
  --argjson slack "$SLACK_DATA" \
  --argjson github "$GITHUB_DATA" \
  --arg start "$WEEK_START" \
  --arg end "$WEEK_END" \
  --arg team "$TEAM_DISPLAY_NAME" \
  --arg team_key "$TEAM_KEY" \
  '{
    metadata: {
      team: $team,
      team_key: $team_key,
      generated_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ")),
      period_start: $start,
      period_end: $end,
      timeframe_days: 7,
      format: "raw_text"
    },
    jira: $jira,
    slack: $slack,
    github: $github
  }' > "$OUTPUT_FILE"

# Validate JSON
if ! jq empty "$OUTPUT_FILE" 2>/dev/null; then
    echo -e "${RED}❌ ERROR: Invalid JSON generated${NC}"
    exit 1
fi

# Create symlink
ln -sf "$(basename "$OUTPUT_FILE")" "data/${TEAM}/team_data_latest.json"

echo -e "${GREEN}✅ Data collection complete!${NC}"
echo ""
echo -e "${CYAN}╔═══════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║   Data Summary                                             ║${NC}"
echo -e "${CYAN}╚═══════════════════════════════════════════════════════════╝${NC}"
echo ""

echo -e "  ${BLUE}JIRA Issues:${NC}    ${GREEN}${TOTAL_JIRA_COUNT}${NC}"
echo -e "  ${BLUE}GitHub PRs:${NC}     ${GREEN}${GITHUB_COUNT}${NC}"
echo -e "  ${BLUE}Slack Channels:${NC} ${GREEN}5${NC}"
echo ""
echo -e "${GREEN}✅ Output:${NC} $OUTPUT_FILE"
echo -e "${GREEN}✅ Symlink:${NC} data/${TEAM}/team_data_latest.json"
echo ""

# Cleanup temp files
rm -f "$JIRA_FILE" "$SLACK_FILE" "$GITHUB_FILE"
# Clean up individual JIRA project files
for PROJECT_FILE in "${JIRA_PROJECT_DATA[@]}"; do
    rm -f "$PROJECT_FILE"
done

log "Data gathering complete"

echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}✅ Ready for report generation!${NC}"
echo -e "${BLUE}   Run: bash scripts/reports/generate_reports.sh${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
