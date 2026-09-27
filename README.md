# CPPair — constant-product pair with built-in LP token

`src/CPPair.sol` is a Uniswap-V2-style constant-product automated market maker for two
ERC-20 tokens. The pair contract is itself the ERC-20 liquidity-provider token
(`CP LP` / `CPLP`, 18 decimals). It is intentionally minimal: no owner, no protocol fee,
no flash swaps, no price accumulator, no permit.

This repository is local-only. Nothing is deployed and there is no deploy script.

## Layout

| Path | Purpose |
| --- | --- |
| `src/CPPair.sol` | The pair (Solidity 0.8.26) |
| `test/CPPair.t.sol` | Unit tests for every function and revert path (70 tests, incl. 2 fuzz) |
| `test/mocks/MockERC20.sol` | 18-decimal mock token with public `mint` |
| `test/mocks/FeeOnTransferERC20.sol` | Mock that burns 1% per transfer, used to prove pulls reject fee-on-transfer |
| `test/mocks/ReentrantERC20.sol` | Mock that calls back into the pair mid-transfer, used to prove the guard |
| `lib/forge-std` | forge-std v1.9.7 vendored as plain files (no submodule) |
| `foundry.toml`, `remappings.txt` | Compiler pinned to `solc = "0.8.26"`, EVM `cancun`, `ffi = false`, no fs permissions |

Run:

```
forge build
forge test
forge fmt --check
```

Tests read no environment variables, use no `ffi`, and do not depend on the caller address,
so they pass in any order and in parallel.

## Interface

```solidity
constructor(address token0, address token1);               // non-zero, distinct

function addLiquidity(uint256 amount0Desired, uint256 amount1Desired, uint256 minShares, address to)
    external returns (uint256 amount0, uint256 amount1, uint256 shares);
function removeLiquidity(uint256 shares, uint256 min0, uint256 min1, address to)
    external returns (uint256 amount0, uint256 amount1);
function swapExactIn(address tokenIn, uint256 amountIn, uint256 minOut, address to)
    external returns (uint256 amountOut);
function sync() external;
function skim(address to) external;

function getReserves() external view returns (uint112 reserve0, uint112 reserve1);
function quote(uint256 amountIn, address tokenIn) external view returns (uint256 amountOut);

// ERC-20: name, symbol, decimals, totalSupply, balanceOf, allowance, approve, transfer, transferFrom
```

Events: `Mint`, `Burn`, `Swap`, `Sync`, plus ERC-20 `Transfer` and `Approval`.

### Semantics

- **Reserves** are two `uint112` values in storage. They change only inside
  `addLiquidity`, `removeLiquidity`, `swapExactIn`, `sync` and `skim`. Tokens sent directly to
  the pair ("donations") raise the raw balance but not the reserve until `sync` folds them in
  or `skim` sends them out. Any update that would exceed `uint112` reverts with `ReserveOverflow`.
- **First deposit** takes both desired amounts in full, mints `sqrt(a0 * a1) - 1000` shares to
  `to` and 1000 shares to `0x000000000000000000000000000000000000dEaD`. Nobody controls that
  address, so total supply never returns to zero and the pool always retains a residual reserve.
  Reverts with `InsufficientInitialLiquidity` if `sqrt(a0 * a1) <= 1000`.
- **Later deposits** pull the largest pair matching the current reserve ratio that fits inside
  both desired amounts, then mint `min(a0 * S / r0, a1 * S / r1)` rounded down. Untaken desired
  amounts are never pulled. Reverts with `InsufficientSharesMinted` when shares are zero or
  below `minShares`.
- **Removal** burns `shares` from `msg.sender` and pays `shares * reserve / totalSupply` of each
  token, rounded down. Reverts with `InsufficientShares` for zero shares, `InsufficientOutput`
  when either payout is zero or below its minimum, and `InsufficientBalance` when the caller
  holds fewer shares than requested.
- **Swaps** charge 0.3% on the input:
  `out = floor(amountIn * 997 * rOut / (rIn * 1000 + amountIn * 997))`. Reverts with
  `UnknownToken` for a token that is neither `token0` nor `token1`, and `InsufficientOutput`
  for zero output or output below `minOut`. `quote` returns the same number without state
  change (0 for an empty pool or dust input) and reverts only on an unknown token.
- **sync / skim** are permissionless, as in Uniswap V2. `sync` sets reserves to the current
  balances; `skim(to)` sends `balance - reserve` of each token to `to`.
- **Token pulls** compare the pair's balance before and after `transferFrom` and revert with
  `FeeOnTransfer` if the received amount differs from the requested one. A transfer that
  reverts or returns `false` surfaces as `TransferFailed`. Tokens that return no data
  (USDT-style) are accepted.
- **Reentrancy**: every state-changing function (`addLiquidity`, `removeLiquidity`,
  `swapExactIn`, `sync`, `skim`) is guarded by a single lock. Storage effects (shares, reserves,
  events) are applied before any external token call. A callback that re-enters during a
  transfer sees `Reentrancy()`.
- **ERC-20**: standard behaviour. Transfers and mints to the zero address revert with
  `ZeroAddress`. An allowance of `type(uint256).max` is not decremented.

## Assumptions

- Both tokens are ordinary ERC-20s with 18 decimals in the tests. The contract itself does
  not read `decimals()` and works with any decimals, but a token whose balance can change
  without a transfer (rebasing) or that takes a fee on transfer is **not supported**: deposits
  and swaps in a fee token revert, and rebases desynchronise balances from reserves until
  `sync`/`skim` is called.
- `token0` and `token1` are not validated to have code. Deploying against a non-contract
  address produces a pair whose every pull reverts with `TransferFailed`.
- Prices are read directly from reserves and can be moved within a single transaction. The
  pair is not a safe oracle; there is no TWAP accumulator by design.
- The 1000-share minimum liquidity bounds but does not eliminate first-depositor rounding
  games. A first deposit of `1001 x 1001` wei is valid and mints one share to the depositor.
- Later deposits assume both reserves are non-zero once supply is non-zero. This holds because
  the first deposit requires both amounts to be positive and removals revert on a zero payout.

## Deployment parameters

There is no deploy script in this assignment (local-only scope). If deployed, the only
parameters are the two token addresses passed to the constructor. There are no admin keys,
upgrade paths, fee switches or pausers to configure afterwards.

## Operational responsibilities

- Nobody operates the pair after deployment: it has no owner and no privileged functions.
- Integrators must set `minShares`, `min0`, `min1` and `minOut` to protect against price
  movement between quoting and execution; the pair enforces only what the caller passes.
- Anyone may call `sync` or `skim`. Tokens sent to the pair outside `addLiquidity` are a gift to
  whoever calls `skim` next, or to all LPs if `sync` is called first.
- Because reserves are `uint112`, pools with more than roughly `5.19e33` base units of either
  token cannot exist; deposits or syncs that would exceed this revert.

## Out of scope for this assignment

Stateful invariant tests (solvency, k-monotonicity under random sequences, share accounting)
are assigned to a second worker. The unit suite here includes two bounded fuzz tests as a
sanity check but is not a substitute for that work or for an independent security review.
