#!/bin/bash
# Query border info for a window ID
# Usage: ./query-border.sh <window_id>

WINDOW_ID=${1:-78}

# Create JSON-RPC request
REQUEST=$(cat <<EOF
{"jsonrpc":"2.0","id":"query-1","method":"borders.query","params":{"windowId":$WINDOW_ID}}
EOF
)

# Send to socket and get response
echo "$REQUEST" | nc -U /tmp/grid-server.sock | jq .
