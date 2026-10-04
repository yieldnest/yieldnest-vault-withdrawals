#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "Usage: $0 <deployment-json>"
  exit 1
fi

if [ -z "${ETH_MAINNET_RPC_URL:-}" ]; then
  echo "ETH_MAINNET_RPC_URL is required"
  exit 1
fi

deployment_file="$1"
artifact_file="out/WithdrawalRequestDeployer.sol/WithdrawalRequestDeployer.json"

for command in jq cast; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "$command is required"
    exit 1
  fi
done

if [ ! -f "$deployment_file" ]; then
  echo "Deployment file not found: $deployment_file"
  exit 1
fi

if [ ! -f "$artifact_file" ]; then
  echo "Contract artifact not found: $artifact_file"
  echo "Run forge build from the repository root, then retry."
  exit 1
fi

deployed_address="$(jq -r '.systemDeployer' "$deployment_file")"
if [ -z "$deployed_address" ] || [ "$deployed_address" = "null" ]; then
  echo "Missing required deployment field: systemDeployer"
  exit 1
fi

echo "Checking deployed WithdrawalRequestDeployer bytecode"
echo "  deployment file: $deployment_file"
echo "  contract:        $deployed_address"
echo "  artifact:        $artifact_file"
echo

local_runtime="$(jq -r '.deployedBytecode.object' "$artifact_file" | tr '[:upper:]' '[:lower:]')"
if [ -z "$local_runtime" ] || [ "$local_runtime" = "null" ] || [ "$local_runtime" = "0x" ]; then
  echo "No local deployed bytecode found in artifact: $artifact_file"
  exit 1
fi

deployed_runtime="$(cast code "$deployed_address" --rpc-url "$ETH_MAINNET_RPC_URL" | tr '[:upper:]' '[:lower:]')"
if [ "$deployed_runtime" = "0x" ]; then
  echo "No code found at deployed address: $deployed_address"
  exit 1
fi

echo "  local runtime hash:    $(cast keccak "$local_runtime")"
echo "  deployed runtime hash: $(cast keccak "$deployed_runtime")"
echo

if [ "$local_runtime" != "$deployed_runtime" ]; then
  echo "WithdrawalRequestDeployer bytecode mismatch"
  exit 1
fi

echo "WithdrawalRequestDeployer bytecode matches"
