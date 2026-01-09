#!/usr/bin/env python3
"""Gather Slack data using official Bot Token API"""

import os
import sys
import json
from datetime import datetime, timedelta
from pathlib import Path
from slack_sdk import WebClient
from slack_sdk.errors import SlackApiError


def log(message: str, log_file: Path):
    """Log message to both console and file"""
    timestamp = datetime.now().strftime('%Y-%m-%dT%H:%M:%S')
    log_line = f"[{timestamp}] {message}"
    print(log_line)
    with open(log_file, 'a') as f:
        f.write(log_line + '\n')


def main():
    # Parse arguments
    channel_ids = sys.argv[1] if len(sys.argv) > 1 else ""
    github_users = sys.argv[2] if len(sys.argv) > 2 else ""
    output_file = sys.argv[3] if len(sys.argv) > 3 else '/tmp/slack.json'
    log_dir = sys.argv[4] if len(sys.argv) > 4 else 'logs'

    # Setup logging
    Path(log_dir).mkdir(exist_ok=True)
    log_file = Path(log_dir) / f"gather_slack_{datetime.now().strftime('%Y-%m-%dT%H-%M-%S')}.log"

    log("Starting Slack data gathering with Bot Token...", log_file)
    log(f"Channels: {channel_ids}", log_file)
    log(f"Filter by users: {github_users}", log_file)

    # Get Bot Token from environment
    slack_bot_token = os.getenv('SLACK_BOT_TOKEN')
    if not slack_bot_token:
        log("WARNING: SLACK_BOT_TOKEN not configured, skipping Slack data", log_file)
        with open(output_file, 'w') as f:
            json.dump({
                "raw_text": "No Slack data - credentials not configured",
                "source": "slack",
                "error": "missing_credentials"
            }, f)
        sys.exit(0)  # Non-fatal

    try:
        # Initialize Slack client
        client = WebClient(token=slack_bot_token)

        # Test authentication
        auth_response = client.auth_test()
        log(f"✅ Authenticated as bot: {auth_response['user']}", log_file)

        # Parse channel IDs
        channels = [ch.strip() for ch in channel_ids.split(',') if ch.strip()]
        if not channels:
            log("No channels specified", log_file)
            with open(output_file, 'w') as f:
                json.dump({
                    "raw_text": "No Slack data - no channels configured",
                    "source": "slack",
                    "channel_count": 0
                }, f)
            return

        # Calculate date range (last 7 days)
        end_time = datetime.now()
        start_time = end_time - timedelta(days=7)
        oldest = str(int(start_time.timestamp()))
        latest = str(int(end_time.timestamp()))

        log(f"Date range: {start_time} to {end_time}", log_file)

        # Parse GitHub users for filtering
        github_user_list = [u.strip().lower() for u in github_users.split(',') if u.strip()]

        # Gather messages from all channels
        all_messages = []

        for channel_id in channels:
            try:
                log(f"Fetching messages from channel {channel_id}...", log_file)

                # Get channel info
                try:
                    channel_info = client.conversations_info(channel=channel_id)
                    channel_name = channel_info['channel']['name']
                except SlackApiError as e:
                    log(f"  WARNING: Could not get channel info: {str(e)}", log_file)
                    channel_name = channel_id

                # Fetch messages
                result = client.conversations_history(
                    channel=channel_id,
                    oldest=oldest,
                    latest=latest,
                    limit=200
                )

                messages = result.get('messages', [])
                log(f"  Found {len(messages)} messages in #{channel_name}", log_file)

                # Process messages
                for msg in messages:
                    # Skip bot messages and system messages
                    if msg.get('subtype') in ['bot_message', 'channel_join', 'channel_leave']:
                        continue

                    user_id = msg.get('user')
                    if not user_id:
                        continue

                    # Get user info
                    try:
                        user_info = client.users_info(user=user_id)
                        user_profile = user_info['user']['profile']
                        display_name = user_profile.get('display_name', '')
                        real_name = user_profile.get('real_name', '')

                        # Filter by GitHub users if specified
                        if github_user_list:
                            user_match = False
                            for gh_user in github_user_list:
                                if (gh_user in display_name.lower() or
                                    gh_user in real_name.lower()):
                                    user_match = True
                                    break
                            if not user_match:
                                continue

                        # Format message
                        timestamp = datetime.fromtimestamp(float(msg['ts']))
                        text = msg.get('text', '')

                        # Check if message has replies
                        thread_info = ""
                        if msg.get('reply_count', 0) > 0:
                            thread_info = f" [{msg['reply_count']} replies]"

                        message_text = f"#{channel_name} - {display_name or real_name} ({timestamp.strftime('%Y-%m-%d %H:%M')}){thread_info}:\n{text}\n"
                        all_messages.append(message_text)

                    except SlackApiError as e:
                        log(f"  WARNING: Could not get user info for {user_id}: {str(e)}", log_file)
                        continue

            except SlackApiError as e:
                log(f"  ERROR: Failed to fetch messages from {channel_id}: {str(e)}", log_file)
                log(f"  Error details: {e.response['error']}", log_file)
                if e.response['error'] == 'not_in_channel':
                    log(f"  HINT: Bot needs to be invited to channel {channel_id}", log_file)
                continue

        # Format output
        messages_text = '\n'.join(all_messages) if all_messages else "No relevant Slack messages found"

        output_data = {
            "raw_text": messages_text,
            "source": "slack",
            "channel_count": len(channels),
            "message_count": len(all_messages),
            "date_range": {
                "start": start_time.isoformat(),
                "end": end_time.isoformat()
            }
        }

        with open(output_file, 'w') as f:
            json.dump(output_data, f, indent=2)

        log(f"✅ Slack data saved: {len(all_messages)} messages from {len(channels)} channels", log_file)

    except SlackApiError as e:
        log(f"ERROR: Slack API error: {str(e)}", log_file)
        with open(output_file, 'w') as f:
            json.dump({
                "raw_text": "No Slack data - API error",
                "source": "slack",
                "error": "api_failure",
                "error_message": str(e)
            }, f)
        sys.exit(1)
    except Exception as e:
        log(f"ERROR: Failed to fetch Slack data: {str(e)}", log_file)
        with open(output_file, 'w') as f:
            json.dump({
                "raw_text": "No Slack data - unexpected error",
                "source": "slack",
                "error": "unexpected_error",
                "error_message": str(e)
            }, f)
        sys.exit(1)


if __name__ == '__main__':
    main()
