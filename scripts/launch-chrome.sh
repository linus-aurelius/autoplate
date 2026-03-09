#!/bin/bash
# Launch Chrome with CDP (Chrome DevTools Protocol) enabled.
# This uses the real Chrome profile — all extensions, cookies, bookmarks intact.
# The only difference from normal Chrome: agent-browser can connect on port 9222.

CHROME_PROFILE="/Users/linus/Library/Application Support/Google/ChromeProfile"
CDP_PORT=9222

# Check if Chrome is already running with CDP
if curl -s "http://127.0.0.1:$CDP_PORT/json/version" > /dev/null 2>&1; then
  echo "Chrome already running with CDP on port $CDP_PORT"
  exit 0
fi

# Kill Chrome if running without CDP
if pgrep -f "Google Chrome" > /dev/null 2>&1; then
  echo "Chrome running without CDP. Restarting..."
  pkill -f "Google Chrome"
  sleep 2
fi

open -a "Google Chrome" --args --remote-debugging-port=$CDP_PORT --user-data-dir="$CHROME_PROFILE"

# Wait for CDP to be ready
attempts=0
while [ $attempts -lt 15 ]; do
  if curl -s "http://127.0.0.1:$CDP_PORT/json/version" > /dev/null 2>&1; then
    echo "Chrome ready with CDP on port $CDP_PORT"
    exit 0
  fi
  sleep 2
  attempts=$((attempts + 1))
done

echo "ERROR: Chrome CDP not available after 30s"
exit 1
