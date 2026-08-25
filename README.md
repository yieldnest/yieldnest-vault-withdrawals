# yieldnest-vault-withdrawals

Standalone Foundry package for YieldNest withdrawal request management.

## Layout

- `src/Bag.sol`: per-request NFT claim container.
- `src/BeaconProxyFactory.sol`: upgradeable beacon proxy factory for Bags.
- `src/WithdrawalRequest.sol`: yn-token withdrawal request queue and fulfilment contract.
- `src/interface/`: public interfaces used by the withdrawal contracts.
- `script/deploy/DeployWithdrawalRequest.s.sol`: ynETHx deployment script.
- `test/local/unit/`: unit tests.
- `test/mainnet/`: mainnet-fork integration tests.

## Setup

```sh
git submodule update --init --recursive
forge test --match-path 'test/local/unit/*.t.sol'
```

Mainnet-fork tests use `ETH_MAINNET_RPC_URL`:

```sh
FOUNDRY_PROFILE=mainnet forge test --match-path test/mainnet/withdrawalrequest.spec.sol
```
