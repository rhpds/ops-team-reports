#!/usr/bin/env python3
"""Gather CoG emails from Gmail"""

import os
import sys
import json
import base64
from datetime import datetime
from pathlib import Path
from google.oauth2.credentials import Credentials
from googleapiclient.discovery import build


def log(message: str, log_file: Path):
    """Log message to both console and file"""
    timestamp = datetime.now().strftime('%Y-%m-%dT%H:%M:%S')
    log_line = f"[{timestamp}] {message}"
    print(log_line)
    with open(log_file, 'a') as f:
        f.write(log_line + '\n')


def main():
    # Parse arguments with defaults
    start_date = sys.argv[1] if len(sys.argv) > 1 else None
    end_date = sys.argv[2] if len(sys.argv) > 2 else None
    output_file = sys.argv[3] if len(sys.argv) > 3 else '/tmp/cog_emails.json'
    log_dir = sys.argv[4] if len(sys.argv) > 4 else 'logs'

    # Setup logging
    Path(log_dir).mkdir(exist_ok=True)
    log_file = Path(log_dir) / f"gather_cog_{datetime.now().strftime('%Y-%m-%dT%H-%M-%S')}.log"

    log("Starting CoG emails gathering from Gmail...", log_file)
    log(f"Date range: {start_date} to {end_date}", log_file)

    # Get OAuth credentials from environment
    google_token_json = os.getenv('GOOGLE_TOKEN')
    if not google_token_json:
        log("ERROR: GOOGLE_TOKEN must be set", log_file)
        with open(output_file, 'w') as f:
            json.dump({
                "raw_text": "No CoG emails - missing credentials",
                "source": "cog_emails",
                "error": "missing_credentials"
            }, f)
        sys.exit(1)

    try:
        # Parse OAuth token (includes refresh_token, client_id, client_secret)
        token_info = json.loads(google_token_json)

        # Create credentials object from refresh token
        credentials = Credentials(
            token=token_info.get('access_token'),
            refresh_token=token_info.get('refresh_token'),
            token_uri='https://oauth2.googleapis.com/token',
            client_id=token_info.get('client_id'),
            client_secret=token_info.get('client_secret'),
            scopes=['https://www.googleapis.com/auth/gmail.readonly']
        )

        # Build Gmail API service
        service = build('gmail', 'v1', credentials=credentials)

        # Build search query
        # Search for emails from gemini-notes@google.com with "Notes:" in subject
        query_parts = [
            'from:gemini-notes@google.com',
            'subject:"Notes:"'
        ]

        # Add date filters if provided
        if start_date:
            # Convert YYYY-MM-DD to Gmail date format (YYYY/MM/DD)
            gmail_start = start_date.replace('-', '/')
            query_parts.append(f'after:{gmail_start}')
        if end_date:
            gmail_end = end_date.replace('-', '/')
            query_parts.append(f'before:{gmail_end}')

        query = ' '.join(query_parts)
        log(f"Executing Gmail query: {query}", log_file)

        # Search for emails
        results = service.users().messages().list(
            userId='me',
            q=query,
            maxResults=100
        ).execute()

        messages = results.get('messages', [])
        email_count = len(messages)
        log(f"Found {email_count} CoG emails", log_file)

        # Extract email content
        emails_text_parts = []
        for msg in messages:
            try:
                # Get full message
                message = service.users().messages().get(
                    userId='me',
                    id=msg['id'],
                    format='full'
                ).execute()

                # Extract headers
                headers = message['payload']['headers']
                subject = next((h['value'] for h in headers if h['name'] == 'Subject'), 'No Subject')
                from_email = next((h['value'] for h in headers if h['name'] == 'From'), 'Unknown')
                date_str = next((h['value'] for h in headers if h['name'] == 'Date'), '')

                # Extract body
                body = ''
                if 'parts' in message['payload']:
                    for part in message['payload']['parts']:
                        if part['mimeType'] == 'text/plain' and 'data' in part['body']:
                            body = base64.urlsafe_b64decode(part['body']['data']).decode('utf-8')
                            break
                        elif part['mimeType'] == 'text/html' and 'data' in part['body'] and not body:
                            body = base64.urlsafe_b64decode(part['body']['data']).decode('utf-8')
                elif 'body' in message['payload'] and 'data' in message['payload']['body']:
                    body = base64.urlsafe_b64decode(message['payload']['body']['data']).decode('utf-8')

                # Format email info
                text = f"From: {from_email}\n"
                text += f"Subject: {subject}\n"
                text += f"Date: {date_str}\n"
                text += f"\n{body}\n"
                text += f"{'-' * 80}\n"

                emails_text_parts.append(text)

            except Exception as e:
                log(f"  WARNING: Could not fetch email {msg['id']}: {str(e)}", log_file)

        emails_text = '\n'.join(emails_text_parts)

        # Create output JSON
        output_data = {
            "raw_text": emails_text,
            "source": "cog_emails",
            "email_count": email_count,
            "date_range": {
                "start": start_date,
                "end": end_date
            }
        }

        with open(output_file, 'w') as f:
            json.dump(output_data, f, indent=2)

        log(f"✅ CoG emails data saved to {output_file}", log_file)

    except json.JSONDecodeError as e:
        log(f"ERROR: Invalid Google token JSON: {str(e)}", log_file)
        with open(output_file, 'w') as f:
            json.dump({
                "raw_text": "No CoG emails - invalid credentials",
                "source": "cog_emails",
                "error": "invalid_credentials"
            }, f)
        sys.exit(1)
    except Exception as e:
        log(f"ERROR: Failed to fetch CoG emails: {str(e)}", log_file)
        with open(output_file, 'w') as f:
            json.dump({
                "raw_text": "No CoG emails - API error",
                "source": "cog_emails",
                "error": "api_failure",
                "error_message": str(e)
            }, f)
        sys.exit(1)


if __name__ == '__main__':
    main()
