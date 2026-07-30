#!/usr/bin/env bash
set -euo pipefail

TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

bash "${TEST_DIR}/test_release_cli.sh"
bash "${TEST_DIR}/test_entrypoint.sh"
bash "${TEST_DIR}/test_gpu_detection.sh"
bash "${TEST_DIR}/test_artifact_commands.sh"
bash "${TEST_DIR}/test_system_flow.sh"
bash "${TEST_DIR}/test_lifecycle.sh"

printf 'PASS: all ROCm 7.14 installer tests\n'
