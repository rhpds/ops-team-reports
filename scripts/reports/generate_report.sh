#!/usr/bin/env bash
# Generate weekly report from collected data using Gemini AI

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

TEAM="${1:-rhpds}"
DATA_FILE="$PROJECT_ROOT/data/$TEAM/team_data_latest.json"

if [[ ! -f "$DATA_FILE" ]]; then
    echo "ERROR: Data file not found: $DATA_FILE"
    echo "Run: bash scripts/data/gather_all.sh $TEAM"
    exit 1
fi

REPORT_DIR="$PROJECT_ROOT/reports/$TEAM"
mkdir -p "$REPORT_DIR"

REPORT_MD_FILE="$REPORT_DIR/weekly_$(date -u +%Y-%m-%d).md"
REPORT_HTML_FILE="$REPORT_DIR/weekly_$(date -u +%Y-%m-%d).html"

echo "📋 Generating Weekly Report..."
echo "  Team: $TEAM"
echo "  Input: $DATA_FILE"
echo "  Output: $REPORT_HTML_FILE"

# Extract data from JSON
JIRA_TEXT=$(jq -r '.jira.raw_text // "No JIRA data"' "$DATA_FILE")
SLACK_TEXT=$(jq -r '.slack.raw_text // "No Slack data"' "$DATA_FILE")
GITHUB_TEXT=$(jq -r '.github.raw_text // "No GitHub data"' "$DATA_FILE")
WEEK_START=$(jq -r '.metadata.period_start' "$DATA_FILE")
WEEK_END=$(jq -r '.metadata.period_end' "$DATA_FILE")
TEAM_NAME=$(jq -r '.metadata.team' "$DATA_FILE")

# Create prompt file
PROMPT_FILE=$(mktemp)
cat > "$PROMPT_FILE" << EOF
You are generating a weekly team report for $TEAM_NAME covering $WEEK_START to $WEEK_END.

# DATA SOURCES

## JIRA Issues
$JIRA_TEXT

## Slack Activity
$SLACK_TEXT

## GitHub Pull Requests
$GITHUB_TEXT

# INSTRUCTIONS

Generate a comprehensive weekly report in Markdown format with the following sections:

1. **Executive Summary** (2-3 sentences)
   - Highlight the most important accomplishments and activities

2. **Key Accomplishments**
   - List major milestones, completed work, or significant progress
   - Include links to JIRA issues, PRs, etc.

3. **Team Activity**
   - Summarize JIRA progress (issues completed, in progress, blocked)
   - Summarize GitHub activity (PRs merged, under review)
   - Note any important Slack discussions or decisions

4. **Collaboration & Communication**
   - Highlight cross-team collaboration or important discussions
   - Note any blockers or issues that need attention

5. **Next Week Focus**
   - Based on the data, what are the likely priorities for next week?

# FORMAT GUIDELINES
- Use Markdown headers (##, ###)
- Use bullet points for lists
- Include hyperlinks where available
- Keep it professional but readable
- Be concise but informative
- If a data source has no meaningful data, briefly note it and move on

Generate the report now:
EOF

echo "  Calling Gemini AI to generate report..."

# Check for Gemini API key
if [[ -z "${GEMINI_API_KEY:-}" ]]; then
    echo "ERROR: GEMINI_API_KEY environment variable not set"
    rm -f "$PROMPT_FILE"
    exit 1
fi

# Generate report using Gemini API
PROMPT_TEXT=$(cat "$PROMPT_FILE")

# Escape the prompt text for JSON
PROMPT_JSON=$(jq -n --arg text "$PROMPT_TEXT" '$text')

# Call Gemini API (using gemini-2.5-flash for fast, cost-effective generation)
RESPONSE=$(curl -s -X POST \
    "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent" \
    -H "x-goog-api-key: ${GEMINI_API_KEY}" \
    -H "Content-Type: application/json" \
    -d "{
        \"contents\": [{
            \"parts\": [{
                \"text\": ${PROMPT_JSON}
            }]
        }]
    }")

# Check for API errors
if echo "$RESPONSE" | jq -e '.error' > /dev/null 2>&1; then
    echo "ERROR: Gemini API error:"
    echo "$RESPONSE" | jq '.error'
    rm -f "$PROMPT_FILE"
    exit 1
fi

# Extract the generated text from the response
echo "$RESPONSE" | jq -r '.candidates[0].content.parts[0].text // ""' > "$REPORT_MD_FILE"

rm -f "$PROMPT_FILE"

if [[ ! -f "$REPORT_MD_FILE" ]] || [[ ! -s "$REPORT_MD_FILE" ]]; then
    echo "ERROR: Failed to generate report - empty response"
    echo "API Response:"
    echo "$RESPONSE" | jq '.'
    exit 1
fi

echo "✅ Markdown report generated: $REPORT_MD_FILE"

# Convert to HTML with basic styling
cat > "$REPORT_HTML_FILE" << 'HTMLEOF'
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <title>Weekly Team Report</title>
    <style>
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen, Ubuntu, sans-serif;
            max-width: 900px;
            margin: 40px auto;
            padding: 20px;
            line-height: 1.6;
            color: #333;
        }
        h1 { color: #2c3e50; border-bottom: 3px solid #3498db; padding-bottom: 10px; }
        h2 { color: #34495e; margin-top: 30px; border-bottom: 2px solid #ecf0f1; padding-bottom: 5px; }
        h3 { color: #7f8c8d; }
        a { color: #3498db; text-decoration: none; }
        a:hover { text-decoration: underline; }
        code { background: #f4f4f4; padding: 2px 6px; border-radius: 3px; }
        pre { background: #f4f4f4; padding: 15px; border-radius: 5px; overflow-x: auto; }
        ul { padding-left: 25px; }
        li { margin: 8px 0; }
        .meta { color: #7f8c8d; font-size: 0.9em; margin-bottom: 20px; }
    </style>
</head>
<body>
HTMLEOF

# Add metadata
cat >> "$REPORT_HTML_FILE" << EOF
<div class="meta">
    <strong>Team:</strong> $TEAM_NAME<br>
    <strong>Period:</strong> $WEEK_START to $WEEK_END<br>
    <strong>Generated:</strong> $(date -u +"%Y-%m-%d %H:%M:%S UTC")
</div>
EOF

# Convert markdown to HTML (basic conversion)
# For better conversion, could use pandoc, but keeping dependencies minimal
python3 -c "
import markdown
import sys

with open('$REPORT_MD_FILE', 'r') as f:
    text = f.read()

html = markdown.markdown(text, extensions=['tables', 'fenced_code'])
print(html)
" >> "$REPORT_HTML_FILE" 2>/dev/null || {
    # Fallback: just wrap in <pre> if markdown module not available
    echo "<pre>" >> "$REPORT_HTML_FILE"
    cat "$REPORT_MD_FILE" >> "$REPORT_HTML_FILE"
    echo "</pre>" >> "$REPORT_HTML_FILE"
}

cat >> "$REPORT_HTML_FILE" << 'HTMLEOF'
</body>
</html>
HTMLEOF

echo "✅ HTML report generated: $REPORT_HTML_FILE"

# Create index.html as a copy of the latest report for GitHub Pages
INDEX_FILE="$REPORT_DIR/index.html"
cp "$REPORT_HTML_FILE" "$INDEX_FILE"
echo "✅ Index file created: $INDEX_FILE"

echo ""
echo "📊 Reports ready!"
echo "   Markdown: $REPORT_MD_FILE"
echo "   HTML:     $REPORT_HTML_FILE"
echo "   Index:    $INDEX_FILE"
