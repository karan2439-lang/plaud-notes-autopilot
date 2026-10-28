#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== 1/3 Running library tests (test_new_recordings.sh) ==="
bash "$SCRIPT_DIR/lib/test_new_recordings.sh"

echo "=== 2/3 Running pipeline tests (test_run_plaud_pipeline.sh) ==="
bash "$SCRIPT_DIR/test_run_plaud_pipeline.sh"

echo "=== 3/3 Running install/uninstall tests (test_install_uninstall.sh) ==="
bash "$SCRIPT_DIR/test_install_uninstall.sh"

echo "=========================================="
echo "ALL TESTS PASSED SUCCESSFULLY!"
echo "=========================================="
