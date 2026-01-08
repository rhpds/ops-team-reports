# RHPDS Operations Team Weekly Reports

Automated weekly team reports using Claude AI, gathering data from JIRA, Slack, and GitHub.

## 🎯 What It Does

Generates weekly HTML reports from your team's activity across:

- **JIRA** (`https://issues.redhat.com` project: RHDPOPS)
- **GitHub** (rhpds organization, 8 team members)
- **Slack** (5 team channels, filtered by team members)

## 🚀 Quick Start

### Prerequisites

- [Claude CLI](https://github.com/anthropics/claude-cli) installed
- `jq`, `yq`, and `bash` available
- Python 3.11+ with `markdown` module

**Install dependencies (macOS):**

```bash
brew install yq jq
pip3 install markdown
npm install -g @anthropic-ai/claude-code
```

### Local Execution

```bash
# Set required environment variables
export ANTHROPIC_API_KEY="your-api-key"
export JIRA_API_TOKEN="your-jira-token"
export JIRA_EMAIL="your-jira-email@redhat.com"
export GITHUB_TOKEN="ghp_your-token"
export X_SLACK_WEB_TOKEN="xoxc-..."  # Optional
export X_SLACK_COOKIE_TOKEN="xoxd-..."  # Optional

# Gather data
bash scripts/data/gather_all.sh rhpds

# Generate report
bash scripts/reports/generate_report.sh rhpds

# View report
open reports/rhpds/weekly_$(date -u +%Y-%m-%d).html
```

## 🔑 Required Credentials

### For Local Development

Set these environment variables:

| Variable | Description | Example |
|----------|-------------|---------|
| `ANTHROPIC_API_KEY` | Claude API key | `sk-ant-...` |
| `JIRA_API_TOKEN` | JIRA API token | Get from https://issues.redhat.com |
| `JIRA_EMAIL` | Your JIRA email | `user@redhat.com` |
| `GITHUB_TOKEN` | GitHub PAT | `ghp_...` |
| `X_SLACK_WEB_TOKEN` | Slack web token | `xoxc-...` (optional) |
| `X_SLACK_COOKIE_TOKEN` | Slack cookie | `xoxd-...` (optional) |

**Get JIRA token:** https://issues.redhat.com/secure/ViewProfile.jspa → Personal Access Tokens

**Get GitHub PAT:** https://github.com/settings/tokens → Generate new token (needs `repo` scope)

### For GitHub Actions

Add these as repository secrets in GitHub Settings → Secrets and variables → Actions:

- `ANTHROPIC_API_KEY`
- `JIRA_API_TOKEN`
- `JIRA_EMAIL`
- `GH_PAT` (GitHub Personal Access Token)
- `X_SLACK_WEB_TOKEN` (optional)
- `X_SLACK_COOKIE_TOKEN` (optional)

## 🤖 GitHub Actions Automation

The workflow runs automatically:

- **Every Monday at 9:00 AM UTC**
- Or manually via GitHub Actions tab → "Run workflow"

### Setup GitHub Actions

1. **Add secrets** (see above)
2. **Enable GitHub Pages** (optional):
   - Settings → Pages
   - Source: GitHub Actions
   - Reports will be published to `https://rhpds.github.io/ops-team-reports/reports/`

3. **Workflow will**:
   - Gather data from JIRA, Slack, GitHub
   - Generate HTML report using Claude
   - Upload reports as artifacts (90-day retention)
   - Deploy to GitHub Pages (scheduled runs only)

## 📁 Project Structure

```
ops-team-reports/
├── .github/workflows/
│   └── weekly-reports.yml      # GitHub Actions workflow
├── config/teams/
│   └── rhpds.yaml              # Team configuration
├── scripts/
│   ├── data/
│   │   ├── gather_jira.sh      # JIRA REST API calls
│   │   ├── gather_github.sh    # GitHub API calls
│   │   ├── gather_slack.sh     # Slack via Claude + MCP
│   │   └── gather_all.sh       # Orchestrator
│   └── reports/
│       └── generate_report.sh  # Claude-powered report generation
├── data/                       # Generated data (gitignored)
├── reports/                    # Generated reports (gitignored)
└── logs/                       # Execution logs (gitignored)
```

## 👥 Team Configuration

Edit `config/teams/rhpds.yaml` to modify:

- Team members and GitHub usernames
- JIRA project keys
- Slack channel IDs
- GitHub organizations

**Current team members:**
- ahsen-shah
- bbethell-1
- bosebc
- d-jana
- klewis0928
- privera1
- rhjcd
- YoNoSoyVictor

## 🔧 How It Works

### Data Collection (gather_all.sh)

1. **JIRA** - Direct REST API calls using Basic Auth
   - Fetches issues from RHDPOPS project
   - Filters by date range (last 7 days)

2. **GitHub** - REST API calls using Bearer token
   - Searches PRs by author across rhpds org
   - Filters by date range (last 7 days)

3. **Slack** - Claude CLI with Slack MCP server
   - Monitors 5 team channels
   - Filters messages by team GitHub usernames
   - Includes thread links

### Report Generation (generate_report.sh)

1. Loads collected data from JSON
2. Sends to Claude with structured prompt
3. Claude generates Markdown report
4. Converts to styled HTML

Report includes:
- Executive summary
- Key accomplishments
- Team activity (JIRA, GitHub, Slack)
- Collaboration highlights
- Next week focus

## 📊 Output

Reports are generated in `reports/rhpds/`:

- `weekly_YYYY-MM-DD.md` - Markdown format
- `weekly_YYYY-MM-DD.html` - Styled HTML

Data is saved in `data/rhpds/`:

- `team_data_YYYY-MM-DDTHH-MM-SS.json` - Timestamped data
- `team_data_latest.json` - Symlink to latest

## 🐛 Troubleshooting

### No data collected

1. Check credentials are set correctly
2. Check logs in `logs/` directory
3. Test individual scripts:

```bash
# Test JIRA
bash scripts/data/gather_jira.sh "2025-01-01" "2025-01-08" "/tmp/test-jira.json" "logs" "RHDPOPS"

# Test GitHub
bash scripts/data/gather_github.sh "2025-01-01" "2025-01-08" "/tmp/test-github.json" "logs" "ahsen-shah,bbethell-1"
```

### Claude CLI issues

```bash
# Verify Claude CLI is installed
claude --version

# Test Claude connection
echo "Hello" | claude
```

### GitHub Actions failing

1. Verify all secrets are added in repository settings
2. Check workflow logs in Actions tab
3. Verify secrets have correct permissions:
   - `GH_PAT` needs `repo` scope
   - `JIRA_API_TOKEN` needs read access to RHDPOPS

## 📈 Future Enhancements

- [ ] Support multiple teams in single repo
- [ ] Add report customization templates
- [ ] Trend analysis (week-over-week comparisons)
- [ ] Slack notifications when reports are ready
- [ ] Dashboard view for historical reports

## 🤝 Contributing

1. Create a feature branch
2. Test changes locally first
3. Submit PR with description
4. Ensure GitHub Actions pass

## 📝 License

Internal Red Hat tool - Not for external distribution

---

**Questions?** Check logs in `logs/` or contact the RHPDS team.
