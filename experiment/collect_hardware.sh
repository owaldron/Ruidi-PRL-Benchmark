#!/usr/bin/env bash
# Collect hardware info and write it as JSON to the path given as $1.
set -euo pipefail

OUTPUT_PATH="${1:?Usage: collect_hardware.sh <output-path>}"

if [[ "$(uname)" == "Darwin" ]]; then
  CPU=$(sysctl -n machdep.cpu.brand_string)
  CORES=$(sysctl -n hw.ncpu)
  MEM_BYTES=$(sysctl -n hw.memsize)
  MEM_GB=$(( MEM_BYTES / 1073741824 ))
  ARCH=$(uname -m)
  OS="$(sw_vers -productName) $(sw_vers -productVersion)"
else
  CPU=$(lscpu | awk -F: '/Model name/ {gsub(/^ +/, "", $2); print $2}')
  CORES=$(nproc)
  MEM_KB=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
  MEM_GB=$(( MEM_KB / 1048576 ))
  ARCH=$(uname -m)
  OS=$(uname -sr)
fi

cat > "$OUTPUT_PATH" <<EOF
{
  "cpu": "$CPU",
  "cores": $CORES,
  "memory_gb": $MEM_GB,
  "arch": "$ARCH",
  "os": "$OS",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

echo "Hardware info written to $OUTPUT_PATH"
