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

if [ ! -f "$deployment_file" ]; then
  echo "Deployment file not found: $deployment_file"
  exit 1
fi

for command in jq cast; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "$command is required"
    exit 1
  fi
done

verify_bytecode() {
  local label="$1"
  local deployment_field="$2"
  local artifact_file="$3"

  if [ ! -f "$artifact_file" ]; then
    echo "Contract artifact not found: $artifact_file"
    echo "Run forge build from the repository root, then retry."
    exit 1
  fi

  local deployed_address
  deployed_address="$(jq -r ".$deployment_field" "$deployment_file")"
  if [ -z "$deployed_address" ] || [ "$deployed_address" = "null" ]; then
    echo "Missing required deployment field: $deployment_field"
    exit 1
  fi

  echo "Checking deployed $label bytecode"
  echo "  deployment file: $deployment_file"
  echo "  contract:        $deployed_address"
  echo "  artifact:        $artifact_file"
  echo

  local local_runtime
  local_runtime="$(jq -r '.deployedBytecode.object' "$artifact_file" | tr '[:upper:]' '[:lower:]')"
  if [ -z "$local_runtime" ] || [ "$local_runtime" = "null" ] || [ "$local_runtime" = "0x" ]; then
    echo "No local deployed bytecode found in artifact: $artifact_file"
    exit 1
  fi

  local deployed_runtime
  deployed_runtime="$(cast code "$deployed_address" --rpc-url "$ETH_MAINNET_RPC_URL" | tr '[:upper:]' '[:lower:]')"
  if [ "$deployed_runtime" = "0x" ]; then
    echo "No code found at deployed address: $deployed_address"
    exit 1
  fi

  echo "  local runtime hash:    $(cast keccak "$local_runtime")"
  echo "  deployed runtime hash: $(cast keccak "$deployed_runtime")"
  echo

  if [ "$local_runtime" != "$deployed_runtime" ]; then
    echo "$label bytecode mismatch"
    exit 1
  fi

  echo "$label bytecode matches"
  echo
}

verify_bytecode \
  "WithdrawalRequest implementation" \
  "withdrawalRequestImplementation" \
  "out/WithdrawalRequest.sol/WithdrawalRequest.json"

verify_bytecode \
  "BaseWithdrawer implementation" \
  "withdrawerImplementation" \
  "out/BaseWithdrawer.sol/BaseWithdrawer.json"

verify_bytecode \
  "BeaconProxyFactory implementation" \
  "bagFactoryImplementation" \
  "out/BeaconProxyFactory.sol/BeaconProxyFactory.json"

verify_bytecode \
  "Bag implementation" \
  "bagImplementation" \
  "out/Bag.sol/Bag.json"

echo "All implementation bytecode matches"
