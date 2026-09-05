# Withdrawal Request Frontend Guide

This guide describes the current generic withdrawal request flow for frontend integration.

## Contracts

- `WithdrawalRequest`: request manager and ERC721 request NFT.
- `WithdrawalRequestViewer`: read-only helper for request, bag, balance, rate, and claim state.
- `Bag`: per-request asset container where resolved assets are held until claimed.

The frontend should treat the deployed `WithdrawalRequest` proxy as the primary protocol contract and the deployed
`WithdrawalRequestViewer` as the preferred read API.

## Core Flow

### 1. Read System Configuration

Read the configured vault share token from the manager:

```solidity
WithdrawalRequest.token()
```

Read the minimum request size through the viewer:

```solidity
WithdrawalRequestViewer.minWithdrawalAmount(withdrawalRequest)
```

The minimum is denominated in the configured vault share token units.

For display, the frontend may also read the current redemption-rate conversion:

```solidity
WithdrawalRequestViewer.convertToAssetsAtRedemptionRate(withdrawalRequest, shares)
```

This converts vault shares into default-asset units using the currently configured withdrawer. For the base withdrawer,
this follows the vault's live `convertToAssets` behavior.

### 2. User Approves Shares

The user approves the configured vault share token to the deployed `WithdrawalRequest` proxy.

- Token: `WithdrawalRequest.token()`
- Spender: deployed `WithdrawalRequest` proxy
- Amount: vault shares the user wants to lock

### 3. User Creates A Withdrawal Request

The user creates a request with either:

```solidity
requestWithdrawal(uint256 amount, address receiver)
requestWithdrawal(uint256 amount, address receiver, bytes data)
```

- `amount` is denominated in vault shares.
- `receiver` receives the withdrawal request NFT.
- `data` is optional bounded metadata for resolver-specific terms.

On success, the manager:

1. Transfers `amount` shares from the user to the manager.
2. Creates a dedicated Bag for the request.
3. Stores request data.
4. Mints the request NFT to `receiver`.
5. Emits `WithdrawalRequested`.

The returned request id is also the ERC721 token id.

### 4. Request Ownership Is The NFT

`WithdrawalRequest` is an ERC721. The request NFT is the transferable user position.

Useful ERC721 reads:

```solidity
ownerOf(requestId)
balanceOf(user)
tokenOfOwnerByIndex(user, index)
```

The Bag is not the NFT. It is a per-request asset container. Claim authority follows the current owner of the request
NFT through `WithdrawalRequest.ownerOf(requestId)`.

Only the current request NFT owner can claim assets from the Bag. ERC721 approvals or operators are not enough to claim.

### 5. UI Tracks Requests Through The Viewer

For a single request, use:

```solidity
WithdrawalRequestViewer.getRequest(withdrawalRequest, requestId)
```

For a user's request dashboard, use:

```solidity
WithdrawalRequestViewer.getInProgressRequestsForOwner(withdrawalRequest, user)
```

Each returned `RequestView` contains:

```solidity
struct RequestView {
    uint256 id;
    address owner;
    address bag;
    address token;
    uint256 amountLocked;
    uint256 rateAtRequest;
    bytes data;
    uint256 tokenBalance;
    bool isClaimable;
    bool isClaimed;
    AssetBalance[] assetBalances;
}
```

`assetBalances` contains the redeemed assets currently tracked for the request:

```solidity
struct AssetBalance {
    address asset;
    uint256 balance;
}
```

These balances are read from the request's Bag. They are the assets the frontend should show as available to claim.

### 6. Resolver Resolves Requests

Resolution is permissioned. A user does not normally trigger settlement directly.

A resolver with `RESOLVER_ROLE` calls:

```solidity
resolveWithdrawalRequest(uint256 id, address asset, uint256 assets)
resolveWithdrawalRequest(uint256 id, address[] assets, uint256[] assetAmounts)
```

The configured withdrawer performs the vault withdrawal and sends received assets into the request's Bag.

`amountLocked` decreases by the actual vault shares consumed. The asset amount received by the Bag is measured and
emitted in `WithdrawalRequestResolved`.

For resolver tooling, the viewer exposes:

```solidity
WithdrawalRequestViewer.convertToAssets(withdrawalRequest, asset, shares)
WithdrawalRequestViewer.maxResolutionAssets(withdrawalRequest, requestId, asset)
```

These helpers are for estimating or bounding resolver inputs. They should not be shown as a guaranteed user claim
amount.

### 7. User Claims Assets From The Bag

Resolved assets are not automatically pushed to the user. They accumulate in the request's Bag until the request NFT
owner claims them.

A user can claim assets from the same request multiple times. This matters when a request is resolved in multiple
tranches.

To claim, call `claim` on the request's Bag address:

```solidity
Bag.claim(address[] assets, address payable recipient, uint256[] amounts)
```

The Bag address is available in `RequestView.bag`.

For the best user experience, the frontend should claim all currently available redeemed assets in one transaction:

1. Read `RequestView.assetBalances`.
2. Filter for entries where `balance > 0`.
3. Pass all filtered `asset` values as `assets`.
4. Pass the corresponding `balance` values as `amounts`.
5. Use the user's selected destination as `recipient`.

Native ETH is represented by the Bag's `ETH()` constant:

```solidity
Bag.ETH()
```

### 8. Determine Whether Claiming Is Finished

Use:

```solidity
WithdrawalRequestViewer.requestIsClaimed(withdrawalRequest, requestId)
```

or the `RequestView.isClaimed` field from `getRequest` / `getInProgressRequestsForOwner`.

`isClaimed == true` means the request is considered claimable/redeemed and all tracked redeemed asset balances in the
Bag are zero. This is the field the frontend should use to determine that the claiming process is finished.

`RequestView.isClaimable` is a UI heuristic based on remaining locked-share dust. It means most or all of the requested
shares have been resolved, but it is not the same as "all assets have been claimed."

### 9. Optional Cleanup: Burn Completed Request NFT

After a request is fully resolved and all tracked Bag asset balances have been claimed, the NFT owner can burn the
request:

```solidity
WithdrawalRequest.burn(requestId)
```

Burning deletes the stored request and burns the ERC721 token. The frontend should only offer this after
`RequestView.isClaimed == true`.

