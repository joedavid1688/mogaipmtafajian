#!/bin/sh

if [ $# -ne 1 ]; then
    echo "Usage: sh ./extract_dkim.sh <domain>"
    exit 1
fi

domain=$1
dkim_file="/etc/pmta/$domain-dkim.txt"

if [ ! -f "$dkim_file" ]; then
    echo "DKIM file for domain $domain not found!"
    exit 1
fi

# Extract all quoted strings, concatenate, then pull out the p= value
# This handles multi-line DKIM keys split across multiple quoted strings
full_value=$(sed -n 's/.*"\([^"]*\)".*/\1/p' "$dkim_file" | tr -d ' \t\n\r')

# Extract p= value from the concatenated string
dkim_p=$(echo "$full_value" | sed 's/.*p=//g')

if [ -n "$dkim_p" ]; then
    echo "v=DKIM1; k=rsa;p=$dkim_p"
else
    echo "No valid DKIM record found in $dkim_file"
fi
