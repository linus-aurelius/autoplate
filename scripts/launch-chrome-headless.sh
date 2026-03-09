#!/bin/bash
# Launch a headless Chrome instance for background automation.
# No UI, no focus stealing. Used for scraping public pages.
# Port 9223 (separate from the main Chrome on 9222).

CDP_PORT=9223
PROFILE_DIR="/Users/linus/Library/Application Support/Google/ChromeHeadless"

# Check if already running
if curl -s "http://127.0.0.1:$CDP_PORT/json/version" > /dev/null 2>&1; then
  echo "Headless Chrome already running on port $CDP_PORT"
  exit 0
fi

# Launch headless Chrome in background
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  --headless=new \
  --remote-debugging-port=$CDP_PORT \
  --user-data-dir="$PROFILE_DIR" \
  --no-first-run \
  --disable-gpu \
  --window-size=1280,800 \
  > /dev/null 2>&1 &

# Wait for CDP to be ready
attempts=0
while [ $attempts -lt 15 ]; do
  if curl -s "http://127.0.0.1:$CDP_PORT/json/version" > /dev/null 2>&1; then
    echo "Headless Chrome ready on port $CDP_PORT"
    exit 0
  fi
  sleep 1
  attempts=$((attempts + 1))
done

echo "ERROR: Headless Chrome not available after 15s"
exit 1
