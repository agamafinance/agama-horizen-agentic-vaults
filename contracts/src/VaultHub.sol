// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

interface IVaultVerifier {
    function verify(bytes calldata proof, bytes32[] calldata publicInputs) external view returns (bool);
}

/// @title VaultHub
/// @notice Private strategy vaults with depositors. Each strategy keeps its book
/// off chain; the hub holds a commitment to it. Every epoch the strategy commits
/// its orders before the close, the oracle posts closing prices after it, and the
/// strategy settles with a proof (zk/vault_epoch) that moves its book, prices it,
/// and pays the epoch's redemptions in cash.
///
/// Depositors work in epochs, like an asynchronous vault: a deposit made during
/// epoch e is priced at e's proven NAV per share; a redemption requested during
/// e is priced at e+1's, so the strategy sees it before committing the orders
/// that raise the cash. Both are claimed once the epoch is settled.
///
/// A strategist registers with a bond in ZEN. The bond sets how much capital the
/// vault may take, and it is slashed if the strategy holds depositors' money and
/// stops proving. A strategy starts in a sandbox where only its strategist can
/// deposit, and opens to everyone after SANDBOX_EPOCHS proven epochs. A drawdown
/// beyond the one it declared freezes it: no new orders, no new deposits, and
/// depositors exit at the last proven NAV.
contract VaultHub {
    using SafeERC20 for IERC20;

    uint256 public constant ASSETS = 4; // 0 USDC, 1 ETH, 2 BTC, 3 ZEN
    uint64 public constant ONE = 1_000_000; // price of USDC, and of a share at launch
    uint64 public constant BPS = 10_000;
    uint64 public constant PERFORMANCE_FEE_BPS = 1_000; // 10% of gains above the high-water mark
    uint64 public constant SANDBOX_EPOCHS = 20; // proven epochs before outside deposits
    uint64 public constant MISSED_EPOCHS_LIMIT = 20; // a vault with depositors must prove within this window

    IVaultVerifier public immutable verifier;
    address public immutable oracle;
    uint64 public immutable genesisTime;
    uint64 public immutable epochLength;
    IERC20 public immutable usdc;
    IERC20 public immutable zen;
    address public immutable treasury;
    uint256 public immutable minBond; // in ZEN base units
    uint256 public immutable capacityPerZen; // USDC (1e-6) a vault may hold per whole ZEN of bond

    struct Strategy {
        address owner;
        uint8 allowedMask;
        uint64 maxWeightBps;
        uint64 maxDrawdownBps;
        bytes32 book;
        uint64 lastEpoch;
        bool started;
        bool frozen;
        uint64 nav; // after the last epoch's flows
        uint64 totalShares;
        uint64 sharePrice; // USDC per share, 1e6 = 1.00
        uint64 highWaterMark;
        uint64 peakSharePrice;
        uint64 drawdownBps; // maximum seen
        uint32 epochsSettled;
        uint256 bond;
        string name;
    }

    struct EpochResult {
        uint64 nav; // before flows: the price of a share this epoch is nav / sharesBefore
        uint64 sharesBefore;
        uint64 minted; // shares minted for the epoch's deposits
        uint64 outflow; // USDC paid for the epoch's redemptions
        bool settled;
    }

    Strategy[] internal strategies;
    mapping(uint256 => mapping(uint64 => bytes32)) public orderCommit;
    mapping(uint64 => uint64[ASSETS]) internal closePrices;
    mapping(uint64 => bool) public pricesPosted;
    uint64 public lastPriced;

    mapping(uint256 => mapping(address => uint64)) public sharesOf;
    mapping(uint256 => mapping(uint64 => uint64)) public depositsIn;
    mapping(uint256 => mapping(uint64 => uint64)) public redeemsIn;
    mapping(uint256 => mapping(uint64 => mapping(address => uint64))) public depositOf;
    mapping(uint256 => mapping(uint64 => mapping(address => uint64))) public redeemOf;
    mapping(uint256 => mapping(uint64 => EpochResult)) internal results;
    mapping(uint256 => uint64) public pendingDeposits; // deposited, not yet settled or reclaimed

    event Registered(uint256 indexed id, address indexed owner, string name, uint8 allowedMask, uint64 maxWeightBps, uint64 maxDrawdownBps, uint256 bond);
    event Deposited(uint256 indexed id, uint64 indexed epoch, address indexed user, uint64 amount);
    event RedeemRequested(uint256 indexed id, uint64 indexed epoch, address indexed user, uint64 shares);
    event Claimed(uint256 indexed id, uint64 indexed epoch, address indexed user, uint64 shares, uint64 paid);
    event Reclaimed(uint256 indexed id, uint64 indexed epoch, address indexed user, uint64 refunded, uint64 sharesBack);
    event OrdersCommitted(uint256 indexed id, uint64 indexed epoch, bytes32 commitment);
    event PricesPosted(uint64 indexed epoch, uint64[ASSETS] prices);
    event EpochSettled(uint256 indexed id, uint64 indexed epoch, bytes32 book, uint64 nav, uint64 sharePrice, uint64 totalShares, uint64 inflow, uint64 outflow, uint64 feeShares);
    event Frozen(uint256 indexed id, uint64 drawdownBps);
    event Slashed(uint256 indexed id, uint256 bond, address by);
    event Retired(uint256 indexed id, uint256 bondReturned);
    event Exited(uint256 indexed id, address indexed user, uint64 shares, uint64 paid);

    error NotOwner();
    error NotOracle();
    error BadMandate();
    error BondTooSmall();
    error UnknownStrategy();
    error StrategyFrozen();
    error NotFrozen();
    error SandboxOnly();
    error OverCapacity(uint64 capacity);
    error ZeroAmount();
    error NotEnoughShares();
    error EpochClosed(uint64 epoch, uint64 closesAt);
    error EpochStillOpen(uint64 epoch, uint64 closesAt);
    error AlreadyCommitted();
    error AlreadyPosted();
    error BadPrices();
    error NoOrders();
    error NoPrices();
    error EpochNotAfterLast(uint64 epoch, uint64 last);
    error EpochTooOld(uint64 epoch);
    error NotSettled();
    error AlreadySettled();
    error StillSettleable();
    error NotSlashable();
    error HasDepositors();
    error BadProof();

    constructor(
        address verifier_,
        address oracle_,
        uint64 genesisTime_,
        uint64 epochLength_,
        address usdc_,
        address zen_,
        address treasury_,
        uint256 minBond_,
        uint256 capacityPerZen_
    ) {
        verifier = IVaultVerifier(verifier_);
        oracle = oracle_;
        genesisTime = genesisTime_;
        epochLength = epochLength_;
        usdc = IERC20(usdc_);
        zen = IERC20(zen_);
        treasury = treasury_;
        minBond = minBond_;
        capacityPerZen = capacityPerZen_;
    }

    // ------------------------------------------------------------------ time

    function currentEpoch() public view returns (uint64) {
        return (uint64(block.timestamp) - genesisTime) / epochLength;
    }

    function closesAt(uint64 epoch) public view returns (uint64) {
        return genesisTime + (epoch + 1) * epochLength;
    }

    // ------------------------------------------------------------ strategists

    function register(string calldata name, uint8 allowedMask, uint64 maxWeightBps, uint64 maxDrawdownBps, uint256 bond)
        external
        returns (uint256 id)
    {
        if (allowedMask & 0x0E == 0 || allowedMask & 0xF1 != 0 || maxWeightBps == 0 || maxWeightBps > BPS) revert BadMandate();
        if (maxDrawdownBps == 0 || maxDrawdownBps > BPS) revert BadMandate();
        if (bond < minBond) revert BondTooSmall();
        zen.safeTransferFrom(msg.sender, address(this), bond);
        id = strategies.length;
        Strategy storage s = strategies.push();
        s.owner = msg.sender;
        s.allowedMask = allowedMask;
        s.maxWeightBps = maxWeightBps;
        s.maxDrawdownBps = maxDrawdownBps;
        s.sharePrice = ONE;
        s.highWaterMark = ONE;
        s.peakSharePrice = ONE;
        s.bond = bond;
        s.name = name;
        emit Registered(id, msg.sender, name, allowedMask, maxWeightBps, maxDrawdownBps, bond);
    }

    /// @notice How much capital the vault may hold: its ZEN bond times capacityPerZen.
    function capacity(uint256 id) public view returns (uint64) {
        uint256 c = _s(id).bond * capacityPerZen / 1e18;
        return c > type(uint64).max ? type(uint64).max : uint64(c);
    }

    function commitOrders(uint256 id, uint64 epoch, bytes32 commitment) external {
        Strategy storage s = _s(id);
        if (msg.sender != s.owner) revert NotOwner();
        if (s.frozen) revert StrategyFrozen();
        uint64 closes = closesAt(epoch);
        if (block.timestamp >= closes) revert EpochClosed(epoch, closes);
        if (orderCommit[id][epoch] != bytes32(0)) revert AlreadyCommitted();
        orderCommit[id][epoch] = commitment;
        emit OrdersCommitted(id, epoch, commitment);
    }

    function postPrices(uint64 epoch, uint64[ASSETS] calldata prices) external {
        if (msg.sender != oracle) revert NotOracle();
        uint64 closes = closesAt(epoch);
        if (block.timestamp < closes) revert EpochStillOpen(epoch, closes);
        if (pricesPosted[epoch]) revert AlreadyPosted();
        if (prices[0] != ONE) revert BadPrices();
        for (uint256 i = 1; i < ASSETS; i++) {
            if (prices[i] == 0) revert BadPrices();
        }
        closePrices[epoch] = prices;
        pricesPosted[epoch] = true;
        if (epoch > lastPriced) lastPriced = epoch;
        emit PricesPosted(epoch, prices);
    }

    struct Settlement {
        uint256 id;
        uint64 epoch;
        bytes32 orders;
        uint64 inflow;
        uint64 redeem;
        bytes32 newBook;
        uint64 nav;
        uint64 outflow;
    }

    /// @notice Settle an epoch with a vault_epoch proof. The contract rebuilds every
    /// public input itself: the book it holds, the orders committed before the
    /// close, the posted prices, the mandate, and the epoch's flows.
    function settle(uint256 id, uint64 epoch, bytes32 newBook, uint64 nav, uint64 outflow, bytes calldata proof) external {
        Strategy storage s = _s(id);
        if (msg.sender != s.owner) revert NotOwner();
        if (s.frozen) revert StrategyFrozen();
        if (s.started && epoch <= s.lastEpoch) revert EpochNotAfterLast(epoch, s.lastEpoch);
        if (currentEpoch() > epoch + MISSED_EPOCHS_LIMIT) revert EpochTooOld(epoch);
        bytes32 orders = orderCommit[id][epoch];
        if (orders == bytes32(0)) revert NoOrders();
        if (!pricesPosted[epoch]) revert NoPrices();

        Settlement memory t =
            Settlement(id, epoch, orders, depositsIn[id][epoch], redeemsIn[id][epoch], newBook, nav, outflow);
        if (!verifier.verify(proof, _inputs(s, t))) revert BadProof();
        _apply(s, t);
    }

    function _inputs(Strategy storage s, Settlement memory t) internal view returns (bytes32[] memory pi) {
        pi = new bytes32[](16); // 13 inputs, then the 3 outputs
        pi[0] = bytes32(t.id);
        pi[1] = bytes32(uint256(t.epoch));
        pi[2] = s.started ? s.book : bytes32(0);
        pi[3] = t.orders;
        uint64[ASSETS] storage p = closePrices[t.epoch];
        for (uint256 i = 0; i < ASSETS; i++) {
            pi[4 + i] = bytes32(uint256(p[i]));
        }
        pi[8] = bytes32(uint256(s.allowedMask));
        pi[9] = bytes32(uint256(s.maxWeightBps));
        pi[10] = bytes32(uint256(t.inflow));
        pi[11] = bytes32(uint256(t.redeem));
        pi[12] = bytes32(uint256(s.totalShares));
        pi[13] = t.newBook;
        pi[14] = bytes32(uint256(t.nav));
        pi[15] = bytes32(uint256(t.outflow));
    }

    function _apply(Strategy storage s, Settlement memory t) internal {
        uint64 before = s.totalShares;
        // performance fee on the gain above the high-water mark, in new shares,
        // before the flows so that this epoch's depositors do not pay for it
        uint64 feeShares = _performanceFee(s, t.id, t.nav, before);
        uint64 shares = before + feeShares;

        // deposits are priced at the proven NAV per share, after the fee
        uint64 minted;
        if (t.inflow > 0) {
            minted = (shares == 0 || t.nav == 0) ? t.inflow : uint64(uint256(t.inflow) * shares / t.nav);
        }
        pendingDeposits[t.id] -= t.inflow;
        results[t.id][t.epoch] = EpochResult(t.nav, shares, minted, t.outflow, true);

        s.totalShares = shares + minted - t.redeem;
        s.nav = t.nav + t.inflow - t.outflow;
        if (s.totalShares != 0) s.sharePrice = uint64(uint256(s.nav) * ONE / s.totalShares);
        if (s.sharePrice > s.highWaterMark) s.highWaterMark = s.sharePrice;
        if (s.sharePrice > s.peakSharePrice) s.peakSharePrice = s.sharePrice;
        uint64 dd = uint64(uint256(s.peakSharePrice - s.sharePrice) * BPS / s.peakSharePrice);
        if (dd > s.drawdownBps) s.drawdownBps = dd;
        s.book = t.newBook;
        s.lastEpoch = t.epoch;
        s.started = true;
        s.epochsSettled += 1;
        emit EpochSettled(t.id, t.epoch, t.newBook, t.nav, s.sharePrice, s.totalShares, t.inflow, t.outflow, feeShares);
        if (dd > s.maxDrawdownBps) {
            s.frozen = true;
            emit Frozen(t.id, dd);
        }
    }

    function _performanceFee(Strategy storage s, uint256 id, uint64 nav, uint64 shares) internal returns (uint64 feeShares) {
        if (shares == 0 || nav == 0) return 0;
        uint64 price = uint64(uint256(nav) * ONE / shares);
        if (price <= s.highWaterMark) return 0;
        uint256 fee = uint256(price - s.highWaterMark) * shares / ONE * PERFORMANCE_FEE_BPS / BPS;
        if (fee == 0 || fee >= nav) return 0;
        feeShares = uint64(fee * shares / (nav - fee));
        uint64 toTreasury = feeShares / 2;
        sharesOf[id][s.owner] += feeShares - toTreasury;
        sharesOf[id][treasury] += toTreasury;
    }

    // ------------------------------------------------------------- depositors

    function deposit(uint256 id, uint64 amount) external {
        Strategy storage s = _s(id);
        if (amount == 0) revert ZeroAmount();
        if (s.frozen) revert StrategyFrozen();
        if (s.epochsSettled < SANDBOX_EPOCHS && msg.sender != s.owner) revert SandboxOnly();
        uint64 cap = capacity(id);
        if (uint256(s.nav) + pendingDeposits[id] + amount > cap) revert OverCapacity(cap);
        uint64 e = currentEpoch();
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        depositsIn[id][e] += amount;
        depositOf[id][e][msg.sender] += amount;
        pendingDeposits[id] += amount;
        emit Deposited(id, e, msg.sender, amount);
    }

    /// @notice Redeem shares at the next epoch's proven NAV per share.
    function requestRedeem(uint256 id, uint64 shares) external {
        Strategy storage s = _s(id);
        if (shares == 0) revert ZeroAmount();
        if (s.frozen) revert StrategyFrozen();
        if (sharesOf[id][msg.sender] < shares) revert NotEnoughShares();
        sharesOf[id][msg.sender] -= shares;
        uint64 e = currentEpoch() + 1;
        redeemsIn[id][e] += shares;
        redeemOf[id][e][msg.sender] += shares;
        emit RedeemRequested(id, e, msg.sender, shares);
    }

    /// @notice Collect the shares of a settled deposit and the cash of a settled redemption.
    function claim(uint256 id, uint64 epoch) external {
        EpochResult storage r = results[id][epoch];
        if (!r.settled) revert NotSettled();
        uint64 d = depositOf[id][epoch][msg.sender];
        uint64 q = redeemOf[id][epoch][msg.sender];
        uint64 got;
        uint64 paid;
        if (d > 0) {
            got = uint64(uint256(d) * r.minted / depositsIn[id][epoch]);
            depositOf[id][epoch][msg.sender] = 0;
            sharesOf[id][msg.sender] += got;
        }
        if (q > 0) {
            paid = uint64(uint256(q) * r.outflow / redeemsIn[id][epoch]);
            redeemOf[id][epoch][msg.sender] = 0;
            usdc.safeTransfer(msg.sender, paid);
        }
        emit Claimed(id, epoch, msg.sender, got, paid);
    }

    /// @notice Take back a deposit or a redemption request of an epoch that can no
    /// longer be settled: a later epoch was settled, the window passed, or the
    /// strategy is frozen.
    function reclaim(uint256 id, uint64 epoch) external {
        Strategy storage s = _s(id);
        if (results[id][epoch].settled) revert AlreadySettled();
        bool dead = s.frozen || (s.started && epoch <= s.lastEpoch) || currentEpoch() > epoch + MISSED_EPOCHS_LIMIT;
        if (!dead) revert StillSettleable();
        uint64 d = depositOf[id][epoch][msg.sender];
        uint64 q = redeemOf[id][epoch][msg.sender];
        if (d > 0) {
            depositOf[id][epoch][msg.sender] = 0;
            depositsIn[id][epoch] -= d;
            pendingDeposits[id] -= d;
            usdc.safeTransfer(msg.sender, d);
        }
        if (q > 0) {
            redeemOf[id][epoch][msg.sender] = 0;
            redeemsIn[id][epoch] -= q;
            sharesOf[id][msg.sender] += q;
        }
        emit Reclaimed(id, epoch, msg.sender, d, q);
    }

    /// @notice Leave a frozen vault at its last proven NAV per share.
    function exitFrozen(uint256 id) external {
        Strategy storage s = _s(id);
        if (!s.frozen) revert NotFrozen();
        uint64 sh = sharesOf[id][msg.sender];
        if (sh == 0) revert ZeroAmount();
        uint64 paid = uint64(uint256(sh) * s.nav / s.totalShares);
        sharesOf[id][msg.sender] = 0;
        s.totalShares -= sh;
        s.nav -= paid;
        usdc.safeTransfer(msg.sender, paid);
        emit Exited(id, msg.sender, sh, paid);
    }

    // ------------------------------------------------------- bond and guards

    /// @notice Anyone may slash a vault that holds depositors' money and has not
    /// proven an epoch within MISSED_EPOCHS_LIMIT. The bond goes to the treasury,
    /// the vault freezes, and depositors exit at the last proven NAV.
    function slash(uint256 id) external {
        Strategy storage s = _s(id);
        if (s.frozen || !s.started || s.totalShares == 0 || currentEpoch() <= s.lastEpoch + MISSED_EPOCHS_LIMIT) {
            revert NotSlashable();
        }
        s.frozen = true;
        uint256 b = s.bond;
        s.bond = 0;
        zen.safeTransfer(treasury, b);
        emit Slashed(id, b, msg.sender);
    }

    /// @notice A strategist with no depositors left takes the bond back and closes the vault.
    function retire(uint256 id) external {
        Strategy storage s = _s(id);
        if (msg.sender != s.owner) revert NotOwner();
        if (s.totalShares != 0 || pendingDeposits[id] != 0) revert HasDepositors();
        s.frozen = true;
        uint256 b = s.bond;
        s.bond = 0;
        zen.safeTransfer(s.owner, b);
        emit Retired(id, b);
    }

    // ------------------------------------------------------------------ views

    function strategyCount() external view returns (uint256) {
        return strategies.length;
    }

    function strategy(uint256 id) external view returns (Strategy memory) {
        return _s(id);
    }

    function result(uint256 id, uint64 epoch) external view returns (EpochResult memory) {
        return results[id][epoch];
    }

    function prices(uint64 epoch) external view returns (uint64[ASSETS] memory) {
        return closePrices[epoch];
    }

    function _s(uint256 id) internal view returns (Strategy storage) {
        if (id >= strategies.length) revert UnknownStrategy();
        return strategies[id];
    }
}
