# AGENTS.md

This file tells Codex and other agents how to operate in `yieldnest-vault-withdrawals`.
It is also a deployment/configuration guide for people, LLMs, and config validators
checking YieldNest withdrawal request deployments.

## Purpose

This repo contains the YieldNest withdrawal request system:

- request NFT, locked-share custody, and resolver-gated settlement in [`src/WithdrawalRequest.sol`](src/WithdrawalRequest.sol)
- per-request asset containers in [`src/Bag.sol`](src/Bag.sol)
- beacon proxy bag deployment and upgrades in [`src/BeaconProxyFactory.sol`](src/BeaconProxyFactory.sol)
- vault withdrawal adapter logic in [`src/withdrawers/BaseWithdrawer.sol`](src/withdrawers/BaseWithdrawer.sol)
- request policy and share-to-asset math helpers under [`src/policies/`](src/policies) and [`src/library/`](src/library)
- read-only request and bag views in [`views/WithdrawalRequestViewer.sol`](views/WithdrawalRequestViewer.sol)
- deployment scripts under [`script/`](script)
- unit and mainnet-fork tests under [`test/`](test)

The default posture is conservative. Preserve request custody, resolver authority, bag ownership, role boundaries,
storage layout, initializer behavior, and upgrade safety.

## Repo Map

- `src/`
  - `WithdrawalRequest.sol`: upgradeable request manager, ERC721 request ownership, locked yn-token custody, resolution
  - `Bag.sol`: upgradeable asset container whose current registry owner can claim assets
  - `BeaconProxyFactory.sol`: upgradeable factory that creates beacon proxies and upgrades their shared implementation
  - `withdrawers/BaseWithdrawer.sol`: production withdrawer adapter used by `WithdrawalRequest`
  - `policies/MinAmountRequestPolicy.sol`: production request validation policy
  - `library/VaultMath.sol`: conversion helper for vault shares to specific asset amounts
  - `interface/`: narrow production interfaces used by the system
- `views/`
  - `WithdrawalRequestViewer.sol`: read-only view helper for requests, bag balances, claim state, and max resolution
- `script/`
  - `deploy/DeployWithdrawalRequest.s.sol`: production deployment flow and deployment artifact writer
- `test/local/`
  - unit tests and test-only helpers; contracts under `test/local/unit/helpers/` are not production contracts
- `test/mainnet/`
  - mainnet-fork coverage for deployed-like behavior
- `deployments/`
  - deployment artifacts and config outputs
- `broadcast/`, `out/`, `cache/`
  - generated artifacts; do not hand-edit unless explicitly required

## Deployment Model

YieldNest withdrawal request deployments use upgradeable proxies and one non-upgradeable withdrawer adapter.
Distinguish these surfaces:

1. Implementation contracts
   - `Bag`, `BeaconProxyFactory`, and `WithdrawalRequest` are implementation contracts.
   - Implementations disable initializers in constructors.
   - An implementation deployment is not a configured live system.

2. WithdrawalRequest proxy
   - A live `WithdrawalRequest` instance should be an OpenZeppelin `TransparentUpgradeableProxy` pointing at a
     `WithdrawalRequest` implementation.
   - The proxy must be initialized atomically through the proxy constructor.
   - The proxy admin owner should be the intended admin/timelock owner.
   - Do not deploy or test production upgradeable instances behind ERC1967 proxies directly; this repo uses
     `TransparentUpgradeableProxy` except where beacon proxies are explicitly required for bags.

3. Bag factory proxy and bag beacon proxies
   - `BeaconProxyFactory` itself should be deployed behind `TransparentUpgradeableProxy`.
   - `BeaconProxyFactory` creates `BeaconProxy` instances for bags.
   - Bag instances are initialized with `(ownerRegistry, id)` where `ownerRegistry.ownerOf(id)` controls claim
     permissions.
   - In the withdrawal request system, `ownerRegistry` is the `WithdrawalRequest` proxy and `id` is the request NFT id.

4. BaseWithdrawer
   - `BaseWithdrawer` is currently a constructor-configured production adapter, not an upgradeable proxy.
   - It is bound to exactly one vault token and one `WithdrawalRequest` address at deployment.
   - The deployment script predicts the `WithdrawalRequest` proxy address before deploying the withdrawer. If nonce
     ordering changes, the predicted proxy verification must be updated and re-tested.

5. Initializers
   - Initialize every proxy exactly once.
   - Deploy and initialize proxies atomically, or otherwise prove there was no public window where a proxy existed
     uninitialized.
   - Do not call initializers on implementations.
   - Do not add new initializer paths without preserving upgrade safety.

## Inheritance Requirements

### Withdrawal Request Instance

Use [`src/WithdrawalRequest.sol`](src/WithdrawalRequest.sol) for a production request manager. It is concrete and
inherits:

```text
WithdrawalRequest -> Initializable, AccessControlUpgradeable, ERC721EnumerableUpgradeable,
                     PausableUpgradeable, ReentrancyGuardUpgradeable, IAuth, IResolver
```

A request manager must be initialized through `WithdrawalRequest.initialize(...)` on the proxy.

### Bag Instance

Use [`src/Bag.sol`](src/Bag.sol) for claimable asset containers. It is concrete and inherits:

```text
Bag -> Initializable, ReentrancyGuardUpgradeable, IBag
```

A bag must be initialized through `Bag.initialize(ownerRegistry, id)` by the factory-created beacon proxy. Do not
assume the bag has local ownership state; it delegates authorization to `ownerRegistry.ownerOf(id)`.

### Withdrawer Instance

Use [`src/withdrawers/BaseWithdrawer.sol`](src/withdrawers/BaseWithdrawer.sol) for the production withdrawer adapter.
Test-only withdrawers under `test/` are not production deployment candidates.

`BaseWithdrawer` implements `IWithdrawer` and forwards asset withdrawals to the configured YieldNest vault. It also
supports the vault token itself as an asset, moving locked shares into the request bag without calling the vault.

## Withdrawal Request Configuration

A normal `WithdrawalRequest` proxy is initialized with:

```solidity
WithdrawalRequest.initialize(
    address token_,
    address defaultAdmin,
    address resolver,
    address configurationManager,
    address pauser,
    address bagFactory_,
    address withdrawer_,
    address requestPolicy_,
    uint256 maxDataLength_
)
```

Parameter meanings and validation:

- `token_`
  - The yn-token whose shares are locked by requests and consumed during resolution.
  - Must implement `IWithdrawerVault`: ERC20 metadata, `withdrawAsset(...)`, and `convertToAssets(...)`.
  - The `WithdrawalRequest` contract receives and holds this token until requests are resolved or cancelled in kind.

- `defaultAdmin`
  - Receives `DEFAULT_ADMIN_ROLE`.
  - Production deployments should use the intended timelock/admin, not a temporary EOA left with authority.

- `resolver`
  - Receives `RESOLVER_ROLE`.
  - This should normally be a resolver module, not an unconstrained EOA, because it controls when and how requests are
    resolved.
  - Direct request creation is permissionless within policy limits; resolver modules must enforce any additional
    off-chain terms, ordering, deadlines, batching, fill ratios, or cancellation policy.

- `configurationManager`
  - Receives `CONFIGURATION_MANAGER_ROLE`.
  - Can update the request policy, withdrawer, and `maxDataLength`.
  - Treat this role as system-critical because a bad withdrawer can break resolution.

- `pauser`
  - Receives `PAUSER_ROLE`.
  - Can pause and unpause request creation. Pausing does not stop resolution.

- `bagFactory_`
  - Factory used to deploy request bags.
  - Must grant `CREATOR_ROLE` to the `WithdrawalRequest` proxy.
  - In the default deployment script, this is achieved by initializing the factory with the predicted proxy as creator.

- `withdrawer_`
  - Adapter called by `WithdrawalRequest.resolveWithdrawalRequest(...)`.
  - Must only allow calls from the configured `WithdrawalRequest`.
  - When `BaseWithdrawer` is used with BaseStrategy-backed vaults, grant the withdrawer fee exemption and, depending on
    vault configuration, potentially `ALLOCATOR_ROLE`.

- `requestPolicy_`
  - Policy called during request creation.
  - Current production policy is `MinAmountRequestPolicy`, but the manager supports replacement by the configuration
    manager.

- `maxDataLength_`
  - Maximum bytes accepted in request metadata.
  - Resolver modules may version and interpret `data`, but `WithdrawalRequest` only enforces length.

## Request Lifecycle

1. A user calls `requestWithdrawal(amount, receiver, data)`.
2. `requestPolicy.validateRequest(...)` must pass.
3. `amount` yn-token shares are transferred into `WithdrawalRequest`.
4. A new bag is created with `Bag.initialize(address(this), id)`.
5. A request NFT is minted to `receiver`.
6. A resolver with `RESOLVER_ROLE` calls `resolveWithdrawalRequest(...)`.
7. The withdrawer receives a temporary allowance up to the request's locked amount.
8. The withdrawer moves redeemed assets into the bag and returns the amount of yn-token shares consumed.
9. `WithdrawalRequest` verifies both yn-token balance delta and bag asset balance delta.
10. The request NFT owner claims bag assets.
11. The request NFT owner can burn the request only after locked amount is dust/zero and tracked bag assets are empty.

Do not weaken the balance-delta checks. They are the main guardrail between a resolver/withdrawer call and request
accounting.

## Cancellation And Dust

Cancellation is represented as resolution in kind, not as a separate request state.

If the resolver calls:

```solidity
resolveWithdrawalRequest(id, address(token()), request.amountLocked)
```

`BaseWithdrawer` transfers the locked vault-token shares from `WithdrawalRequest` into the request bag and returns the
same amount as consumed shares. No vault withdrawal happens and no shares are burned by the vault.

Use this path to:

- eject unredeemed shares back to the request owner through the bag
- clear residual share dust
- support resolver-level cancellation policies such as deadlines or failed fills

The resolver module, not `WithdrawalRequest`, must decide when cancellation is allowed.

## Bag Configuration

A `Bag` is a generic container. It does not know about `WithdrawalRequest` except through the `IAuth` owner registry
interface.

Production assumptions:

- `ownerRegistry.ownerOf(id)` is the only claim authority.
- If the request NFT transfers, claim authority follows the new NFT owner automatically.
- A standalone bag registry is valid only if it controls owner changes correctly.
- Bag claim functions are intentionally owner-pull based. Do not add third-party sweeping paths without a clear
  authorization model.
- `ETH` is represented by `0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE`.

## Beacon Proxy Factory Configuration

`BeaconProxyFactory.initialize(...)` takes:

```solidity
BeaconProxyFactory.initialize(
    address implementation_,
    address defaultAdmin,
    address creator,
    address implementationManager
)
```

Configuration requirements:

- `implementation_` must be the intended `Bag` implementation.
- `creator` must be the `WithdrawalRequest` proxy for the standard system.
- `implementationManager` controls all future bag implementation upgrades.
- Upgrading the beacon changes behavior for every existing and future bag proxy.
- Do not grant `CREATOR_ROLE` or `IMPLEMENTATION_MANAGER_ROLE` broadly.

## Withdrawer Configuration

`BaseWithdrawer` is deployed with:

```solidity
new BaseWithdrawer(address token_, address withdrawalRequest_)
```

Configuration requirements:

- `token_` must be the same vault token configured in `WithdrawalRequest`.
- `withdrawalRequest_` must be the live `WithdrawalRequest` proxy.
- Direct calls by anyone except `withdrawalRequest_` must revert.
- `withdrawAsset(...)` must either forward to the vault or transfer the vault token itself into the bag.
- `convertToAssets(...)` uses the configured vault's default conversion, not the per-asset `VaultMath` helper.

For BaseStrategy-backed vaults, validate any role/fee exemptions needed by the vault before production use.

## Roles

Production role surfaces:

- `WithdrawalRequest.DEFAULT_ADMIN_ROLE`
  - Admin for all request manager roles.

- `WithdrawalRequest.RESOLVER_ROLE`
  - Can resolve requests and move assets into bags.
  - This role is the main settlement authority.

- `WithdrawalRequest.CONFIGURATION_MANAGER_ROLE`
  - Can update request policy, withdrawer, and maximum data length.

- `WithdrawalRequest.PAUSER_ROLE`
  - Can pause and unpause request creation.

- `BeaconProxyFactory.DEFAULT_ADMIN_ROLE`
  - Admin for factory roles.

- `BeaconProxyFactory.CREATOR_ROLE`
  - Can create initialized bag proxies.

- `BeaconProxyFactory.IMPLEMENTATION_MANAGER_ROLE`
  - Can upgrade the shared bag implementation.

The default deployment script places admin and configuration authority behind a `TimelockController`. Validate final
role ownership after deployment and do not leave deployer-only authorities unless the deployment plan explicitly
requires them.

## Final Configuration Checklist

Before treating a deployment as production-ready, verify:

1. `WithdrawalRequest` proxy is a `TransparentUpgradeableProxy`.
2. `WithdrawalRequest` implementation has initializers disabled.
3. `WithdrawalRequest` proxy was initialized atomically with intended parameters.
4. `Bag` implementation has initializers disabled.
5. `BeaconProxyFactory` proxy is a `TransparentUpgradeableProxy`.
6. `BeaconProxyFactory` proxy was initialized atomically.
7. `BeaconProxyFactory.beacon()` points to a beacon with the intended `Bag` implementation.
8. `BeaconProxyFactory.CREATOR_ROLE` is held by the `WithdrawalRequest` proxy.
9. `BeaconProxyFactory.IMPLEMENTATION_MANAGER_ROLE` is held by the intended admin/timelock.
10. `BaseWithdrawer.token()` equals `WithdrawalRequest.token()`.
11. `BaseWithdrawer.withdrawalRequest()` equals the `WithdrawalRequest` proxy.
12. The configured resolver is the intended resolver module or authorized account.
13. The configured request policy matches the intended minimum/request policy.
14. `maxDataLength()` matches the resolver's expected request data envelope.
15. For BaseStrategy-backed vaults, withdrawer fee exemption and any required vault roles are configured.
16. Request creation, resolution, claim, cancellation-in-kind, and burn flows are tested.

## Working Rules

1. Make the smallest defensible change.
2. Do not silently change public interfaces, role semantics, request lifecycle, or storage layout.
3. Do not modify deployment artifacts, broadcast outputs, or generated files unless the task explicitly calls for it.
4. When touching request accounting, resolver behavior, bag ownership, vault conversions, or withdrawals, prefer
   additional tests over explanation-only changes.
5. When working on upgradeability-sensitive code, treat storage layout and initializer behavior as first-class
   constraints.
6. If a change affects security assumptions, state the risk clearly in the final summary.

## Source Of Truth

When inferring intent, prefer this order:

1. tests covering the touched behavior
2. concrete implementation in `src/` and `views/`
3. deployment scripts in `script/`
4. repo docs
5. audit notes and ad hoc markdown only as supporting context

If docs and tests disagree, trust tests and implementation, then call out the inconsistency.

## Commands

Run commands from the repo root.

### Install / setup

```bash
forge install
git submodule update --init --recursive
```

### Format

```bash
forge fmt
```

### Unit tests

```bash
forge test --match-path 'test/local/unit/*.t.sol'
```

### Mainnet-fork tests

Requires `ETH_MAINNET_RPC_URL`.

```bash
FOUNDRY_PROFILE=mainnet forge test
```

### Targeted tests

```bash
forge test --match-path 'test/local/unit/withdrawalrequest.t.sol'
forge test --match-path 'test/local/unit/bag.t.sol'
forge test --match-path 'test/local/unit/withdrawalrequestviewer.t.sol'
```

## Solidity-Specific Guidance

### Withdrawal request work

- Preserve locked-share accounting.
- Preserve the allowance pattern around withdrawer calls: approve before resolution, revoke after resolution.
- Preserve `InvalidTokenBalanceChange` and `UnexpectedAssetsWithdrawn` checks.
- Be explicit about share amounts vs asset amounts.
- Remember that `request.data` is length-bounded but semantically interpreted by resolver modules.

### Bag work

- Preserve owner-registry based authorization.
- Do not introduce local ownership state that can diverge from `ownerRegistry.ownerOf(id)`.
- Preserve reentrancy protection around ERC20, native ETH, and ERC721 claims.
- If adding new claim paths, test old owner vs new owner behavior after registry ownership changes.

### Upgradeable patterns

- Do not reorder or remove storage variables in upgradeable contracts.
- Use ERC-7201 namespaced storage consistently.
- Be careful with initializer flows and access-control setup.
- If a change is upgrade-sensitive, mention storage/initializer considerations in the final response.

### Vault and withdrawer integrations

- Use `IVault` directly for YieldNest vault integrations unless a narrower interface is required by
  `WithdrawalRequest`.
- Keep `IWithdrawerVault` for `WithdrawalRequest` unless intentionally changing the request manager's token contract.
- Do not assume every asset amount is a share amount; use `VaultMath.convertToAssets(...)` when converting shares into
  a specific vault asset amount.
- If changing `BaseWithdrawer`, test both underlying-asset redemption and vault-token pass-through.

## Scripts And Deployments

- Prefer existing scripts in `script/` over inventing new one-off approaches.
- Use `TransparentUpgradeableProxy` for upgradeable production deployments except beacon-created bags.
- Keep predicted address logic and deployment nonce assumptions aligned with deployed contract order.
- Keep deployment parameters and `_verifySetup()` checks aligned.
- Do not rewrite `broadcast/` outputs by hand.
- Do not commit environment-specific secrets or RPC values.

## Testing Strategy

When adding tests:

- place unit tests next to the closest existing suite
- extend existing helper/setup patterns instead of creating parallel abstractions
- keep production behavior tests out of test-only helper semantics unless the helper is explicitly the subject
- add explicit scenario coverage for edge cases
- add fork coverage when behavior depends on deployed YieldNest vault behavior

Useful existing areas:

- `test/local/unit/withdrawalrequest.t.sol`
- `test/local/unit/bag.t.sol`
- `test/local/unit/withdrawalrequestviewer.t.sol`
- `test/local/unit/demoinorderresolver.t.sol`
- `test/local/unit/fillratioresolver.t.sol`
- `test/mainnet/`

## Review Checklist

Before finalizing, check:

- Does the change preserve resolver and configuration role boundaries?
- Does it preserve storage layout and initializer safety where applicable?
- Does it preserve request custody and locked-share accounting?
- Are share amounts and asset amounts handled correctly?
- Does bag authorization still follow the current owner registry?
- Are the relevant tests run?
- Are generated artifacts left untouched unless explicitly requested?

## Final Response Expectations

In the final response:

- summarize what changed
- state what you validated
- mention any tests not run
- call out real risks, assumptions, or follow-up items

Keep it concise and technical.
