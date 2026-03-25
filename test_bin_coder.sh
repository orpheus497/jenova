#!/bin/sh
./bin/coder-server > test_bin_coder.log 2>&1 &
PID1=$!
sleep 5
echo "Checking bin/coder-server background boot:"
curl -s http://127.0.0.1:8080/health || echo "HTTP 8080 Proxy Down"
curl -s http://127.0.0.1:8081/health || echo "HTTP 8081 LLAMA Down"
kill $PID1 2>/dev/null
echo ""
echo "Log output:"
cat test_bin_coder.log
