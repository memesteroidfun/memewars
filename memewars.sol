// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC20 {
  function transfer(address to, uint256 amount) external returns (bool);
  function transferFrom(address from, address to, uint256 amount) external returns (bool);
  function balanceOf(address account) external view returns (uint256);
  function allowance(address owner, address spender) external view returns (uint256);
  function approve(address spender, uint256 amount) external returns (bool);
  function decimals() external view returns (uint8);
}

library PythStructs {
    struct Price {
        int64 price;
        uint64 conf;
        int32 expo;
        uint publishTime;
    }
}

interface IPyth {
    function getUpdateFee(bytes[] calldata updateData) external view returns (uint fee);
    function updatePriceFeeds(bytes[] calldata updateData) external payable;
    function getPriceNoOlderThan(bytes32 id, uint age) external view returns (PythStructs.Price memory price);
}

abstract contract Ownable {
    address public owner;
    event OwnershipTransferred(address indexed prev, address indexed next);
    modifier onlyOwner() { require(msg.sender == owner, "Ownable: not owner"); _; }
    constructor() { owner = msg.sender; emit OwnershipTransferred(address(0), msg.sender); }
    function transferOwnership(address next) external onlyOwner { require(next != address(0), "zero"); emit OwnershipTransferred(owner, next); owner = next; }
}
abstract contract ReentrancyGuard { uint256 private _g = 1; modifier nonReentrant(){ require(_g == 1, "reentrancy"); _g = 2; _; _g = 1; } }

contract MemeWarsPythImmutable is Ownable, ReentrancyGuard {
    IERC20 public immutable MUSD;
    IPyth  public immutable PYTH;

    uint40 public MIN_DURATION;
    uint40 public MAX_DURATION;
    uint40 public MAX_PYTH_AGE;
    uint96 public MIN_CREATOR_STAKE;
    uint16 public feeBps;

    uint16 public constant CLOSE_PCT_BPS = 1000;
    uint40 public constant MIN_CLOSE_BUFFER = 30 minutes;
    uint40 public constant MAX_CLOSE_BUFFER = 24 hours;

    mapping(bytes32 => bool) public allowedPriceId;

    uint16 public constant BET_FEE_BPS = 100;

    enum Status { Open, Locked, Settled, Voided, Expired }
    struct Market {
        bytes32 priceId;
        int64   threshold1e8;
        uint40  createdAt;
        uint40  betCloseTime;
        uint40  settlementTime;
        uint128 poolYes;
        uint128 poolNo;
        address creator;
        bool    creatorSideYes;
        Status  status;
        bool    yesWon;
        uint32  uniqueBettors;
    }
    uint64 public nextMarketId = 1;
    mapping(uint64 => Market) public markets;

    struct UserPos { uint128 yes; uint128 no; bool claimed; }
    mapping(uint64 => mapping(address => UserPos)) public positions;
    mapping(uint64 => mapping(address => bool)) private _hasBet;

    event MarketCreated(
        uint64 indexed id,
        bytes32 indexed priceId,
        int64 threshold1e8,
        uint40 settlementTime,
        uint40 betCloseTime,
        address indexed creator,
        bool creatorSideYes,
        uint256 creatorStake
    );
    event BetPlaced(
        uint64 indexed id,
        address indexed user,
        bool isYes,
        uint256 amount,
        uint256 poolYesAfter,
        uint256 poolNoAfter
    );
    event MarketLocked(uint64 indexed id);
    event MarketSettled(uint64 indexed id, bool yesWon, int64 finalPrice1e8);
    event MarketVoided(uint64 indexed id, uint8 reasonCode);
    event Claimed(uint64 indexed id, address indexed user, uint256 amount);
    event Refunded(uint64 indexed id, address indexed user, uint256 amount);
    event PriceIdAllowed(bytes32 indexed id, bool allowed);

    constructor(
        address _musd,
        address _pyth,
        uint40 _minDuration,
        uint40 _maxDuration,
        uint40 _maxPythAge,
        uint96 _minCreatorStake
    ) {
        require(_musd != address(0) && _pyth != address(0), "zero addr");
        MUSD = IERC20(_musd);
        PYTH = IPyth(_pyth);
        require(_minDuration > 0 && _maxDuration >= _minDuration, "bad dur");
        MIN_DURATION = _minDuration;
        MAX_DURATION = _maxDuration;
        MAX_PYTH_AGE = _maxPythAge;
        MIN_CREATOR_STAKE = _minCreatorStake;
        feeBps = 0;
    }

    function setParams(
        uint40 _minDuration,
        uint40 _maxDuration,
        uint40 _maxPythAge,
        uint96 _minCreatorStake,
        uint16 _feeBps
    ) external onlyOwner {
        require(_minDuration > 0 && _maxDuration >= _minDuration, "bad dur");
        require(_feeBps <= 10000, "fee>100%");
        MIN_DURATION = _minDuration;
        MAX_DURATION = _maxDuration;
        MAX_PYTH_AGE = _maxPythAge;
        MIN_CREATOR_STAKE = _minCreator_STAKE_SAFE(_minCreatorStake);
        feeBps = _feeBps;
    }

    function _minCreator_STAKE_SAFE(uint96 v) internal pure returns (uint96) { return v; }

    function setPriceIdAllowed(bytes32 id, bool allowed) external onlyOwner {
        allowedPriceId[id] = allowed;
        emit PriceIdAllowed(id, allowed);
    }

    function setPriceIdAllowedBatch(bytes32[] calldata ids, bool allowed) external onlyOwner {
        for (uint256 i = 0; i < ids.length; i++) {
            allowedPriceId[ids[i]] = allowed;
            emit PriceIdAllowed(ids[i], allowed);
        }
    }

    function adminVoid(uint64 id) external onlyOwner {
        Market storage m = markets[id];
        require(m.status == Status.Open || m.status == Status.Locked, "not open/locked");
        m.status = Status.Voided;
        emit MarketVoided(id, 2);
    }

    function createMarket(
        bytes32 priceId,
        int64 threshold1e8,
        uint40 settlementTime,
        bool creatorSideYes,
        uint256 creatorStake
    ) external nonReentrant returns (uint64 id) {
        require(allowedPriceId[priceId], "priceId not allowed");
        require(threshold1e8 > 0, "bad threshold");
        require(settlementTime > block.timestamp + MIN_DURATION, "too soon");
        require(settlementTime <= block.timestamp + MAX_DURATION, "too far");
        require(creatorStake >= MIN_CREATOR_STAKE, "stake too low");

        uint40 betCloseTime = uint40(settlementTime - _computeCloseBuffer(uint40(settlementTime - uint40(block.timestamp))));
        require(betCloseTime > block.timestamp, "close<=now");

        id = nextMarketId++;
        Market storage m = markets[id];
        m.priceId = priceId;
        m.threshold1e8 = threshold1e8;
        m.createdAt = uint40(block.timestamp);
        m.betCloseTime = betCloseTime;
        m.settlementTime = settlementTime;
        m.creator = msg.sender;
        m.creatorSideYes = creatorSideYes;
        m.status = Status.Open;

        uint256 netStake = _takeFeeAndCredit(m, id, creatorSideYes, creatorStake);

        emit MarketCreated(id, priceId, threshold1e8, settlementTime, betCloseTime, msg.sender, creatorSideYes, netStake);
        emit BetPlaced(id, msg.sender, creatorSideYes, netStake, m.poolYes, m.poolNo);
    }

    function placeBet(uint64 id, bool isYes, uint256 amount) external nonReentrant {
        Market storage m = markets[id];
        require(m.status == Status.Open, "not open");
        require(block.timestamp < m.betCloseTime, "closed");
        require(amount > 0, "zero");

        uint256 net = _takeFeeAndCredit(m, id, isYes, amount);
        emit BetPlaced(id, msg.sender, isYes, net, m.poolYes, m.poolNo);
    }

    function lock(uint64 id) external {
        Market storage m = markets[id];
        require(m.status == Status.Open, "bad status");
        require(block.timestamp >= m.betCloseTime, "not yet");
        m.status = Status.Locked;
        emit MarketLocked(id);
    }

    function settle(uint64 id, bytes[] calldata updateData) external payable nonReentrant {
        Market storage m = markets[id];
        require(block.timestamp >= m.settlementTime, "too early");
        require(m.status == Status.Open || m.status == Status.Locked, "bad status");

        if (m.uniqueBettors <= 1) {
            m.status = Status.Expired;
            emit MarketVoided(id, 1);
            return;
        }
        if (m.poolYes == 0 || m.poolNo == 0) {
            m.status = Status.Voided;
            emit MarketVoided(id, 1);
            return;
        }

        uint fee = PYTH.getUpdateFee(updateData);
        require(msg.value >= fee, "pyth fee");
        PYTH.updatePriceFeeds{value: fee}(updateData);
        if (msg.value > fee) {
            unchecked { payable(msg.sender).transfer(msg.value - fee); }
        }

        PythStructs.Price memory p = PYTH.getPriceNoOlderThan(m.priceId, MAX_PYTH_AGE);
        int256 norm = _normalizeTo1e8(p.price, p.expo);
        require(norm > 0, "bad price");

        bool yesWon = norm >= int256(m.threshold1e8);
        m.yesWon = yesWon;
        m.status = Status.Settled;

        emit MarketSettled(id, yesWon, int64(norm));
    }

    function claim(uint64 id) external nonReentrant {
        Market storage m = markets[id];
        require(m.status == Status.Settled, "not settled");

        UserPos storage up = positions[id][msg.sender];
        require(!up.claimed, "claimed");

        uint256 stake = m.yesWon ? up.yes : up.no;
        require(stake > 0, "no win");

        uint256 Y = m.poolYes;
        uint256 N = m.poolNo;
        uint256 winningPool = m.yesWon ? Y : N;
        uint256 loserPool = m.yesWon ? N : Y;

        uint256 feeCut = (feeBps == 0) ? 0 : (loserPool * feeBps) / 10_000;
        uint256 distributableLoser = loserPool - feeCut;

        uint256 payout = stake + (stake * distributableLoser) / winningPool;

        up.claimed = true;
        _safeTransfer(MUSD, msg.sender, payout);
        emit Claimed(id, msg.sender, payout);
    }

    function refund(uint64 id) external nonReentrant {
        Market storage m = markets[id];
        require(m.status == Status.Voided || m.status == Status.Expired, "no refund");

        UserPos storage up = positions[id][msg.sender];
        require(!up.claimed, "claimed");
        uint256 amt = uint256(up.yes) + uint256(up.no);
        require(amt > 0, "nothing");

        up.claimed = true;
        _safeTransfer(MUSD, msg.sender, amt);
        emit Refunded(id, msg.sender, amt);
    }

    function computeBetCloseTime(uint40 nowTs, uint40 settlementTime) external pure returns (uint40) {
        require(settlementTime > nowTs, "bad T");
        uint40 duration = settlementTime - nowTs;
        uint40 buffer = _computeCloseBuffer(duration);
        return settlementTime - buffer;
    }

    function _takeFeeAndCredit(Market storage m, uint64 id, bool isYes, uint256 amount) private returns (uint256 net) {
        _safeTransferFrom(MUSD, msg.sender, address(this), amount);
        uint256 fee = (amount * BET_FEE_BPS) / 10_000;
        if (fee > 0) { _safeTransfer(MUSD, owner, fee); }
        net = amount - fee;
        UserPos storage up = positions[id][msg.sender];
        if (isYes) {
            m.poolYes += uint128(net);
            up.yes += uint128(net);
        } else {
            m.poolNo += uint128(net);
            up.no += uint128(net);
        }
        if (!_hasBet[id][msg.sender]) { _hasBet[id][msg.sender] = true; m.uniqueBettors += 1; }
    }

    function _computeCloseBuffer(uint40 duration) internal pure returns (uint40) {
        uint256 pct = (uint256(duration) * CLOSE_PCT_BPS) / 10_000;
        uint40 b = uint40(pct);
        if (b < MIN_CLOSE_BUFFER) return MIN_CLOSE_BUFFER;
        if (b > MAX_CLOSE_BUFFER) return MAX_CLOSE_BUFFER;
        return b;
    }

    function _normalizeTo1e8(int64 price, int32 expo) internal pure returns (int256) {
        int256 p = int256(price);
        int32 e = expo + 8;
        if (e == 0) return p;
        if (e > 0) {
            return p * int256(10 ** uint32(uint32(e)));
        } else {
            return p / int256(10 ** uint32(uint32(-e)));
        }
    }

    function _safeTransfer(IERC20 t, address to, uint256 amt) internal {
        require(address(t) != address(0), "token0");
        bool ok = t.transfer(to, amt);
        require(ok, "transfer");
    }
    function _safeTransferFrom(IERC20 t, address from, address to, uint256 amt) internal {
        require(address(t) != address(0), "token0");
        bool ok = t.transferFrom(from, to, amt);
        require(ok, "transferFrom");
    }

    receive() external payable {}
}
