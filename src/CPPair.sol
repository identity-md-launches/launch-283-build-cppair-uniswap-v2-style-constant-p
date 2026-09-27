// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title CPPair
/// @notice A Uniswap-V2-style constant-product pair for two ERC-20 tokens that is
///         also its own ERC-20 liquidity-provider (LP) token ("CP LP" / "CPLP", 18 decimals).
/// @dev Design summary:
///      - Reserves are `uint112` each, stored, and only change inside `addLiquidity`,
///        `removeLiquidity`, `swapExactIn`, `sync` and `skim`. Raw token balances may
///        therefore exceed the reserves after direct transfers ("donations").
///      - The first deposit locks `MINIMUM_LIQUIDITY` (1000) shares at the burn address
///        `0x...dEaD` forever, so total supply never returns to zero.
///      - Swaps charge a 0.3% fee on the input amount.
///      - Every token pull is verified by balance difference; fee-on-transfer tokens revert.
///      - A reentrancy guard protects every state-changing function; storage effects
///        (reserves, supply, balances) are applied before any external token call.
///      - No owner, no protocol fee, no flash swaps, no price accumulator.
contract CPPair {
    // ─────────────────────────────────────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────────────────────────────────────

    error ZeroAddress();
    error IdenticalTokens();
    error Reentrancy();
    error InsufficientInitialLiquidity();
    error InsufficientSharesMinted();
    error InsufficientShares();
    error InsufficientOutput();
    error UnknownToken();
    error FeeOnTransfer();
    error TransferFailed();
    error ReserveOverflow();
    error InsufficientBalance();
    error InsufficientAllowance();

    // ─────────────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────────────

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    event Mint(address indexed sender, address indexed to, uint256 amount0, uint256 amount1, uint256 shares);
    event Burn(address indexed sender, address indexed to, uint256 amount0, uint256 amount1, uint256 shares);
    event Swap(
        address indexed sender, address indexed tokenIn, uint256 amountIn, uint256 amountOut, address indexed to
    );
    event Sync(uint112 reserve0, uint112 reserve1);

    // ─────────────────────────────────────────────────────────────────────────────
    // Constants and immutables
    // ─────────────────────────────────────────────────────────────────────────────

    string public constant name = "CP LP";
    string public constant symbol = "CPLP";
    uint8 public constant decimals = 18;

    /// @notice Shares permanently locked at `BURN_ADDRESS` by the first deposit.
    uint256 public constant MINIMUM_LIQUIDITY = 1000;
    /// @notice Recipient of the permanently locked minimum liquidity.
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    /// @notice Fee numerator: 997/1000 of the input amount is swapped, 0.3% stays in the pool.
    uint256 private constant FEE_NUMERATOR = 997;
    uint256 private constant FEE_DENOMINATOR = 1000;

    address public immutable token0;
    address public immutable token1;

    // ─────────────────────────────────────────────────────────────────────────────
    // Storage
    // ─────────────────────────────────────────────────────────────────────────────

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    uint112 private _reserve0;
    uint112 private _reserve1;

    uint256 private constant UNLOCKED = 1;
    uint256 private constant LOCKED = 2;
    uint256 private _lock = UNLOCKED;

    // ─────────────────────────────────────────────────────────────────────────────
    // Modifiers
    // ─────────────────────────────────────────────────────────────────────────────

    modifier nonReentrant() {
        if (_lock == LOCKED) revert Reentrancy();
        _lock = LOCKED;
        _;
        _lock = UNLOCKED;
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────────────────────────

    /// @param token0_ First pool token. Must be non-zero.
    /// @param token1_ Second pool token. Must be non-zero and different from `token0_`.
    constructor(address token0_, address token1_) {
        if (token0_ == address(0) || token1_ == address(0)) revert ZeroAddress();
        if (token0_ == token1_) revert IdenticalTokens();
        token0 = token0_;
        token1 = token1_;
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Views
    // ─────────────────────────────────────────────────────────────────────────────

    /// @notice Current stored reserves.
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1) {
        return (_reserve0, _reserve1);
    }

    /// @notice Output of `swapExactIn(tokenIn, amountIn, ...)` at the current reserves.
    /// @dev Reverts on an unknown token. Returns 0 when the pool is empty or the input is too small.
    function quote(uint256 amountIn, address tokenIn) external view returns (uint256 amountOut) {
        (uint256 reserveIn, uint256 reserveOut) = _orderedReserves(tokenIn);
        return _getAmountOut(amountIn, reserveIn, reserveOut);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Liquidity
    // ─────────────────────────────────────────────────────────────────────────────

    /// @notice Adds liquidity and mints LP shares to `to`.
    /// @dev First deposit: takes both desired amounts in full, mints sqrt(a0*a1) - 1000 shares to `to`
    ///      and 1000 to `BURN_ADDRESS`. Reverts if sqrt(a0*a1) <= 1000.
    ///      Later deposits: pulls the largest reserve-ratio-matched pair within the desired amounts
    ///      and mints min(a0 * S / r0, a1 * S / r1), rounded down.
    ///      Reverts when the minted shares are zero or below `minShares`.
    /// @param amount0Desired Maximum amount of token0 the caller is willing to deposit.
    /// @param amount1Desired Maximum amount of token1 the caller is willing to deposit.
    /// @param minShares Minimum shares that must be minted to `to`.
    /// @param to Recipient of the LP shares.
    /// @return amount0 Amount of token0 actually pulled.
    /// @return amount1 Amount of token1 actually pulled.
    /// @return shares Shares minted to `to`.
    function addLiquidity(uint256 amount0Desired, uint256 amount1Desired, uint256 minShares, address to)
        external
        nonReentrant
        returns (uint256 amount0, uint256 amount1, uint256 shares)
    {
        uint256 reserve0 = _reserve0;
        uint256 reserve1 = _reserve1;
        uint256 supply = totalSupply;

        if (supply == 0) {
            amount0 = amount0Desired;
            amount1 = amount1Desired;
            uint256 root = _sqrt(amount0 * amount1);
            if (root <= MINIMUM_LIQUIDITY) revert InsufficientInitialLiquidity();
            shares = root - MINIMUM_LIQUIDITY;
            _mint(BURN_ADDRESS, MINIMUM_LIQUIDITY);
        } else {
            // Largest ratio-matched pair within the desired amounts.
            uint256 amount1Optimal = (amount0Desired * reserve1) / reserve0;
            if (amount1Optimal <= amount1Desired) {
                amount0 = amount0Desired;
                amount1 = amount1Optimal;
            } else {
                amount0 = (amount1Desired * reserve0) / reserve1;
                amount1 = amount1Desired;
            }
            // Spec formula: min(a0 * S / r0, a1 * S / r1), each rounded down.
            // forge-lint: disable-next-line(divide-before-multiply)
            uint256 shares0 = (amount0 * supply) / reserve0;
            // forge-lint: disable-next-line(divide-before-multiply)
            uint256 shares1 = (amount1 * supply) / reserve1;
            shares = shares0 < shares1 ? shares0 : shares1;
        }

        if (shares == 0 || shares < minShares) revert InsufficientSharesMinted();

        // Effects.
        _mint(to, shares);
        _update(reserve0 + amount0, reserve1 + amount1);
        emit Mint(msg.sender, to, amount0, amount1, shares);

        // Interactions (verified by balance difference).
        _pull(token0, amount0);
        _pull(token1, amount1);
    }

    /// @notice Burns `shares` from the caller and pays the pro-rata reserves to `to`.
    /// @dev Pays shares * reserve / totalSupply of each token, rounded down.
    ///      Reverts when either output is zero or below its minimum.
    /// @param shares LP shares to burn from `msg.sender`.
    /// @param min0 Minimum token0 output.
    /// @param min1 Minimum token1 output.
    /// @param to Recipient of the tokens.
    /// @return amount0 token0 paid out.
    /// @return amount1 token1 paid out.
    function removeLiquidity(uint256 shares, uint256 min0, uint256 min1, address to)
        external
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        if (shares == 0) revert InsufficientShares();
        uint256 reserve0 = _reserve0;
        uint256 reserve1 = _reserve1;
        uint256 supply = totalSupply;

        amount0 = (shares * reserve0) / supply;
        amount1 = (shares * reserve1) / supply;
        if (amount0 == 0 || amount1 == 0) revert InsufficientOutput();
        if (amount0 < min0 || amount1 < min1) revert InsufficientOutput();

        // Effects.
        _burn(msg.sender, shares);
        _update(reserve0 - amount0, reserve1 - amount1);
        emit Burn(msg.sender, to, amount0, amount1, shares);

        // Interactions.
        _push(token0, to, amount0);
        _push(token1, to, amount1);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Swaps
    // ─────────────────────────────────────────────────────────────────────────────

    /// @notice Swaps an exact amount of `tokenIn` for as much of the other token as the curve allows.
    /// @dev 0.3% fee on input: out = floor(amountIn * 997 * rOut / (rIn * 1000 + amountIn * 997)).
    ///      Reverts on an unknown token, zero output, or output below `minOut`.
    /// @param tokenIn Either `token0` or `token1`.
    /// @param amountIn Exact input amount pulled from `msg.sender`.
    /// @param minOut Minimum acceptable output.
    /// @param to Recipient of the output token.
    /// @return amountOut Output amount sent to `to`.
    function swapExactIn(address tokenIn, uint256 amountIn, uint256 minOut, address to)
        external
        nonReentrant
        returns (uint256 amountOut)
    {
        (uint256 reserveIn, uint256 reserveOut) = _orderedReserves(tokenIn);
        amountOut = _getAmountOut(amountIn, reserveIn, reserveOut);
        if (amountOut == 0 || amountOut < minOut) revert InsufficientOutput();

        address tokenOut;
        // Effects.
        if (tokenIn == token0) {
            tokenOut = token1;
            _update(reserveIn + amountIn, reserveOut - amountOut);
        } else {
            tokenOut = token0;
            _update(reserveOut - amountOut, reserveIn + amountIn);
        }
        emit Swap(msg.sender, tokenIn, amountIn, amountOut, to);

        // Interactions.
        _pull(tokenIn, amountIn);
        _push(tokenOut, to, amountOut);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Reserve maintenance (permissionless, as in Uniswap V2)
    // ─────────────────────────────────────────────────────────────────────────────

    /// @notice Sets the reserves to the current token balances of this contract.
    function sync() external nonReentrant {
        _update(_balance(token0), _balance(token1));
    }

    /// @notice Sends `balance - reserve` of each token to `to`.
    function skim(address to) external nonReentrant {
        uint256 excess0 = _balance(token0) - _reserve0;
        uint256 excess1 = _balance(token1) - _reserve1;
        if (excess0 > 0) _push(token0, to, excess0);
        if (excess1 > 0) _push(token1, to, excess1);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // ERC-20 (LP token)
    // ─────────────────────────────────────────────────────────────────────────────

    function approve(address spender, uint256 value) external returns (bool) {
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transfer(address to, uint256 value) external returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < value) revert InsufficientAllowance();
            unchecked {
                allowance[from][msg.sender] = allowed - value;
            }
        }
        _transfer(from, to, value);
        return true;
    }

    function _transfer(address from, address to, uint256 value) private {
        if (to == address(0)) revert ZeroAddress();
        uint256 fromBalance = balanceOf[from];
        if (fromBalance < value) revert InsufficientBalance();
        unchecked {
            balanceOf[from] = fromBalance - value;
        }
        balanceOf[to] += value;
        emit Transfer(from, to, value);
    }

    function _mint(address to, uint256 value) private {
        if (to == address(0)) revert ZeroAddress();
        totalSupply += value;
        balanceOf[to] += value;
        emit Transfer(address(0), to, value);
    }

    function _burn(address from, uint256 value) private {
        uint256 fromBalance = balanceOf[from];
        if (fromBalance < value) revert InsufficientBalance();
        unchecked {
            balanceOf[from] = fromBalance - value;
            totalSupply -= value;
        }
        emit Transfer(from, address(0), value);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Internals
    // ─────────────────────────────────────────────────────────────────────────────

    function _orderedReserves(address tokenIn) private view returns (uint256 reserveIn, uint256 reserveOut) {
        if (tokenIn == token0) return (_reserve0, _reserve1);
        if (tokenIn == token1) return (_reserve1, _reserve0);
        revert UnknownToken();
    }

    function _getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut)
        private
        pure
        returns (uint256 amountOut)
    {
        if (amountIn == 0 || reserveIn == 0 || reserveOut == 0) return 0;
        uint256 amountInWithFee = amountIn * FEE_NUMERATOR;
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = reserveIn * FEE_DENOMINATOR + amountInWithFee;
        amountOut = numerator / denominator;
    }

    function _update(uint256 balance0, uint256 balance1) private {
        if (balance0 > type(uint112).max || balance1 > type(uint112).max) revert ReserveOverflow();
        // Casts are safe: both values were bounds-checked against type(uint112).max above.
        // forge-lint: disable-start(unsafe-typecast)
        _reserve0 = uint112(balance0);
        _reserve1 = uint112(balance1);
        emit Sync(_reserve0, _reserve1);
        // forge-lint: disable-end(unsafe-typecast)
    }

    /// @dev Babylonian square root, rounded down.
    function _sqrt(uint256 y) private pure returns (uint256 z) {
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

    function _balance(address token) private view returns (uint256) {
        (bool ok, bytes memory data) = token.staticcall(abi.encodeWithSelector(0x70a08231, address(this)));
        if (!ok || data.length < 32) revert TransferFailed();
        return abi.decode(data, (uint256));
    }

    /// @dev Pulls `amount` of `token` from `msg.sender` and verifies receipt by balance difference.
    function _pull(address token, uint256 amount) private {
        if (amount == 0) return;
        uint256 before = _balance(token);
        _call(token, abi.encodeWithSelector(0x23b872dd, msg.sender, address(this), amount));
        uint256 received = _balance(token) - before;
        if (received != amount) revert FeeOnTransfer();
    }

    function _push(address token, address to, uint256 amount) private {
        _call(token, abi.encodeWithSelector(0xa9059cbb, to, amount));
    }

    /// @dev Tolerates tokens that return nothing (USDT-style) but rejects an explicit `false`.
    function _call(address token, bytes memory data) private {
        // Every caller holds the nonReentrant lock, which is set before this call.
        // forge-lint: disable-next-line(reentrancy-no-eth)
        (bool ok, bytes memory ret) = token.call(data);
        if (!ok || (ret.length != 0 && !abi.decode(ret, (bool)))) revert TransferFailed();
    }
}
