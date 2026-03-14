#!/bin/bash

# Usage: bash extract_dkim.sh <domain> [selector]
# selector defaults to "default" if not provided

if [ $# -lt 1 ]; then
    echo "Usage: bash extract_dkim.sh <domain> [selector]"
    exit 1
fi

DOMAIN="$1"
SELECTOR="${2:-default}"
DKIM_FILE="/etc/pmta/dkim/${DOMAIN}-dkim.txt"

if [ ! -f "$DKIM_FILE" ]; then
    echo "DKIM file not found: $DKIM_FILE"
    exit 1
fi

# Extract all quoted strings, concatenate, then pull out the p= value
full_value=$(sed -n 's/.*"\([^"]*\)".*/\1/p' "$DKIM_FILE" | tr -d ' \t\n\r')

# Extract p= value
dkim_p=$(echo "$full_value" | sed 's/.*p=//g')

if [ -n "$dkim_p" ]; then
    echo "v=DKIM1; k=rsa; p=$dkim_p"
else
    echo "No valid DKIM record found in $DKIM_FILE"
    exit 1
fi
