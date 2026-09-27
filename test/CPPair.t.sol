// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {CPPair} from "../src/CPPair.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {FeeOnTransferERC20} from "./mocks/FeeOnTransferERC20.sol";
import {ReentrantERC20} from "./mocks/ReentrantERC20.sol";

contract CPPairTest is Test {
    // Mirrors of the pair's events for vm.expectEmit.
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event Mint(address indexed sender, address indexed to, uint256 amount0, uint256 amount1, uint256 shares);
    event Burn(address indexed sender, address indexed to, uint256 amount0, uint256 amount1, uint256 shares);
    event Swap(
        address indexed sender, address indexed tokenIn, uint256 amountIn, uint256 amountOut, address indexed to
    );
    event Sync(uint112 reserve0, uint112 reserve1);

    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 internal constant MIN_LIQ = 1000;
    uint256 internal constant SUPPLY = 1_000_000e18;

    MockERC20 internal tokenA;
    MockERC20 internal tokenB;
    CPPair internal pair;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    function setUp() public {
        tokenA = new MockERC20("Token A", "TKA");
        tokenB = new MockERC20("Token B", "TKB");
        pair = new CPPair(address(tokenA), address(tokenB));

        _fund(alice);
        _fund(bob);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────────────────────

    function _fund(address who) internal {
        tokenA.mint(who, SUPPLY);
        tokenB.mint(who, SUPPLY);
        vm.startPrank(who);
        tokenA.approve(address(pair), type(uint256).max);
        tokenB.approve(address(pair), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev Alice seeds the pool with (a0, a1). Returns her shares.
    function _seed(uint256 a0, uint256 a1) internal returns (uint256 shares) {
        vm.prank(alice);
        (,, shares) = pair.addLiquidity(a0, a1, 0, alice);
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

    function _k() internal view returns (uint256) {
        (uint112 r0, uint112 r1) = pair.getReserves();
        return uint256(r0) * uint256(r1);
    }

    function _amountOut(uint256 amountIn, uint256 rIn, uint256 rOut) internal pure returns (uint256) {
        return (amountIn * 997 * rOut) / (rIn * 1000 + amountIn * 997);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Constructor and metadata
    // ─────────────────────────────────────────────────────────────────────────

    function test_Constructor_Metadata() public view {
        assertEq(pair.name(), "CP LP");
        assertEq(pair.symbol(), "CPLP");
        assertEq(pair.decimals(), 18);
        assertEq(pair.token0(), address(tokenA));
        assertEq(pair.token1(), address(tokenB));
        assertEq(pair.totalSupply(), 0);
        assertEq(pair.MINIMUM_LIQUIDITY(), MIN_LIQ);
        assertEq(pair.BURN_ADDRESS(), DEAD);
        (uint112 r0, uint112 r1) = pair.getReserves();
        assertEq(r0, 0);
        assertEq(r1, 0);
    }

    function test_Constructor_RevertZeroToken0() public {
        vm.expectRevert(CPPair.ZeroAddress.selector);
        new CPPair(address(0), address(tokenB));
    }

    function test_Constructor_RevertZeroToken1() public {
        vm.expectRevert(CPPair.ZeroAddress.selector);
        new CPPair(address(tokenA), address(0));
    }

    function test_Constructor_RevertIdenticalTokens() public {
        vm.expectRevert(CPPair.IdenticalTokens.selector);
        new CPPair(address(tokenA), address(tokenA));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // addLiquidity — first deposit
    // ─────────────────────────────────────────────────────────────────────────

    function test_AddLiquidity_FirstDeposit() public {
        uint256 a0 = 1000e18;
        uint256 a1 = 4000e18;
        uint256 expectedShares = 2000e18 - MIN_LIQ; // sqrt(1000e18 * 4000e18) = 2000e18

        vm.expectEmit(true, true, true, true, address(pair));
        emit Transfer(address(0), DEAD, MIN_LIQ);
        vm.expectEmit(true, true, true, true, address(pair));
        emit Transfer(address(0), alice, expectedShares);
        vm.expectEmit(true, true, true, true, address(pair));
        emit Sync(uint112(a0), uint112(a1));
        vm.expectEmit(true, true, true, true, address(pair));
        emit Mint(alice, alice, a0, a1, expectedShares);

        vm.prank(alice);
        (uint256 used0, uint256 used1, uint256 shares) = pair.addLiquidity(a0, a1, expectedShares, alice);

        assertEq(used0, a0);
        assertEq(used1, a1);
        assertEq(shares, expectedShares);
        assertEq(pair.balanceOf(alice), expectedShares);
        assertEq(pair.balanceOf(DEAD), MIN_LIQ);
        assertEq(pair.totalSupply(), expectedShares + MIN_LIQ);

        (uint112 r0, uint112 r1) = pair.getReserves();
        assertEq(r0, a0);
        assertEq(r1, a1);
        assertEq(tokenA.balanceOf(address(pair)), a0);
        assertEq(tokenB.balanceOf(address(pair)), a1);
        assertEq(tokenA.balanceOf(alice), SUPPLY - a0);
        assertEq(tokenB.balanceOf(alice), SUPPLY - a1);
    }

    function test_AddLiquidity_FirstDeposit_MintsToRecipient() public {
        vm.prank(alice);
        (,, uint256 shares) = pair.addLiquidity(10e18, 10e18, 0, carol);
        assertEq(pair.balanceOf(carol), shares);
        assertEq(pair.balanceOf(alice), 0);
        assertEq(tokenA.balanceOf(alice), SUPPLY - 10e18);
    }

    function test_AddLiquidity_FirstDeposit_TakesFullAmountsEvenWhenUnbalanced() public {
        // No ratio exists yet, so both desired amounts are taken as given.
        vm.prank(alice);
        (uint256 used0, uint256 used1, uint256 shares) = pair.addLiquidity(1e18, 1e21, 0, alice);
        assertEq(used0, 1e18);
        assertEq(used1, 1e21);
        assertEq(shares, _sqrt(1e18 * 1e21) - MIN_LIQ);
    }

    function test_AddLiquidity_FirstDeposit_BoundaryJustAboveMinimum() public {
        // sqrt(1001 * 1001) = 1001 > 1000 -> exactly 1 share to the depositor.
        vm.prank(alice);
        (,, uint256 shares) = pair.addLiquidity(1001, 1001, 0, alice);
        assertEq(shares, 1);
        assertEq(pair.balanceOf(DEAD), MIN_LIQ);
        assertEq(pair.totalSupply(), 1001);
    }

    function test_AddLiquidity_RevertFirstDeposit_SqrtEqualToMinimum() public {
        // sqrt(1000 * 1000) = 1000 <= 1000 -> revert.
        vm.prank(alice);
        vm.expectRevert(CPPair.InsufficientInitialLiquidity.selector);
        pair.addLiquidity(1000, 1000, 0, alice);
    }

    function test_AddLiquidity_RevertFirstDeposit_SqrtRoundsDownToMinimum() public {
        // sqrt(1001 * 1000) = floor(1000.49) = 1000 <= 1000 -> revert.
        vm.prank(alice);
        vm.expectRevert(CPPair.InsufficientInitialLiquidity.selector);
        pair.addLiquidity(1001, 1000, 0, alice);
    }

    function test_AddLiquidity_RevertFirstDeposit_ZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(CPPair.InsufficientInitialLiquidity.selector);
        pair.addLiquidity(0, 1e24, 0, alice);
    }

    function test_AddLiquidity_RevertFirstDeposit_BelowMinShares() public {
        vm.prank(alice);
        vm.expectRevert(CPPair.InsufficientSharesMinted.selector);
        pair.addLiquidity(1000e18, 4000e18, 2000e18, alice); // actual = 2000e18 - 1000
    }

    function test_AddLiquidity_RevertZeroRecipient() public {
        vm.prank(alice);
        vm.expectRevert(CPPair.ZeroAddress.selector);
        pair.addLiquidity(1e18, 1e18, 0, address(0));
    }

    function test_AddLiquidity_RevertWithoutAllowance() public {
        vm.startPrank(carol);
        tokenA.mint(carol, 1e18);
        tokenB.mint(carol, 1e18);
        vm.expectRevert(CPPair.TransferFailed.selector);
        pair.addLiquidity(1e18, 1e18, 0, carol);
        vm.stopPrank();
    }

    function test_AddLiquidity_RevertReserveOverflow() public {
        uint256 huge = uint256(type(uint112).max) + 1;
        tokenA.mint(carol, huge);
        tokenB.mint(carol, huge);
        vm.startPrank(carol);
        tokenA.approve(address(pair), huge);
        tokenB.approve(address(pair), huge);
        vm.expectRevert(CPPair.ReserveOverflow.selector);
        pair.addLiquidity(huge, huge, 0, carol);
        vm.stopPrank();
    }

    function test_AddLiquidity_RevertFeeOnTransfer() public {
        FeeOnTransferERC20 fee = new FeeOnTransferERC20();
        CPPair feePair = new CPPair(address(fee), address(tokenB));
        fee.mint(alice, 100e18);
        vm.startPrank(alice);
        fee.approve(address(feePair), type(uint256).max);
        tokenB.approve(address(feePair), type(uint256).max);
        vm.expectRevert(CPPair.FeeOnTransfer.selector);
        feePair.addLiquidity(10e18, 10e18, 0, alice);
        vm.stopPrank();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // addLiquidity — subsequent deposits
    // ─────────────────────────────────────────────────────────────────────────

    function test_AddLiquidity_Subsequent_Token0IsBinding() public {
        _seed(1000e18, 4000e18);
        uint256 supply = pair.totalSupply();

        // amount1Optimal = 100 * 4000 / 1000 = 400 <= 1000 -> (100, 400).
        vm.expectEmit(true, true, true, true, address(pair));
        emit Mint(bob, bob, 100e18, 400e18, supply / 10);
        vm.prank(bob);
        (uint256 used0, uint256 used1, uint256 shares) = pair.addLiquidity(100e18, 1000e18, 0, bob);

        assertEq(used0, 100e18);
        assertEq(used1, 400e18);
        assertEq(shares, supply / 10);
        assertEq(pair.balanceOf(bob), shares);
        assertEq(pair.totalSupply(), supply + shares);
        assertEq(tokenA.balanceOf(bob), SUPPLY - 100e18);
        assertEq(tokenB.balanceOf(bob), SUPPLY - 400e18);
        (uint112 r0, uint112 r1) = pair.getReserves();
        assertEq(r0, 1100e18);
        assertEq(r1, 4400e18);
    }

    function test_AddLiquidity_Subsequent_Token1IsBinding() public {
        _seed(1000e18, 4000e18);
        uint256 supply = pair.totalSupply();

        // amount1Optimal = 1000 * 4 = 4000 > 400 -> amount0 = 400 * 1000 / 4000 = 100 -> (100, 400).
        vm.prank(bob);
        (uint256 used0, uint256 used1, uint256 shares) = pair.addLiquidity(1000e18, 400e18, 0, bob);

        assertEq(used0, 100e18);
        assertEq(used1, 400e18);
        assertEq(shares, supply / 10);
        assertEq(tokenA.balanceOf(bob), SUPPLY - 100e18);
        assertEq(tokenB.balanceOf(bob), SUPPLY - 400e18);
    }

    function test_AddLiquidity_Subsequent_RoundsDown() public {
        _seed(2000, 3000); // sqrt(6e6) = 2449 -> supply 2449
        uint256 supply = pair.totalSupply();
        assertEq(supply, 2449);

        // amount1Optimal = 7 * 3000 / 2000 = 10; shares0 = 7*2449/2000 = 8, shares1 = 10*2449/3000 = 8.
        vm.prank(bob);
        (uint256 used0, uint256 used1, uint256 shares) = pair.addLiquidity(7, 100, 0, bob);
        assertEq(used0, 7);
        assertEq(used1, 10);
        assertEq(shares, 8);
    }

    function test_AddLiquidity_Subsequent_MintsMinOfBothRatios() public {
        _seed(1000e18, 1000e18);
        uint256 supply = pair.totalSupply();
        // amount1Optimal = 13 * 1000/1000 = 13 <= 100 -> (13e18, 13e18); both ratios give the same shares.
        vm.prank(bob);
        (,, uint256 shares) = pair.addLiquidity(13e18, 100e18, 0, bob);
        assertEq(shares, (13e18 * supply) / 1000e18);
    }

    function test_AddLiquidity_Subsequent_RevertZeroShares() public {
        _seed(1e24, 1e12); // supply = 1e18
        // amount1Optimal = 1 * 1e12 / 1e24 = 0 -> shares1 = 0 -> zero shares.
        vm.prank(bob);
        vm.expectRevert(CPPair.InsufficientSharesMinted.selector);
        pair.addLiquidity(1, 1, 0, bob);
    }

    function test_AddLiquidity_Subsequent_RevertBelowMinShares() public {
        _seed(1000e18, 4000e18);
        uint256 supply = pair.totalSupply();
        vm.prank(bob);
        vm.expectRevert(CPPair.InsufficientSharesMinted.selector);
        pair.addLiquidity(100e18, 400e18, supply / 10 + 1, bob);
    }

    function test_AddLiquidity_Subsequent_ExactMinSharesSucceeds() public {
        _seed(1000e18, 4000e18);
        uint256 supply = pair.totalSupply();
        vm.prank(bob);
        (,, uint256 shares) = pair.addLiquidity(100e18, 400e18, supply / 10, bob);
        assertEq(shares, supply / 10);
    }

    function test_AddLiquidity_Subsequent_UsesReservesNotBalances() public {
        _seed(1000e18, 4000e18);
        uint256 supply = pair.totalSupply();
        // Donate token0 directly: balance > reserve, but pricing still uses reserves.
        tokenA.mint(address(pair), 5000e18);

        vm.prank(bob);
        (uint256 used0, uint256 used1, uint256 shares) = pair.addLiquidity(100e18, 1000e18, 0, bob);
        assertEq(used0, 100e18);
        assertEq(used1, 400e18);
        assertEq(shares, supply / 10);
        (uint112 r0,) = pair.getReserves();
        assertEq(r0, 1100e18);
        assertEq(tokenA.balanceOf(address(pair)), 6100e18);
    }

    function testFuzz_AddLiquidity_SubsequentSharesFormula(uint256 d0, uint256 d1) public {
        _seed(1000e18, 4000e18);
        d0 = bound(d0, 1, 100_000e18);
        d1 = bound(d1, 1, 100_000e18);
        (uint112 r0, uint112 r1) = pair.getReserves();
        uint256 supply = pair.totalSupply();

        uint256 e0;
        uint256 e1;
        uint256 opt1 = (d0 * uint256(r1)) / uint256(r0);
        if (opt1 <= d1) {
            (e0, e1) = (d0, opt1);
        } else {
            (e0, e1) = ((d1 * uint256(r0)) / uint256(r1), d1);
        }
        uint256 s0 = (e0 * supply) / uint256(r0);
        uint256 s1 = (e1 * supply) / uint256(r1);
        uint256 expected = s0 < s1 ? s0 : s1;

        vm.prank(bob);
        if (expected == 0) {
            vm.expectRevert(CPPair.InsufficientSharesMinted.selector);
            pair.addLiquidity(d0, d1, 0, bob);
            return;
        }
        (uint256 used0, uint256 used1, uint256 shares) = pair.addLiquidity(d0, d1, 0, bob);
        assertEq(used0, e0);
        assertEq(used1, e1);
        assertEq(shares, expected);
        assertLe(used0, d0);
        assertLe(used1, d1);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // removeLiquidity
    // ─────────────────────────────────────────────────────────────────────────

    function test_RemoveLiquidity_AllOwnShares() public {
        uint256 shares = _seed(1000e18, 4000e18);
        uint256 supply = pair.totalSupply();
        uint256 expect0 = (shares * 1000e18) / supply;
        uint256 expect1 = (shares * 4000e18) / supply;

        vm.expectEmit(true, true, true, true, address(pair));
        emit Transfer(alice, address(0), shares);
        vm.expectEmit(true, true, true, true, address(pair));
        emit Sync(uint112(1000e18 - expect0), uint112(4000e18 - expect1));
        vm.expectEmit(true, true, true, true, address(pair));
        emit Burn(alice, alice, expect0, expect1, shares);

        vm.prank(alice);
        (uint256 out0, uint256 out1) = pair.removeLiquidity(shares, expect0, expect1, alice);

        assertEq(out0, expect0);
        assertEq(out1, expect1);
        assertEq(pair.balanceOf(alice), 0);
        assertEq(pair.totalSupply(), MIN_LIQ);
        assertEq(tokenA.balanceOf(alice), SUPPLY - 1000e18 + expect0);
        assertEq(tokenB.balanceOf(alice), SUPPLY - 4000e18 + expect1);

        // The locked minimum liquidity keeps a residual reserve in the pool.
        (uint112 r0, uint112 r1) = pair.getReserves();
        assertEq(r0, 1000e18 - expect0);
        assertEq(r1, 4000e18 - expect1);
        assertGt(r0, 0);
        assertGt(r1, 0);
        assertEq(tokenA.balanceOf(address(pair)), r0);
        assertEq(tokenB.balanceOf(address(pair)), r1);
    }

    function test_RemoveLiquidity_Partial_ToRecipient() public {
        uint256 shares = _seed(1000e18, 4000e18);
        uint256 supply = pair.totalSupply();
        uint256 burn = shares / 3;
        uint256 expect0 = (burn * 1000e18) / supply;
        uint256 expect1 = (burn * 4000e18) / supply;

        vm.prank(alice);
        (uint256 out0, uint256 out1) = pair.removeLiquidity(burn, 0, 0, carol);

        assertEq(out0, expect0);
        assertEq(out1, expect1);
        assertEq(tokenA.balanceOf(carol), expect0);
        assertEq(tokenB.balanceOf(carol), expect1);
        assertEq(pair.balanceOf(alice), shares - burn);
        assertEq(pair.totalSupply(), supply - burn);
    }

    function test_RemoveLiquidity_RoundsDown() public {
        _seed(2000, 3000); // supply 2449, alice holds 1449
        // 7 shares: 7*2000/2449 = 5.71 -> 5 ; 7*3000/2449 = 8.57 -> 8
        vm.prank(alice);
        (uint256 out0, uint256 out1) = pair.removeLiquidity(7, 0, 0, alice);
        assertEq(out0, 5);
        assertEq(out1, 8);
    }

    function test_RemoveLiquidity_IgnoresDonatedBalance() public {
        uint256 shares = _seed(1000e18, 4000e18);
        uint256 supply = pair.totalSupply();
        tokenA.mint(address(pair), 777e18); // donation not in reserves

        vm.prank(alice);
        (uint256 out0,) = pair.removeLiquidity(shares, 0, 0, alice);
        assertEq(out0, (shares * 1000e18) / supply);
        // Donation is still sitting in the pair, above the reserve.
        (uint112 r0,) = pair.getReserves();
        assertEq(tokenA.balanceOf(address(pair)), uint256(r0) + 777e18);
    }

    function test_RemoveLiquidity_RevertZeroShares() public {
        _seed(1000e18, 4000e18);
        vm.prank(alice);
        vm.expectRevert(CPPair.InsufficientShares.selector);
        pair.removeLiquidity(0, 0, 0, alice);
    }

    function test_RemoveLiquidity_RevertInsufficientBalance() public {
        _seed(1000e18, 4000e18);
        vm.prank(bob);
        vm.expectRevert(CPPair.InsufficientBalance.selector);
        pair.removeLiquidity(1e18, 0, 0, bob);
    }

    function test_RemoveLiquidity_RevertBelowMin0() public {
        uint256 shares = _seed(1000e18, 4000e18);
        uint256 supply = pair.totalSupply();
        uint256 expect0 = (shares * 1000e18) / supply;
        vm.prank(alice);
        vm.expectRevert(CPPair.InsufficientOutput.selector);
        pair.removeLiquidity(shares, expect0 + 1, 0, alice);
    }

    function test_RemoveLiquidity_RevertBelowMin1() public {
        uint256 shares = _seed(1000e18, 4000e18);
        uint256 supply = pair.totalSupply();
        uint256 expect1 = (shares * 4000e18) / supply;
        vm.prank(alice);
        vm.expectRevert(CPPair.InsufficientOutput.selector);
        pair.removeLiquidity(shares, 0, expect1 + 1, alice);
    }

    function test_RemoveLiquidity_RevertZeroOutput() public {
        // 1 wei of token0 against 1e12 token1: sqrt = 1e6 shares. One share pays 0 token0.
        _seed(1, 1e12);
        vm.prank(alice);
        vm.expectRevert(CPPair.InsufficientOutput.selector);
        pair.removeLiquidity(1, 0, 0, alice);
    }

    function test_RemoveLiquidity_StateUnchangedAfterRevert() public {
        uint256 shares = _seed(1000e18, 4000e18);
        vm.prank(alice);
        vm.expectRevert(CPPair.InsufficientOutput.selector);
        pair.removeLiquidity(shares, type(uint256).max, 0, alice);
        assertEq(pair.balanceOf(alice), shares);
        (uint112 r0, uint112 r1) = pair.getReserves();
        assertEq(r0, 1000e18);
        assertEq(r1, 4000e18);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // swapExactIn and quote
    // ─────────────────────────────────────────────────────────────────────────

    function test_Swap_Token0In() public {
        _seed(1000e18, 4000e18);
        uint256 amountIn = 10e18;
        uint256 expectedOut = _amountOut(amountIn, 1000e18, 4000e18);
        assertGt(expectedOut, 0);
        assertEq(pair.quote(amountIn, address(tokenA)), expectedOut);
        uint256 kBefore = _k();

        vm.expectEmit(true, true, true, true, address(pair));
        emit Sync(uint112(1000e18 + amountIn), uint112(4000e18 - expectedOut));
        vm.expectEmit(true, true, true, true, address(pair));
        emit Swap(bob, address(tokenA), amountIn, expectedOut, bob);

        vm.prank(bob);
        uint256 out = pair.swapExactIn(address(tokenA), amountIn, expectedOut, bob);

        assertEq(out, expectedOut);
        assertEq(tokenA.balanceOf(bob), SUPPLY - amountIn);
        assertEq(tokenB.balanceOf(bob), SUPPLY + expectedOut);
        (uint112 r0, uint112 r1) = pair.getReserves();
        assertEq(r0, 1000e18 + amountIn);
        assertEq(r1, 4000e18 - expectedOut);
        assertEq(tokenA.balanceOf(address(pair)), r0);
        assertEq(tokenB.balanceOf(address(pair)), r1);
        assertGe(_k(), kBefore);
        // The 0.3% fee means strictly less than the no-fee output.
        assertLt(expectedOut, (amountIn * 4000e18) / (1000e18 + amountIn));
    }

    function test_Swap_Token1In_ToRecipient() public {
        _seed(1000e18, 4000e18);
        uint256 amountIn = 40e18;
        uint256 expectedOut = _amountOut(amountIn, 4000e18, 1000e18);
        assertEq(pair.quote(amountIn, address(tokenB)), expectedOut);
        uint256 kBefore = _k();

        vm.prank(bob);
        uint256 out = pair.swapExactIn(address(tokenB), amountIn, 0, carol);

        assertEq(out, expectedOut);
        assertEq(tokenA.balanceOf(carol), expectedOut);
        assertEq(tokenB.balanceOf(bob), SUPPLY - amountIn);
        (uint112 r0, uint112 r1) = pair.getReserves();
        assertEq(r0, 1000e18 - expectedOut);
        assertEq(r1, 4000e18 + amountIn);
        assertGe(_k(), kBefore);
    }

    function test_Swap_ExactFormulaSmallNumbers() public {
        _seed(2000, 3000);
        // out = floor(100 * 997 * 3000 / (2000 * 1000 + 100 * 997)) = floor(299100000 / 2099700) = 142
        assertEq(pair.quote(100, address(tokenA)), 142);
        vm.prank(bob);
        uint256 out = pair.swapExactIn(address(tokenA), 100, 0, bob);
        assertEq(out, 142);
    }

    function test_Swap_RevertUnknownToken() public {
        _seed(1000e18, 4000e18);
        MockERC20 other = new MockERC20("Other", "OTH");
        vm.prank(bob);
        vm.expectRevert(CPPair.UnknownToken.selector);
        pair.swapExactIn(address(other), 1e18, 0, bob);
    }

    function test_Swap_RevertBelowMinOut() public {
        _seed(1000e18, 4000e18);
        uint256 expectedOut = _amountOut(10e18, 1000e18, 4000e18);
        vm.prank(bob);
        vm.expectRevert(CPPair.InsufficientOutput.selector);
        pair.swapExactIn(address(tokenA), 10e18, expectedOut + 1, bob);
    }

    function test_Swap_RevertZeroAmountIn() public {
        _seed(1000e18, 4000e18);
        vm.prank(bob);
        vm.expectRevert(CPPair.InsufficientOutput.selector);
        pair.swapExactIn(address(tokenA), 0, 0, bob);
    }

    function test_Swap_RevertZeroOutputFromRounding() public {
        // 1 wei in against a deep reserve rounds the output down to zero.
        _seed(1e24, 1e6);
        assertEq(pair.quote(1, address(tokenA)), 0);
        vm.prank(bob);
        vm.expectRevert(CPPair.InsufficientOutput.selector);
        pair.swapExactIn(address(tokenA), 1, 0, bob);
    }

    function test_Swap_RevertEmptyPool() public {
        vm.prank(bob);
        vm.expectRevert(CPPair.InsufficientOutput.selector);
        pair.swapExactIn(address(tokenA), 1e18, 0, bob);
    }

    function test_Swap_RevertFeeOnTransfer() public {
        FeeOnTransferERC20 fee = new FeeOnTransferERC20();
        CPPair feePair = new CPPair(address(tokenA), address(fee));
        fee.mint(alice, 1000e18);
        fee.mint(bob, 1000e18);
        vm.startPrank(alice);
        tokenA.approve(address(feePair), type(uint256).max);
        fee.approve(address(feePair), type(uint256).max);
        // Seed by minting directly then sync, since a pull of the fee token would revert.
        tokenA.transfer(address(feePair), 100e18);
        fee.transfer(address(feePair), 100e18);
        vm.stopPrank();
        feePair.sync();

        vm.startPrank(bob);
        fee.approve(address(feePair), type(uint256).max);
        vm.expectRevert(CPPair.FeeOnTransfer.selector);
        feePair.swapExactIn(address(fee), 10e18, 0, bob);
        vm.stopPrank();
    }

    function test_Swap_RevertWithoutAllowance() public {
        _seed(1000e18, 4000e18);
        tokenA.mint(carol, 1e18);
        vm.prank(carol);
        vm.expectRevert(CPPair.TransferFailed.selector);
        pair.swapExactIn(address(tokenA), 1e18, 0, carol);
    }

    function test_Swap_UsesReservesNotBalances() public {
        _seed(1000e18, 4000e18);
        tokenB.mint(address(pair), 4000e18); // donation doubles the balance but not the reserve
        uint256 expectedOut = _amountOut(10e18, 1000e18, 4000e18);
        vm.prank(bob);
        uint256 out = pair.swapExactIn(address(tokenA), 10e18, 0, bob);
        assertEq(out, expectedOut);
    }

    function test_Quote_RevertUnknownToken() public {
        vm.expectRevert(CPPair.UnknownToken.selector);
        pair.quote(1e18, address(0xBEEF));
    }

    function test_Quote_EmptyPoolReturnsZero() public view {
        assertEq(pair.quote(1e18, address(tokenA)), 0);
        assertEq(pair.quote(1e18, address(tokenB)), 0);
    }

    function testFuzz_Swap_MatchesFormulaAndPreservesK(uint256 amountIn, bool zeroForOne) public {
        _seed(1000e18, 4000e18);
        amountIn = bound(amountIn, 1, 100_000e18);
        address tokenIn = zeroForOne ? address(tokenA) : address(tokenB);
        (uint112 r0, uint112 r1) = pair.getReserves();
        (uint256 rIn, uint256 rOut) = zeroForOne ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        uint256 expected = _amountOut(amountIn, rIn, rOut);
        uint256 kBefore = _k();

        assertEq(pair.quote(amountIn, tokenIn), expected);
        vm.prank(bob);
        if (expected == 0) {
            vm.expectRevert(CPPair.InsufficientOutput.selector);
            pair.swapExactIn(tokenIn, amountIn, 0, bob);
            return;
        }
        uint256 out = pair.swapExactIn(tokenIn, amountIn, 0, bob);
        assertEq(out, expected);
        assertGe(_k(), kBefore);
        (uint112 n0, uint112 n1) = pair.getReserves();
        assertEq(tokenA.balanceOf(address(pair)), n0);
        assertEq(tokenB.balanceOf(address(pair)), n1);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // sync and skim
    // ─────────────────────────────────────────────────────────────────────────

    function test_Sync_SetsReservesToBalances() public {
        _seed(1000e18, 4000e18);
        tokenA.mint(address(pair), 5e18);
        tokenB.mint(address(pair), 7e18);
        (uint112 r0, uint112 r1) = pair.getReserves();
        assertEq(r0, 1000e18);
        assertEq(r1, 4000e18);

        vm.expectEmit(true, true, true, true, address(pair));
        emit Sync(uint112(1005e18), uint112(4007e18));
        vm.prank(carol); // permissionless
        pair.sync();

        (r0, r1) = pair.getReserves();
        assertEq(r0, 1005e18);
        assertEq(r1, 4007e18);
        assertEq(pair.totalSupply(), 2000e18); // supply untouched
    }

    function test_Sync_EmptyPoolIsNoop() public {
        pair.sync();
        (uint112 r0, uint112 r1) = pair.getReserves();
        assertEq(r0, 0);
        assertEq(r1, 0);
    }

    function test_Sync_RevertReserveOverflow() public {
        tokenA.mint(address(pair), uint256(type(uint112).max) + 1);
        vm.expectRevert(CPPair.ReserveOverflow.selector);
        pair.sync();
    }

    function test_Skim_SendsExcessToRecipient() public {
        _seed(1000e18, 4000e18);
        tokenA.mint(address(pair), 5e18);
        tokenB.mint(address(pair), 7e18);

        vm.prank(bob); // permissionless
        pair.skim(carol);

        assertEq(tokenA.balanceOf(carol), 5e18);
        assertEq(tokenB.balanceOf(carol), 7e18);
        (uint112 r0, uint112 r1) = pair.getReserves();
        assertEq(r0, 1000e18);
        assertEq(r1, 4000e18);
        assertEq(tokenA.balanceOf(address(pair)), 1000e18);
        assertEq(tokenB.balanceOf(address(pair)), 4000e18);
    }

    function test_Skim_OnlyOneTokenInExcess() public {
        _seed(1000e18, 4000e18);
        tokenB.mint(address(pair), 3e18);
        pair.skim(carol);
        assertEq(tokenA.balanceOf(carol), 0);
        assertEq(tokenB.balanceOf(carol), 3e18);
    }

    function test_Skim_NothingToSkimIsNoop() public {
        _seed(1000e18, 4000e18);
        pair.skim(carol);
        assertEq(tokenA.balanceOf(carol), 0);
        assertEq(tokenB.balanceOf(carol), 0);
        assertEq(tokenA.balanceOf(address(pair)), 1000e18);
        assertEq(tokenB.balanceOf(address(pair)), 4000e18);
    }

    function test_Skim_ThenSyncLeavesReservesUnchanged() public {
        _seed(1000e18, 4000e18);
        tokenA.mint(address(pair), 9e18);
        pair.skim(carol);
        pair.sync();
        (uint112 r0, uint112 r1) = pair.getReserves();
        assertEq(r0, 1000e18);
        assertEq(r1, 4000e18);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Reentrancy guard
    // ─────────────────────────────────────────────────────────────────────────

    function _reentrantPair() internal returns (ReentrantERC20 evil, CPPair p) {
        evil = new ReentrantERC20();
        p = new CPPair(address(evil), address(tokenB));
        evil.mint(alice, SUPPLY);
        evil.mint(bob, SUPPLY);
        vm.startPrank(alice);
        evil.approve(address(p), type(uint256).max);
        tokenB.approve(address(p), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(bob);
        evil.approve(address(p), type(uint256).max);
        tokenB.approve(address(p), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev Asserts the armed callback ran and was rejected by the guard.
    function _assertGuardFired(ReentrantERC20 evil) internal view {
        assertTrue(evil.callbackFired(), "callback did not fire");
        assertFalse(evil.callbackSucceeded(), "reentrant call succeeded");
        assertEq(evil.callbackRevertData(), abi.encodeWithSelector(CPPair.Reentrancy.selector));
    }

    function test_Reentrancy_AddLiquidityBlocked() public {
        (ReentrantERC20 evil, CPPair p) = _reentrantPair();
        evil.arm(address(p), abi.encodeCall(CPPair.sync, ()));
        vm.prank(alice);
        p.addLiquidity(100e18, 100e18, 0, alice);
        _assertGuardFired(evil);
        // Outer call completed normally with the reentrant sync rejected.
        (uint112 r0, uint112 r1) = p.getReserves();
        assertEq(r0, 100e18);
        assertEq(r1, 100e18);
    }

    function test_Reentrancy_SwapPullBlocked() public {
        (ReentrantERC20 evil, CPPair p) = _reentrantPair();
        vm.prank(alice);
        p.addLiquidity(100e18, 100e18, 0, alice);

        // Callback fires during the pull of tokenIn (the reentrant token).
        evil.arm(address(p), abi.encodeCall(CPPair.swapExactIn, (address(evil), 1e18, 0, bob)));
        uint256 quoted = p.quote(1e18, address(evil));
        vm.prank(bob);
        uint256 out = p.swapExactIn(address(evil), 1e18, 0, bob);
        _assertGuardFired(evil);
        assertEq(out, quoted);
        (uint112 r0,) = p.getReserves();
        assertEq(r0, 101e18); // exactly one swap was applied
    }

    function test_Reentrancy_SwapPushBlocked() public {
        (ReentrantERC20 evil, CPPair p) = _reentrantPair();
        vm.prank(alice);
        p.addLiquidity(100e18, 100e18, 0, alice);

        // Callback fires during the push of tokenOut (the reentrant token).
        evil.arm(address(p), abi.encodeCall(CPPair.skim, (bob)));
        vm.prank(bob);
        p.swapExactIn(address(tokenB), 1e18, 0, bob);
        _assertGuardFired(evil);
    }

    function test_Reentrancy_RemoveLiquidityBlocked() public {
        (ReentrantERC20 evil, CPPair p) = _reentrantPair();
        vm.prank(alice);
        (,, uint256 shares) = p.addLiquidity(100e18, 100e18, 0, alice);

        evil.arm(address(p), abi.encodeCall(CPPair.removeLiquidity, (1, 0, 0, alice)));
        vm.prank(alice);
        p.removeLiquidity(shares, 0, 0, alice);
        _assertGuardFired(evil);
        assertEq(p.totalSupply(), MIN_LIQ);
    }

    function test_Reentrancy_SkimBlocked() public {
        (ReentrantERC20 evil, CPPair p) = _reentrantPair();
        vm.prank(alice);
        p.addLiquidity(100e18, 100e18, 0, alice);
        evil.mint(address(p), 1e18); // excess to skim triggers a push

        evil.arm(address(p), abi.encodeCall(CPPair.sync, ()));
        p.skim(bob);
        _assertGuardFired(evil);
        (uint112 r0,) = p.getReserves();
        assertEq(r0, 100e18); // reentrant sync did not run
    }

    function test_Reentrancy_GuardResetsAfterCall() public {
        (ReentrantERC20 evil, CPPair p) = _reentrantPair();
        vm.prank(alice);
        p.addLiquidity(100e18, 100e18, 0, alice);
        // Disarmed token: sequential calls must work normally.
        vm.prank(bob);
        p.swapExactIn(address(evil), 1e18, 0, bob);
        vm.prank(bob);
        p.swapExactIn(address(tokenB), 1e18, 0, bob);
        p.sync();
        p.skim(bob);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // ERC-20 LP token
    // ─────────────────────────────────────────────────────────────────────────

    function test_ERC20_Transfer() public {
        uint256 shares = _seed(1000e18, 4000e18);
        vm.expectEmit(true, true, true, true, address(pair));
        emit Transfer(alice, bob, 5e18);
        vm.prank(alice);
        assertTrue(pair.transfer(bob, 5e18));
        assertEq(pair.balanceOf(alice), shares - 5e18);
        assertEq(pair.balanceOf(bob), 5e18);
        assertEq(pair.totalSupply(), shares + MIN_LIQ);
    }

    function test_ERC20_TransferRevertInsufficientBalance() public {
        uint256 shares = _seed(1000e18, 4000e18);
        vm.prank(alice);
        vm.expectRevert(CPPair.InsufficientBalance.selector);
        pair.transfer(bob, shares + 1);
    }

    function test_ERC20_TransferRevertZeroAddress() public {
        _seed(1000e18, 4000e18);
        vm.prank(alice);
        vm.expectRevert(CPPair.ZeroAddress.selector);
        pair.transfer(address(0), 1);
    }

    function test_ERC20_ApproveAndTransferFrom() public {
        uint256 shares = _seed(1000e18, 4000e18);
        vm.expectEmit(true, true, true, true, address(pair));
        emit Approval(alice, bob, 10e18);
        vm.prank(alice);
        assertTrue(pair.approve(bob, 10e18));
        assertEq(pair.allowance(alice, bob), 10e18);

        vm.prank(bob);
        assertTrue(pair.transferFrom(alice, carol, 4e18));
        assertEq(pair.allowance(alice, bob), 6e18);
        assertEq(pair.balanceOf(alice), shares - 4e18);
        assertEq(pair.balanceOf(carol), 4e18);
    }

    function test_ERC20_TransferFromInfiniteAllowanceNotDecremented() public {
        _seed(1000e18, 4000e18);
        vm.prank(alice);
        pair.approve(bob, type(uint256).max);
        vm.prank(bob);
        pair.transferFrom(alice, carol, 4e18);
        assertEq(pair.allowance(alice, bob), type(uint256).max);
    }

    function test_ERC20_TransferFromRevertInsufficientAllowance() public {
        _seed(1000e18, 4000e18);
        vm.prank(alice);
        pair.approve(bob, 1e18);
        vm.prank(bob);
        vm.expectRevert(CPPair.InsufficientAllowance.selector);
        pair.transferFrom(alice, carol, 1e18 + 1);
    }

    function test_ERC20_TransferredSharesAreRedeemable() public {
        uint256 shares = _seed(1000e18, 4000e18);
        uint256 supply = pair.totalSupply();
        vm.prank(alice);
        pair.transfer(bob, shares);

        vm.prank(bob);
        (uint256 out0, uint256 out1) = pair.removeLiquidity(shares, 0, 0, bob);
        assertEq(out0, (shares * 1000e18) / supply);
        assertEq(out1, (shares * 4000e18) / supply);
        assertEq(tokenA.balanceOf(bob), SUPPLY + out0);
        assertEq(tokenB.balanceOf(bob), SUPPLY + out1);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Scenario: full lifecycle keeps balances consistent with reserves
    // ─────────────────────────────────────────────────────────────────────────

    function test_Lifecycle_BalancesTrackReserves() public {
        uint256 aliceShares = _seed(1000e18, 4000e18);
        vm.prank(bob);
        (,, uint256 bobShares) = pair.addLiquidity(500e18, 5000e18, 0, bob);
        vm.prank(bob);
        pair.swapExactIn(address(tokenA), 50e18, 0, bob);
        vm.prank(alice);
        pair.swapExactIn(address(tokenB), 300e18, 0, alice);
        vm.prank(alice);
        pair.removeLiquidity(aliceShares, 0, 0, alice);
        vm.prank(bob);
        pair.removeLiquidity(bobShares, 0, 0, bob);

        (uint112 r0, uint112 r1) = pair.getReserves();
        assertEq(tokenA.balanceOf(address(pair)), r0);
        assertEq(tokenB.balanceOf(address(pair)), r1);
        assertEq(pair.totalSupply(), MIN_LIQ);
        assertEq(pair.balanceOf(DEAD), MIN_LIQ);
        assertGt(r0, 0);
        assertGt(r1, 0);
    }
}
