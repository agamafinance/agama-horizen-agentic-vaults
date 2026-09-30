// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IEpochVerifier {
    function verify(bytes calldata proof, bytes32[] calldata publicInputs) external view returns (bool);
}

/// @title AgentVaultHub
/// @notice Private books, public track records.
///
/// Each registered strategy keeps its book off chain. The hub holds only a
/// commitment to it. An epoch runs in three steps, in this order, enforced by
/// time:
///
///   1. before the epoch closes, the strategy posts a commitment to its orders
///   2. after it closes, the price oracle posts the closing prices
///   3. the strategy settles with a proof that the committed orders, filled at
///      those prices, move the committed book to a new one that respects its
///      mandate, and that the NAV it reports is the value of that book
///
/// Orders are fixed before prices exist, so a strategy cannot pick its trades
/// with hindsight. The NAV is an output of the proof, so it cannot be typed in.
/// What the chain records per epoch is a new commitment and a NAV; the balances,
/// the orders and the logic behind them never leave the strategy.
///
/// This version runs in sandbox: books start from a public amount of virtual
/// cash and fill at the oracle price. Netting across strategies, deposits and
/// the ZEN bond come next.
contract AgentVaultHub {
    uint256 public constant ASSETS = 4; // 0 USDC, 1 ETH, 2 BTC, 3 ZEN
    uint64 public constant PRICE_ONE = 1_000_000;
    uint64 public constant BPS = 10_000;

    struct Strategy {
        address owner;
        uint8 allowedMask; // bit i set means asset i may be held
        uint64 maxWeightBps; // cap on any single non-cash asset, share of NAV
        bytes32 book; // commitment to the private book, zero before genesis
        uint64 lastEpoch; // last settled epoch
        bool started;
        uint64 nav; // last proven NAV
        uint64 peakNav;
        uint64 maxDrawdownBps;
        uint32 epochsSettled;
        string name;
    }

    IEpochVerifier public immutable verifier;
    address public immutable oracle;
    uint64 public immutable genesisTime;
    uint64 public immutable epochLength;
    uint64 public immutable sandboxCapital;

    Strategy[] internal strategies;
    mapping(uint256 => mapping(uint64 => bytes32)) public orderCommit;
    mapping(uint64 => uint64[ASSETS]) internal closePrices;
    mapping(uint64 => bool) public pricesPosted;
    mapping(uint256 => mapping(uint64 => uint64)) public navAt;

    event StrategyRegistered(uint256 indexed id, address indexed owner, string name, uint8 allowedMask, uint64 maxWeightBps);
    event OrdersCommitted(uint256 indexed id, uint64 indexed epoch, bytes32 commitment);
    event PricesPosted(uint64 indexed epoch, uint64[ASSETS] prices);
    event EpochSettled(uint256 indexed id, uint64 indexed epoch, bytes32 book, uint64 nav, uint64 drawdownBps);

    error NotOwner();
    error NotOracle();
    error BadMandate();
    error EpochClosed(uint64 epoch, uint64 closesAt);
    error EpochStillOpen(uint64 epoch, uint64 closesAt);
    error AlreadyCommitted();
    error AlreadyPosted();
    error BadPrices();
    error NoOrders();
    error NoPrices();
    error EpochNotAfterLast(uint64 epoch, uint64 lastEpoch);
    error BadProof();

    constructor(address verifier_, address oracle_, uint64 genesisTime_, uint64 epochLength_, uint64 sandboxCapital_) {
        verifier = IEpochVerifier(verifier_);
        oracle = oracle_;
        genesisTime = genesisTime_;
        epochLength = epochLength_;
        sandboxCapital = sandboxCapital_;
    }

    // ---------------------------------------------------------------- time

    function epochAt(uint256 ts) public view returns (uint64) {
        return ts < genesisTime ? 0 : uint64((ts - genesisTime) / epochLength);
    }

    function closesAt(uint64 epoch) public view returns (uint64) {
        return genesisTime + (epoch + 1) * epochLength;
    }

    function currentEpoch() external view returns (uint64) {
        return epochAt(block.timestamp);
    }

    // ---------------------------------------------------------- strategies

    function register(string calldata name, uint8 allowedMask, uint64 maxWeightBps) external returns (uint256 id) {
        // cash is always allowed, only assets 1..3 are meaningful in the mask
        if (allowedMask & 0x0E == 0 || allowedMask & 0xF0 != 0 || maxWeightBps == 0 || maxWeightBps > BPS) {
            revert BadMandate();
        }
        id = strategies.length;
        Strategy storage s = strategies.push();
        s.owner = msg.sender;
        s.allowedMask = allowedMask;
        s.maxWeightBps = maxWeightBps;
        s.name = name;
        emit StrategyRegistered(id, msg.sender, name, allowedMask, maxWeightBps);
    }

    /// Commit to this epoch's orders. Must land before the epoch closes, and
    /// only once, so the set of orders is fixed before any closing price exists.
    function commitOrders(uint256 id, uint64 epoch, bytes32 commitment) external {
        Strategy storage s = strategies[id];
        if (msg.sender != s.owner) revert NotOwner();
        uint64 closes = closesAt(epoch);
        if (block.timestamp >= closes) revert EpochClosed(epoch, closes);
        if (orderCommit[id][epoch] != bytes32(0)) revert AlreadyCommitted();
        orderCommit[id][epoch] = commitment;
        emit OrdersCommitted(id, epoch, commitment);
    }

    // -------------------------------------------------------------- prices

    /// Closing prices, posted once the epoch is over. USDC is pinned at one.
    function postPrices(uint64 epoch, uint64[ASSETS] calldata prices) external {
        if (msg.sender != oracle) revert NotOracle();
        uint64 closes = closesAt(epoch);
        if (block.timestamp < closes) revert EpochStillOpen(epoch, closes);
        if (pricesPosted[epoch]) revert AlreadyPosted();
        if (prices[0] != PRICE_ONE) revert BadPrices();
        for (uint256 i = 1; i < ASSETS; i++) {
            if (prices[i] == 0) revert BadPrices();
        }
        closePrices[epoch] = prices;
        pricesPosted[epoch] = true;
        emit PricesPosted(epoch, prices);
    }

    // ---------------------------------------------------------- settlement

    /// Settle one epoch for one strategy. Every public input of the proof is
    /// rebuilt here from state the hub already holds, except the two outputs.
    /// A proof made for other orders, other prices, another book or another
    /// strategy therefore does not verify.
    function settle(uint256 id, uint64 epoch, bytes32 newBook, uint64 nav, bytes calldata proof) external {
        Strategy storage s = strategies[id];
        if (msg.sender != s.owner) revert NotOwner();
        if (s.started && epoch <= s.lastEpoch) revert EpochNotAfterLast(epoch, s.lastEpoch);
        bytes32 orders = orderCommit[id][epoch];
        if (orders == bytes32(0)) revert NoOrders();
        if (!pricesPosted[epoch]) revert NoPrices();

        bytes32[] memory pub_ = new bytes32[](14);
        uint64[ASSETS] storage px = closePrices[epoch];
        pub_[0] = bytes32(id);
        pub_[1] = bytes32(uint256(epoch));
        pub_[2] = s.book;
        pub_[3] = orders;
        for (uint256 i = 0; i < ASSETS; i++) {
            pub_[4 + i] = bytes32(uint256(px[i]));
        }
        pub_[8] = bytes32(uint256(s.allowedMask));
        pub_[9] = bytes32(uint256(s.maxWeightBps));
        pub_[10] = bytes32(uint256(s.started ? 0 : 1));
        pub_[11] = bytes32(uint256(sandboxCapital));
        pub_[12] = newBook;
        pub_[13] = bytes32(uint256(nav));
        if (!verifier.verify(proof, pub_)) revert BadProof();

        s.book = newBook;
        s.lastEpoch = epoch;
        s.started = true;
        s.nav = nav;
        s.epochsSettled += 1;
        if (nav > s.peakNav) s.peakNav = nav;
        uint64 dd = s.peakNav == 0 ? 0 : uint64((uint256(s.peakNav - nav) * BPS) / s.peakNav);
        if (dd > s.maxDrawdownBps) s.maxDrawdownBps = dd;
        navAt[id][epoch] = nav;
        emit EpochSettled(id, epoch, newBook, nav, dd);
    }

    // --------------------------------------------------------------- views

    function strategyCount() external view returns (uint256) {
        return strategies.length;
    }

    function strategy(uint256 id) external view returns (Strategy memory) {
        return strategies[id];
    }

    function pricesAt(uint64 epoch) external view returns (uint64[ASSETS] memory) {
        return closePrices[epoch];
    }

    /// Return on sandbox capital, in basis points, from proven NAV only.
    function returnBps(uint256 id) external view returns (int256) {
        Strategy storage s = strategies[id];
        if (!s.started) return 0;
        return (int256(uint256(s.nav)) - int256(uint256(sandboxCapital))) * int256(uint256(BPS)) / int256(uint256(sandboxCapital));
    }
}
