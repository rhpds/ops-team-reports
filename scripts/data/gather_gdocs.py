#!/usr/bin/env python3
"""Gather Google Docs data from team Drive"""

import os
import sys
import json
from datetime import datetime
from pathlib import Path
from google.oauth2 import service_account
from googleapiclient.discovery import build


def log(message: str, log_file: Path):
    """Log message to both console and file"""
    timestamp = datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%S')
    log_line = f"[{timestamp}] {message}"
    print(log_line)
    with open(log_file, 'a') as f:
        f.write(log_line + '\n')


def main():
    # Parse arguments with defaults
    start_date = sys.argv[1] if len(sys.argv) > 1 else None
    end_date = sys.argv[2] if len(sys.argv) > 2 else None
    output_file = sys.argv[3] if len(sys.argv) > 3 else '/tmp/gdocs.json'
    log_dir = sys.argv[4] if len(sys.argv) > 4 else 'logs'
    search_query = sys.argv[5] if len(sys.argv) > 5 else 'cog'  # Default search term

    # Setup logging
    Path(log_dir).mkdir(exist_ok=True)
    log_file = Path(log_dir) / f"gather_gdocs_{datetime.utcnow().strftime('%Y-%m-%dT%H-%M-%S')}.log"

    log("Starting Google Docs data gathering...", log_file)
    log(f"Date range: {start_date} to {end_date}", log_file)
    log(f"Search query: {search_query}", log_file)

    # Get service account credentials from environment
    gdocs_creds_json = os.getenv('GDOCS_SERVICE_ACCOUNT')
    if not gdocs_creds_json:
        log("ERROR: GDOCS_SERVICE_ACCOUNT must be set", log_file)
        with open(output_file, 'w') as f:
            json.dump({
                "raw_text": "No Google Docs data - missing credentials",
                "source": "gdocs",
                "error": "missing_credentials"
            }, f)
        sys.exit(1)

    try:
        # Parse service account credentials
        creds_info = json.loads(gdocs_creds_json)

        # Create credentials object
        SCOPES = ['https://www.googleapis.com/auth/drive.readonly']
        credentials = service_account.Credentials.from_service_account_info(
            creds_info, scopes=SCOPES)

        # Build Drive API service
        service = build('drive', 'v3', credentials=credentials)

        # Build query string
        # Search for Google Docs containing the search query
        query_parts = [
            "mimeType='application/vnd.google-apps.document'",
            f"fullText contains '{search_query}'",
            "trashed=false"
        ]

        # Add date filters if provided
        if start_date:
            query_parts.append(f"createdTime >= '{start_date}T00:00:00'")
        if end_date:
            query_parts.append(f"createdTime <= '{end_date}T23:59:59'")

        query = ' and '.join(query_parts)
        log(f"Executing query: {query}", log_file)

        # Search for documents
        # Note: orderBy is not supported with fullText queries, results are in relevance order
        results = service.files().list(
            q=query,
            spaces='drive',
            fields='files(id, name, createdTime, modifiedTime, webViewLink, owners, lastModifyingUser)',
            pageSize=100
        ).execute()

        docs = results.get('files', [])
        doc_count = len(docs)
        log(f"Found {doc_count} documents", log_file)

        # Transform to simplified format
        docs_text_parts = []
        for doc in docs:
            name = doc.get('name', 'Untitled')
            link = doc.get('webViewLink', '')
            created = doc.get('createdTime', '')
            modified = doc.get('modifiedTime', '')

            # Get owner info
            owners = doc.get('owners', [])
            owner_name = owners[0].get('displayName', 'Unknown') if owners else 'Unknown'

            # Get last modifying user
            last_user = doc.get('lastModifyingUser', {})
            last_modifier = last_user.get('displayName', owner_name)

            text = f"[{name}]({link})\n"
            text += f"  Created: {created}\n"
            text += f"  Last Modified: {modified}\n"
            text += f"  Owner: {owner_name}\n"
            text += f"  Last Modified By: {last_modifier}\n"

            # Try to get document content preview (first 200 chars)
            try:
                doc_service = build('docs', 'v1', credentials=credentials)
                document = doc_service.documents().get(documentId=doc['id']).execute()

                # Extract text content
                content_text = ""
                for element in document.get('body', {}).get('content', []):
                    if 'paragraph' in element:
                        for elem in element['paragraph'].get('elements', []):
                            if 'textRun' in elem:
                                content_text += elem['textRun'].get('content', '')

                if content_text:
                    preview = content_text.strip()[:200].replace('\n', ' ')
                    text += f"  Preview: {preview}...\n"
            except Exception as e:
                log(f"  WARNING: Could not fetch content for {doc['id']}: {str(e)}", log_file)

            docs_text_parts.append(text)

        docs_text = '\n'.join(docs_text_parts)

        # Create output JSON
        output_data = {
            "raw_text": docs_text,
            "source": "gdocs",
            "doc_count": doc_count,
            "search_query": search_query,
            "date_range": {
                "start": start_date,
                "end": end_date
            }
        }

        with open(output_file, 'w') as f:
            json.dump(output_data, f, indent=2)

        log(f"✅ Google Docs data saved to {output_file}", log_file)

    except json.JSONDecodeError as e:
        log(f"ERROR: Invalid service account credentials JSON: {str(e)}", log_file)
        with open(output_file, 'w') as f:
            json.dump({
                "raw_text": "No Google Docs data - invalid credentials",
                "source": "gdocs",
                "error": "invalid_credentials"
            }, f)
        sys.exit(1)
    except Exception as e:
        log(f"ERROR: Failed to fetch Google Docs data: {str(e)}", log_file)
        with open(output_file, 'w') as f:
            json.dump({
                "raw_text": "No Google Docs data - API error",
                "source": "gdocs",
                "error": "api_failure",
                "error_message": str(e)
            }, f)
        sys.exit(1)


if __name__ == '__main__':
    main()
