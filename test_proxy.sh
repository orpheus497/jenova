#!/bin/bash
# Start proxy in background
luajit lib/proxy.lua > /dev/null 2>&1 &
PROXY_PID=$!
sleep 1

echo "--- TEST 1: Missing static file (/nonexistent.css) ---"
curl -s -i http://127.0.0.1:8080/nonexistent.css | head -n 1

echo -e "\n--- TEST 2: Directory access via Storage API ---"
mkdir -p /tmp/jenova_test_dir
export JENOVA_WORKSPACES=/tmp/jenova_test_dir
mkdir -p /tmp/jenova_test_dir/dummy_dir
curl -s -i http://127.0.0.1:8080/api/storage/dummy_dir | head -n 1

echo -e "\n--- TEST 3: Fallback to LLM Backend (/v1/models) ---"
curl -s -i http://127.0.0.1:8080/v1/models | head -n 1

echo -e "\n--- TEST 4: Existing Static File ---"
mkdir -p public
echo "body { color: red; }" > public/style.css
curl -s -i http://127.0.0.1:8080/style.css | head -n 1

kill $PROXY_PID
