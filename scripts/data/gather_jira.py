#!/usr/bin/env python3
"""Gather JIRA data using Python JIRA library (same auth as webapp)"""

import os
import sys
import json
from datetime import datetime, timedelta
from pathlib import Path
from jira import JIRA


def log(message: str, log_file: Path):
    """Log message to both console and file"""
    timestamp = datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%S')
    log_line = f"[{timestamp}] {message}"
    print(log_line)
    with open(log_file, 'a') as f:
        f.write(log_line + '\n')


def main():
    # Parse arguments with defaults
    start_date = sys.argv[1] if len(sys.argv) > 1 else (datetime.utcnow() - timedelta(days=7)).strftime('%Y-%m-%d')
    end_date = sys.argv[2] if len(sys.argv) > 2 else datetime.utcnow().strftime('%Y-%m-%d')
    output_file = sys.argv[3] if len(sys.argv) > 3 else '/tmp/jira.json'
    log_dir = sys.argv[4] if len(sys.argv) > 4 else 'logs'
    jira_project = sys.argv[5] if len(sys.argv) > 5 else 'RHDPOPS'
    team_members = sys.argv[6] if len(sys.argv) > 6 else ''

    # Setup logging
    Path(log_dir).mkdir(exist_ok=True)
    log_file = Path(log_dir) / f"gather_jira_{datetime.utcnow().strftime('%Y-%m-%dT%H-%M-%S')}.log"

    log("Starting JIRA data gathering...", log_file)
    log(f"Project: {jira_project}", log_file)
    log(f"Date range: {start_date} to {end_date}", log_file)

    # Verify required environment variables
    jira_token = os.getenv('JIRA_API_TOKEN')
    if not jira_token:
        log("ERROR: JIRA_API_TOKEN must be set", log_file)
        with open(output_file, 'w') as f:
            json.dump({
                "raw_text": "No JIRA data - missing credentials",
                "source": "jira",
                "error": "missing_credentials"
            }, f)
        sys.exit(1)

    jira_base_url = os.getenv('JIRA_BASE_URL', 'https://issues.redhat.com')

    # Build team member filter if provided
    team_filter = ""
    if team_members:
        members = [m.strip() for m in team_members.split(',') if m.strip()]
        if members:
            member_conditions = ' OR '.join([
                f'assignee = "{m}" OR reporter = "{m}"' for m in members
            ])
            team_filter = f" AND ({member_conditions})"

    # JQL query for issues with any activity in date range
    jql = (
        f"project = {jira_project} AND "
        f"((created >= '{start_date}' AND created <= '{end_date}') OR "
        f"(updated >= '{start_date}' AND updated <= '{end_date}') OR "
        f"(resolutiondate >= '{start_date}' AND resolutiondate <= '{end_date}'))"
        f"{team_filter} ORDER BY updated DESC"
    )

    log(f"Executing JQL: {jql}", log_file)

    try:
        # Connect to JIRA using token auth (same as webapp)
        jira_client = JIRA(server=jira_base_url, token_auth=jira_token)

        # Search for issues
        issues = jira_client.search_issues(
            jql,
            maxResults=100,
            fields='summary,status,assignee,priority,updated,created,resolutiondate,description,comment'
        )

        issue_count = len(issues)
        log(f"Found {issue_count} issues", log_file)

        # Transform to simplified format
        issues_text_parts = []
        for issue in issues:
            key = issue.key
            fields = issue.fields

            text = f"[{key}](https://issues.redhat.com/browse/{key}) - {fields.summary}\n"
            text += f"  Status: {fields.status.name}\n"
            text += f"  Assignee: {fields.assignee.displayName if fields.assignee else 'Unassigned'}\n"
            text += f"  Priority: {fields.priority.name if fields.priority else 'None'}\n"
            text += f"  Created: {fields.created}\n"
            text += f"  Updated: {fields.updated}\n"
            if fields.resolutiondate:
                text += f"  Resolved: {fields.resolutiondate}\n"

            description = fields.description or "No description"
            text += f"  Description: {description[:200]}...\n"

            issues_text_parts.append(text)

        issues_text = '\n'.join(issues_text_parts)

        # Create output JSON
        output_data = {
            "raw_text": issues_text,
            "source": "jira",
            "issue_count": issue_count,
            "project": jira_project,
            "date_range": {
                "start": start_date,
                "end": end_date
            }
        }

        with open(output_file, 'w') as f:
            json.dump(output_data, f, indent=2)

        log(f"✅ JIRA data saved to {output_file}", log_file)

    except Exception as e:
        log(f"ERROR: Failed to fetch JIRA data: {str(e)}", log_file)
        with open(output_file, 'w') as f:
            json.dump({
                "raw_text": "No JIRA data - API error",
                "source": "jira",
                "error": "api_failure",
                "error_message": str(e)
            }, f)
        sys.exit(1)


if __name__ == '__main__':
    main()
