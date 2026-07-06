# yieldnest-vault-withdrawals

Standalone Foundry package for YieldNest withdrawal request management.

## Layout

- `src/withdrawal/Bag.sol`: per-request NFT claim container.
- `src/withdrawal/BeaconProxyFactory.sol`: upgradeable beacon proxy factory for Bags.
- `src/withdrawal/WithdrawalRequestManager.sol`: yn-token withdrawal request queue and fulfilment manager.
- `src/interface/`: public interfaces used by the withdrawal contracts.
- `script/deploy/DeployWithdrawalRequestManager.s.sol`: ynETHx deployment script.
- `test/local/unit/`: unit tests.
- `test/mainnet/`: mainnet-fork integration tests.

## Setup

```sh
git submodule update --init --recursive
forge test --match-path 'test/local/unit/*.t.sol'
```

Mainnet-fork tests use `ETH_MAINNET_RPC_URL`:

```sh
FOUNDRY_PROFILE=mainnet forge test --match-path test/mainnet/withdrawalrequestmanager.spec.sol
```
