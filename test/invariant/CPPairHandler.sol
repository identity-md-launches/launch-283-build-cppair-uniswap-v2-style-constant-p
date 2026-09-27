// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {CPPair} from "../../src/CPPair.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {FullMath} from "./FullMath.sol";

/// @title CPPairHandler
/// @notice Stateful handler for the CPPair invariant campaign. Several actors add, remove,
///         swap both ways, round-trip, donate tokens directly, sync, skim and move LP shares.
/// @dev Every handler call is meant to succeed: inputs are bounded and the expected outcome is
///      computed beforehand, so the invariant test runs with `fail-on-revert = true`. Failure
///      paths are exercised deliberately inside the handlers with try/catch probes that assert
///      the exact custom error, so a call that stops reverting is a test failure too.
///      Properties checked here, before and after each call, rather than in the invariant contract:
///      - reserve0 * reserve1 never decreases across a swap;
///      - k / totalSupply^2 never decreases across add, remove, swap and sync
///        (mulDiv(kAfter, supplyBefore^2, supplyAfter^2) >= kBefore, 512-bit intermediate);
///      - removing shares never pays more than shares / totalSupply of each reserve;
///      - reserves equal balances right after sync(); balances equal reserves right after skim();
///      - a swap followed by the reverse swap never returns more than the original input.
contract CPPairHandler is Test {
    CPPair public immutable pair;
    MockERC20 public immutable token0;
    MockERC20 public immutable token1;

    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 public constant MINIMUM_LIQUIDITY = 1000;

    /// @dev Amounts are drawn log-uniformly in [1, 10^MAX_EXP] so both the wei-level rounding
    ///      regime and the whale regime are hit. 100 calls * 1e27 stays far below uint112.max.
    uint256 internal constant MAX_EXP = 27;

    address[] public actors;

    // ── Ghost state ──────────────────────────────────────────────────────────
    /// @notice True once the first successful addLiquidity has minted the 1000 dead shares.
    bool public initialised;
    /// @notice k and totalSupply right after the first successful deposit.
    uint256 public initialK;
    uint256 public initialSupply;
    /// @notice Tokens sent to the pair outside addLiquidity/swap, per token.
    uint256 public donated0;
    uint256 public donated1;

    // Call counters (for a readable summary and to make sure every path is reached).
    mapping(bytes32 => uint256) public calls;

    constructor(CPPair pair_, MockERC20 token0_, MockERC20 token1_) {
        pair = pair_;
        token0 = token0_;
        token1 = token1_;

        actors.push(makeAddr("alice"));
        actors.push(makeAddr("bob"));
        actors.push(makeAddr("carol"));
        actors.push(makeAddr("dave"));
        for (uint256 i = 0; i < actors.length; i++) {
            vm.startPrank(actors[i]);
            token0.approve(address(pair), type(uint256).max);
            token1.approve(address(pair), type(uint256).max);
            vm.stopPrank();
        }
    }

    function actorsLength() external view returns (uint256) {
        return actors.length;
    }

    // ── Modifiers ────────────────────────────────────────────────────────────

    modifier useActor(uint256 seed) {
        address actor = actors[seed % actors.length];
        vm.startPrank(actor);
        _;
        vm.stopPrank();
    }

    modifier countCall(bytes32 key) {
        calls[key]++;
        _;
    }

    /// @dev The value of one LP share, k / S^2, must never fall across the wrapped call.
    modifier checksShareValue() {
        (uint256 kBefore, uint256 supplyBefore) = _kAndSupply();
        _;
        (uint256 kAfter, uint256 supplyAfter) = _kAndSupply();
        // mulDiv(kAfter, supplyBefore^2, supplyAfter^2) >= kBefore. A quotient too large for 256 bits
        // (donate + sync onto the 1000 dead shares) is trivially >= kBefore and counts as satisfied.
        if (supplyBefore != 0 && supplyAfter != 0) {
            assertTrue(
                FullMath.mulDivGe(kAfter, supplyBefore * supplyBefore, supplyAfter * supplyAfter, kBefore),
                "share value k/S^2 fell"
            );
        }
    }

    // ── addLiquidity ─────────────────────────────────────────────────────────

    /// @dev Snapshot of the state an add/remove call starts from, plus what the spec says it must do.
    struct Snapshot {
        uint256 r0;
        uint256 r1;
        uint256 supply;
        uint256 bal0;
        uint256 bal1;
        uint256 lp;
        uint256 expect0;
        uint256 expect1;
        uint256 expectShares;
    }

    function addLiquidity(uint256 actorSeed, uint256 seed0, uint256 seed1)
        external
        useActor(actorSeed)
        countCall("addLiquidity")
        checksShareValue
    {
        address actor = _actor(actorSeed);
        uint256 desired0 = _logBound(seed0);
        uint256 desired1 = _logBound(seed1);
        token0.mint(actor, desired0);
        token1.mint(actor, desired1);

        Snapshot memory s = _snapshot(actor);
        if (s.supply == 0) {
            uint256 root = _sqrt(desired0 * desired1);
            if (root <= MINIMUM_LIQUIDITY) {
                calls["addLiquidity.revertInitial"]++;
                _expectAddRevert(desired0, desired1, 0, actor, CPPair.InsufficientInitialLiquidity.selector);
                return;
            }
            s.expect0 = desired0;
            s.expect1 = desired1;
            s.expectShares = root - MINIMUM_LIQUIDITY;
        } else {
            uint256 optimal1 = (desired0 * s.r1) / s.r0;
            if (optimal1 <= desired1) {
                (s.expect0, s.expect1) = (desired0, optimal1);
            } else {
                (s.expect0, s.expect1) = ((desired1 * s.r0) / s.r1, desired1);
            }
            uint256 shares0 = (s.expect0 * s.supply) / s.r0;
            uint256 shares1 = (s.expect1 * s.supply) / s.r1;
            s.expectShares = shares0 < shares1 ? shares0 : shares1;
            if (s.expectShares == 0) {
                calls["addLiquidity.revertZeroShares"]++;
                _expectAddRevert(desired0, desired1, 0, actor, CPPair.InsufficientSharesMinted.selector);
                return;
            }
        }

        // Failure paths from the same state: slippage guard and zero recipient.
        _expectAddRevert(desired0, desired1, s.expectShares + 1, actor, CPPair.InsufficientSharesMinted.selector);
        _expectAddRevert(desired0, desired1, 0, address(0), CPPair.ZeroAddress.selector);

        (uint256 amount0, uint256 amount1, uint256 shares) =
            pair.addLiquidity(desired0, desired1, s.expectShares, actor);

        assertLe(amount0, desired0, "add: pulled more token0 than desired");
        assertLe(amount1, desired1, "add: pulled more token1 than desired");
        _checkAdd(actor, s, amount0, amount1, shares);
    }

    function _checkAdd(address actor, Snapshot memory s, uint256 amount0, uint256 amount1, uint256 shares) internal {
        assertEq(amount0, s.expect0, "add: amount0");
        assertEq(amount1, s.expect1, "add: amount1");
        assertEq(shares, s.expectShares, "add: shares");
        assertEq(token0.balanceOf(actor), s.bal0 - amount0, "add: actor token0");
        assertEq(token1.balanceOf(actor), s.bal1 - amount1, "add: actor token1");
        assertEq(pair.balanceOf(actor), s.lp + shares, "add: actor LP");
        assertEq(pair.totalSupply(), s.supply + shares + (s.supply == 0 ? MINIMUM_LIQUIDITY : 0), "add: supply");

        (uint112 n0, uint112 n1) = pair.getReserves();
        assertEq(uint256(n0), s.r0 + amount0, "add: reserve0");
        assertEq(uint256(n1), s.r1 + amount1, "add: reserve1");

        if (!initialised) {
            initialised = true;
            initialK = uint256(n0) * uint256(n1);
            initialSupply = pair.totalSupply();
            assertEq(pair.balanceOf(DEAD), MINIMUM_LIQUIDITY, "add: dead shares");
        }
    }

    function _snapshot(address actor) internal view returns (Snapshot memory s) {
        (uint112 r0, uint112 r1) = pair.getReserves();
        s.r0 = uint256(r0);
        s.r1 = uint256(r1);
        s.supply = pair.totalSupply();
        s.bal0 = token0.balanceOf(actor);
        s.bal1 = token1.balanceOf(actor);
        s.lp = pair.balanceOf(actor);
    }

    // ── removeLiquidity ──────────────────────────────────────────────────────

    function removeLiquidity(uint256 actorSeed, uint256 sharesSeed)
        external
        useActor(actorSeed)
        countCall("removeLiquidity")
        checksShareValue
    {
        address actor = _actor(actorSeed);
        uint256 held = pair.balanceOf(actor);
        if (held == 0) {
            calls["removeLiquidity.noShares"]++;
            _expectRemoveRevert(0, 0, 0, actor, CPPair.InsufficientShares.selector);
            if (pair.totalSupply() != 0) {
                (uint112 r0, uint112 r1) = pair.getReserves();
                uint256 supply = pair.totalSupply();
                // One share pays either something (balance check fails) or nothing (output check fails).
                bytes4 expected = (uint256(r0) / supply == 0 || uint256(r1) / supply == 0)
                    ? CPPair.InsufficientOutput.selector
                    : CPPair.InsufficientBalance.selector;
                _expectRemoveRevert(1, 0, 0, actor, expected);
            }
            return;
        }
        _remove(actor, _bound(sharesSeed, 1, held));
    }

    /// @notice Removes every share the actor holds; the pool must survive on the dead shares.
    function removeAll(uint256 actorSeed) external useActor(actorSeed) countCall("removeAll") checksShareValue {
        address actor = _actor(actorSeed);
        uint256 held = pair.balanceOf(actor);
        if (held == 0) return;
        // A dust holding whose payout rounds to zero cannot be removed; _remove asserts that revert.
        if (!_remove(actor, held)) return;
        calls["removeAll.completed"]++;
        assertEq(pair.balanceOf(actor), 0, "removeAll: leftover shares");
        (uint112 r0, uint112 r1) = pair.getReserves();
        assertGt(uint256(r0), 0, "removeAll: reserve0 drained");
        assertGt(uint256(r1), 0, "removeAll: reserve1 drained");
        assertGe(pair.totalSupply(), MINIMUM_LIQUIDITY, "removeAll: supply below dead shares");
    }

    /// @dev Removes `shares` for `actor` (already pranked). Returns false when the payout rounds to
    ///      zero, after asserting the InsufficientOutput revert.
    function _remove(address actor, uint256 shares) internal returns (bool removed) {
        Snapshot memory s = _snapshot(actor);
        s.expect0 = (shares * s.r0) / s.supply;
        s.expect1 = (shares * s.r1) / s.supply;
        s.expectShares = shares;

        if (s.expect0 == 0 || s.expect1 == 0) {
            calls["removeLiquidity.revertZeroOutput"]++;
            _expectRemoveRevert(shares, 0, 0, actor, CPPair.InsufficientOutput.selector);
            return false;
        }

        // Failure paths: each minimum one above the payout, and one share more than held.
        _expectRemoveRevert(shares, s.expect0 + 1, s.expect1, actor, CPPair.InsufficientOutput.selector);
        _expectRemoveRevert(shares, s.expect0, s.expect1 + 1, actor, CPPair.InsufficientOutput.selector);
        _expectRemoveRevert(s.lp + 1, 0, 0, actor, CPPair.InsufficientBalance.selector);

        (uint256 amount0, uint256 amount1) = pair.removeLiquidity(shares, s.expect0, s.expect1, actor);
        _checkRemove(actor, s, amount0, amount1);
        return true;
    }

    function _checkRemove(address actor, Snapshot memory s, uint256 amount0, uint256 amount1) internal {
        uint256 shares = s.expectShares;
        assertEq(amount0, s.expect0, "remove: amount0");
        assertEq(amount1, s.expect1, "remove: amount1");
        // Never more than the pro-rata share of each reserve: amount * S <= shares * reserve.
        assertLe(amount0 * s.supply, shares * s.r0, "remove: paid more than pro-rata token0");
        assertLe(amount1 * s.supply, shares * s.r1, "remove: paid more than pro-rata token1");
        assertLt(amount0, s.r0, "remove: drained reserve0");
        assertLt(amount1, s.r1, "remove: drained reserve1");

        assertEq(token0.balanceOf(actor), s.bal0 + amount0, "remove: actor token0");
        assertEq(token1.balanceOf(actor), s.bal1 + amount1, "remove: actor token1");
        assertEq(pair.balanceOf(actor), s.lp - shares, "remove: actor LP");
        assertEq(pair.totalSupply(), s.supply - shares, "remove: supply");
        (uint112 n0, uint112 n1) = pair.getReserves();
        assertEq(uint256(n0), s.r0 - amount0, "remove: reserve0");
        assertEq(uint256(n1), s.r1 - amount1, "remove: reserve1");
    }

    // ── swapExactIn ──────────────────────────────────────────────────────────

    function swap(uint256 actorSeed, uint256 amountSeed, bool zeroForOne)
        external
        useActor(actorSeed)
        countCall("swap")
        checksShareValue
    {
        address actor = _actor(actorSeed);
        uint256 amountIn = _logBound(amountSeed);
        MockERC20 tokenIn = zeroForOne ? token0 : token1;
        tokenIn.mint(actor, amountIn);

        // Failure path: a token the pair does not know, for both swap and quote.
        _expectSwapRevert(address(this), amountIn, 0, actor, CPPair.UnknownToken.selector);
        try pair.quote(amountIn, address(this)) {
            assertTrue(false, "quote: unknown token accepted");
        } catch (bytes memory err) {
            assertEq(err, abi.encodeWithSelector(CPPair.UnknownToken.selector), "quote: wrong error");
        }

        _swap(actor, zeroForOne, amountIn);
    }

    /// @notice Swap `amountIn`, then swap the whole output back. Fees make the round trip lossy.
    function swapRoundTrip(uint256 actorSeed, uint256 amountSeed, bool zeroForOne)
        external
        useActor(actorSeed)
        countCall("swapRoundTrip")
        checksShareValue
    {
        address actor = _actor(actorSeed);
        uint256 amountIn = _logBound(amountSeed);
        (zeroForOne ? token0 : token1).mint(actor, amountIn);

        uint256 out = _swap(actor, zeroForOne, amountIn);
        if (out == 0) return; // first leg reverted with zero output; nothing to swap back
        uint256 back = _swap(actor, !zeroForOne, out);
        assertLe(back, amountIn, "round trip returned more than the input");
        calls["swapRoundTrip.completed"]++;
    }

    /// @dev Executes one swap by `actor` (already pranked) and returns the output; returns 0 after
    ///      asserting the InsufficientOutput revert when the quote rounds to zero.
    struct SwapState {
        bool zeroForOne;
        uint256 amountIn;
        uint256 reserveIn;
        uint256 reserveOut;
        uint256 kBefore;
        uint256 supply;
        uint256 inBefore;
        uint256 outBefore;
        uint256 expected;
    }

    function _swap(address actor, bool zeroForOne, uint256 amountIn) internal returns (uint256 out) {
        SwapState memory w;
        w.zeroForOne = zeroForOne;
        w.amountIn = amountIn;
        {
            (uint112 r0, uint112 r1) = pair.getReserves();
            (w.reserveIn, w.reserveOut) = zeroForOne ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
            w.kBefore = uint256(r0) * uint256(r1);
        }
        MockERC20 tokenIn = zeroForOne ? token0 : token1;
        MockERC20 tokenOut = zeroForOne ? token1 : token0;

        w.expected = _amountOut(amountIn, w.reserveIn, w.reserveOut);
        assertEq(pair.quote(amountIn, address(tokenIn)), w.expected, "quote != formula");
        if (w.expected == 0) {
            calls["swap.revertZeroOutput"]++;
            _expectSwapRevert(address(tokenIn), amountIn, 0, actor, CPPair.InsufficientOutput.selector);
            return 0;
        }
        // Failure path: minOut one above what the curve pays.
        _expectSwapRevert(address(tokenIn), amountIn, w.expected + 1, actor, CPPair.InsufficientOutput.selector);

        w.supply = pair.totalSupply();
        w.inBefore = tokenIn.balanceOf(actor);
        w.outBefore = tokenOut.balanceOf(actor);

        out = pair.swapExactIn(address(tokenIn), amountIn, w.expected, actor);
        _checkSwap(actor, w, out);
    }

    function _checkSwap(address actor, SwapState memory w, uint256 out) internal view {
        MockERC20 tokenIn = w.zeroForOne ? token0 : token1;
        MockERC20 tokenOut = w.zeroForOne ? token1 : token0;
        assertEq(out, w.expected, "swap: output != formula");
        assertLt(out, w.reserveOut, "swap: drained output reserve");
        assertEq(tokenIn.balanceOf(actor), w.inBefore - w.amountIn, "swap: actor tokenIn");
        assertEq(tokenOut.balanceOf(actor), w.outBefore + out, "swap: actor tokenOut");

        (uint112 n0, uint112 n1) = pair.getReserves();
        // reserve0 * reserve1 fits in 224 bits, so the plain product is exact.
        assertGe(uint256(n0) * uint256(n1), w.kBefore, "swap: k decreased");
        (uint256 newIn, uint256 newOut) = w.zeroForOne ? (uint256(n0), uint256(n1)) : (uint256(n1), uint256(n0));
        assertEq(newIn, w.reserveIn + w.amountIn, "swap: reserveIn");
        assertEq(newOut, w.reserveOut - out, "swap: reserveOut");
        assertEq(pair.totalSupply(), w.supply, "swap: supply changed");
    }

    // ── donate / sync / skim ─────────────────────────────────────────────────

    /// @notice Sends tokens straight to the pair, bypassing addLiquidity. Reserves must not move.
    function donate(uint256 amountSeed, bool which) external countCall("donate") {
        uint256 amount = _logBound(amountSeed);
        (uint112 r0, uint112 r1) = pair.getReserves();
        if (which) {
            token0.mint(address(pair), amount);
            donated0 += amount;
        } else {
            token1.mint(address(pair), amount);
            donated1 += amount;
        }
        (uint112 n0, uint112 n1) = pair.getReserves();
        assertEq(n0, r0, "donate: reserve0 moved");
        assertEq(n1, r1, "donate: reserve1 moved");
    }

    function sync(uint256 actorSeed) external useActor(actorSeed) countCall("sync") checksShareValue {
        (uint112 r0, uint112 r1) = pair.getReserves();
        uint256 supply = pair.totalSupply();

        pair.sync();

        (uint112 n0, uint112 n1) = pair.getReserves();
        assertEq(uint256(n0), token0.balanceOf(address(pair)), "sync: reserve0 != balance0");
        assertEq(uint256(n1), token1.balanceOf(address(pair)), "sync: reserve1 != balance1");
        assertGe(n0, r0, "sync: reserve0 fell");
        assertGe(n1, r1, "sync: reserve1 fell");
        assertEq(pair.totalSupply(), supply, "sync: supply changed");
        donated0 = 0;
        donated1 = 0;
    }

    function skim(uint256 actorSeed) external useActor(actorSeed) countCall("skim") checksShareValue {
        address actor = _actor(actorSeed);
        (uint112 r0, uint112 r1) = pair.getReserves();
        uint256 supply = pair.totalSupply();
        uint256 excess0 = token0.balanceOf(address(pair)) - uint256(r0);
        uint256 excess1 = token1.balanceOf(address(pair)) - uint256(r1);
        uint256 bal0Before = token0.balanceOf(actor);
        uint256 bal1Before = token1.balanceOf(actor);

        pair.skim(actor);

        (uint112 n0, uint112 n1) = pair.getReserves();
        assertEq(n0, r0, "skim: reserve0 moved");
        assertEq(n1, r1, "skim: reserve1 moved");
        assertEq(token0.balanceOf(address(pair)), uint256(r0), "skim: balance0 != reserve0");
        assertEq(token1.balanceOf(address(pair)), uint256(r1), "skim: balance1 != reserve1");
        assertEq(token0.balanceOf(actor), bal0Before + excess0, "skim: recipient token0");
        assertEq(token1.balanceOf(actor), bal1Before + excess1, "skim: recipient token1");
        assertEq(pair.totalSupply(), supply, "skim: supply changed");
        donated0 = 0;
        donated1 = 0;
    }

    // ── LP token transfers between actors ───────────────────────────────────

    function transferShares(uint256 fromSeed, uint256 toSeed, uint256 amountSeed)
        external
        useActor(fromSeed)
        countCall("transferShares")
    {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 held = pair.balanceOf(from);
        uint256 supply = pair.totalSupply();

        // Failure paths: more than held, and the zero address.
        try pair.transfer(to, held + 1) {
            assertTrue(false, "transfer: over-balance accepted");
        } catch (bytes memory err) {
            assertEq(err, abi.encodeWithSelector(CPPair.InsufficientBalance.selector), "transfer: wrong error");
        }
        try pair.transfer(address(0), 0) {
            assertTrue(false, "transfer: zero address accepted");
        } catch (bytes memory err) {
            assertEq(err, abi.encodeWithSelector(CPPair.ZeroAddress.selector), "transfer: wrong error");
        }

        uint256 amount = _bound(amountSeed, 0, held);
        uint256 toBefore = pair.balanceOf(to);
        assertTrue(pair.transfer(to, amount), "transfer: returned false");
        if (from == to) {
            assertEq(pair.balanceOf(from), held, "self-transfer changed balance");
        } else {
            assertEq(pair.balanceOf(from), held - amount, "transfer: from balance");
            assertEq(pair.balanceOf(to), toBefore + amount, "transfer: to balance");
        }
        assertEq(pair.totalSupply(), supply, "transfer: supply changed");
    }

    // ── Revert probes ────────────────────────────────────────────────────────

    function _expectAddRevert(uint256 d0, uint256 d1, uint256 minShares, address to, bytes4 selector) internal {
        try pair.addLiquidity(d0, d1, minShares, to) {
            assertTrue(false, "addLiquidity: expected revert");
        } catch (bytes memory err) {
            assertEq(err, abi.encodeWithSelector(selector), "addLiquidity: wrong error");
        }
    }

    function _expectRemoveRevert(uint256 shares, uint256 min0, uint256 min1, address to, bytes4 selector) internal {
        try pair.removeLiquidity(shares, min0, min1, to) {
            assertTrue(false, "removeLiquidity: expected revert");
        } catch (bytes memory err) {
            assertEq(err, abi.encodeWithSelector(selector), "removeLiquidity: wrong error");
        }
    }

    function _expectSwapRevert(address tokenIn, uint256 amountIn, uint256 minOut, address to, bytes4 selector)
        internal
    {
        try pair.swapExactIn(tokenIn, amountIn, minOut, to) {
            assertTrue(false, "swapExactIn: expected revert");
        } catch (bytes memory err) {
            assertEq(err, abi.encodeWithSelector(selector), "swapExactIn: wrong error");
        }
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _kAndSupply() internal view returns (uint256 k, uint256 supply) {
        (uint112 r0, uint112 r1) = pair.getReserves();
        k = uint256(r0) * uint256(r1);
        supply = pair.totalSupply();
    }

    /// @dev Log-uniform draw in [1, 10^MAX_EXP].
    function _logBound(uint256 seed) internal pure returns (uint256) {
        uint256 exp = seed % (MAX_EXP + 1);
        return _bound(seed >> 16, 1, 10 ** exp);
    }

    function _amountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) internal pure returns (uint256) {
        if (amountIn == 0 || reserveIn == 0 || reserveOut == 0) return 0;
        uint256 withFee = amountIn * 997;
        return (withFee * reserveOut) / (reserveIn * 1000 + withFee);
    }

    function _sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }
}
