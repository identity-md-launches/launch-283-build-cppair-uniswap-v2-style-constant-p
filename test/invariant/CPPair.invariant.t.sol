// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {CPPair} from "../../src/CPPair.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {FullMath} from "./FullMath.sol";
import {CPPairHandler} from "./CPPairHandler.sol";

/// @title CPPair stateful invariant suite
/// @notice Four actors add, remove, swap both ways, round-trip, donate, sync, skim and move LP
///         shares through `CPPairHandler`. Per-call properties (k across swaps, share value across
///         add/remove/swap/sync, pro-rata payouts, sync/skim balance equalities, round-trip loss and
///         every revert path) are asserted inside the handler; the global properties below are
///         re-checked after every call. `fail-on-revert` is on, so an unexpected revert anywhere,
///         including a failed assertion inside the handler, fails the campaign.
/// forge-config: default.invariant.runs = 1000
/// forge-config: default.invariant.depth = 100
/// forge-config: default.invariant.fail-on-revert = true
contract CPPairInvariantTest is Test {
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    /// @dev Storage slot of CPPair's `_lock` (totalSupply=0, balanceOf=1, allowance=2, reserves=3).
    uint256 internal constant LOCK_SLOT = 4;
    uint256 internal constant UNLOCKED = 1;

    MockERC20 internal token0;
    MockERC20 internal token1;
    CPPair internal pair;
    CPPairHandler internal handler;

    function setUp() public {
        token0 = new MockERC20("Token A", "TKA");
        token1 = new MockERC20("Token B", "TKB");
        pair = new CPPair(address(token0), address(token1));
        handler = new CPPairHandler(pair, token0, token1);

        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = CPPairHandler.addLiquidity.selector;
        selectors[1] = CPPairHandler.removeLiquidity.selector;
        selectors[2] = CPPairHandler.removeAll.selector;
        selectors[3] = CPPairHandler.swap.selector;
        selectors[4] = CPPairHandler.swapRoundTrip.selector;
        selectors[5] = CPPairHandler.donate.selector;
        selectors[6] = CPPairHandler.sync.selector;
        selectors[7] = CPPairHandler.skim.selector;
        selectors[8] = CPPairHandler.transferShares.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    // ── Solvency and accounting ──────────────────────────────────────────────

    /// @notice Stored reserves never exceed the pair's actual token balances, and the surplus is
    ///         exactly what was donated since the last sync/skim.
    function invariant_reservesNeverExceedBalances() public view {
        (uint112 r0, uint112 r1) = pair.getReserves();
        uint256 bal0 = token0.balanceOf(address(pair));
        uint256 bal1 = token1.balanceOf(address(pair));
        assertLe(uint256(r0), bal0, "reserve0 > balance0");
        assertLe(uint256(r1), bal1, "reserve1 > balance1");
        assertEq(bal0 - uint256(r0), handler.donated0(), "unexplained token0 surplus");
        assertEq(bal1 - uint256(r1), handler.donated1(), "unexplained token1 surplus");
    }

    /// @notice Total supply equals the sum of every holder's balance (actors plus the burn address).
    function invariant_supplyMatchesHolders() public view {
        uint256 sum = pair.balanceOf(DEAD);
        uint256 n = handler.actorsLength();
        for (uint256 i = 0; i < n; i++) {
            sum += pair.balanceOf(handler.actors(i));
        }
        assertEq(sum, pair.totalSupply(), "supply != sum of holder balances");
    }

    /// @notice Once initialised, the 1000 dead shares are locked forever and keep both reserves
    ///         strictly positive; before initialisation nothing has been minted.
    function invariant_deadSharesKeepPoolAlive() public view {
        if (!handler.initialised()) {
            assertEq(pair.totalSupply(), 0, "supply before first deposit");
            assertEq(pair.balanceOf(DEAD), 0, "dead shares before first deposit");
            return;
        }
        (uint112 r0, uint112 r1) = pair.getReserves();
        assertEq(pair.balanceOf(DEAD), 1000, "dead shares changed");
        assertGe(pair.totalSupply(), 1000, "supply below dead shares");
        assertGt(uint256(r0), 0, "reserve0 hit zero");
        assertGt(uint256(r1), 0, "reserve1 hit zero");
    }

    /// @notice The value of one LP share, k / totalSupply^2, never falls below its value right after
    ///         the first deposit: mulDiv(kNow, S0^2, SNow^2) >= k0, computed with a 512-bit product.
    function invariant_shareValueNeverBelowInitial() public view {
        if (!handler.initialised()) return;
        (uint112 r0, uint112 r1) = pair.getReserves();
        uint256 kNow = uint256(r0) * uint256(r1);
        uint256 sNow = pair.totalSupply();
        uint256 s0 = handler.initialSupply();
        // A quotient that overflows 256 bits (huge donation synced onto few shares) is trivially >= k0.
        assertTrue(FullMath.mulDivGe(kNow, s0 * s0, sNow * sNow, handler.initialK()), "share value below initial");
    }

    /// @notice The reentrancy lock is released after every call, and `quote` is consistent with
    ///         the reserves the next swap would use.
    function invariant_lockReleasedAndQuoteConsistent() public view {
        assertEq(uint256(vm.load(address(pair), bytes32(LOCK_SLOT))), UNLOCKED, "lock left engaged");
        (uint112 r0, uint112 r1) = pair.getReserves();
        uint256 amountIn = 1e18;
        uint256 expected0 =
            (r0 == 0 || r1 == 0) ? 0 : (amountIn * 997 * uint256(r1)) / (uint256(r0) * 1000 + amountIn * 997);
        uint256 expected1 =
            (r0 == 0 || r1 == 0) ? 0 : (amountIn * 997 * uint256(r0)) / (uint256(r1) * 1000 + amountIn * 997);
        assertEq(pair.quote(amountIn, address(token0)), expected0, "quote token0");
        assertEq(pair.quote(amountIn, address(token1)), expected1, "quote token1");
    }
}
