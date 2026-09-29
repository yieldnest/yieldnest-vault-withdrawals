# yieldnest-vault-withdrawals

Standalone Foundry package for YieldNest withdrawal request management.

## Layout

- `src/Bag.sol`: per-request NFT claim container.
- `src/BeaconProxyFactory.sol`: upgradeable beacon proxy factory for Bags.
- `src/WithdrawalRequest.sol`: yn-token withdrawal request queue and fulfilment contract.
- `src/interface/`: public interfaces used by the withdrawal contracts.
- `script/deploy/DeployWithdrawalRequest.s.sol`: ynETHx deployment script.
- `script/WithdrawalRequestDeployer.sol`: atomic system deployer using existing implementations.
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

## Deployment

First deploy the four implementations using `script/deploy/DeployWithdrawalRequestImplementations.s.sol`.
This writes `deployments/withdrawalRequestImplementations-<chainId>.json`.

Then run `script/deploy/DeployWithdrawalRequest.s.sol` for ynETHx or
`script/deploy/DeployYnRWAxWithdrawalRequest.s.sol` for ynRWAx. These scripts read the implementation addresses
from that JSON, create `WithdrawalRequestDeployer` with no constructor arguments, and call `deploy(params)`
in a second transaction. The deploy call creates
the one-day timelock, request/factory/withdrawer proxies, minimum-amount policy, and viewer, and initializes
the system atomically. Each deployer can deploy once; a failed call can be retried.
Implementation deployment is a separate prerequisite.

`DeploymentParams.admin` receives the timelock default admin, proposer, executor, and canceller roles.
It can manage timelock roles directly without the delay. The timelock also retains its own default admin role.

The resulting deployment JSON includes every ProxyAdmin address (`proxyAdmin`, `bagFactoryProxyAdmin`,
`withdrawerProxyAdmin`) and the `systemDeployer` address. All three ProxyAdmins are owned by the new timelock.
