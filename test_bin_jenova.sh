#!/bin/sh
./bin/jenova-ca > test_bin_jenova.log 2>&1 &
PID1=$!
sleep 10
echo "Checking bin/jenova-ca background boot:"
curl -s http://127.0.0.1:8080/health || echo "HTTP 8080 Proxy Down"
curl -s http://127.0.0.1:8081/health || echo "HTTP 8081 LLAMA Down"
kill $PID1 2>/dev/null
echo ""
echo "Log output:"
cat test_bin_jenova.log
