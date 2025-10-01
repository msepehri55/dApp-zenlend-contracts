// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/*
  CrashGlobal: shared rounds for all players.
  - One global round at a time with:
      roundId, startTime, bettingEndsAt, crashX10
  - Anyone can openNextRound() once betting closes.
  - Owner can forceCloseBetting() early for testing.
  - play(betAmount, autoX10) keeps the same signature as your UI expects.
  - 2% house edge; pendingPrizes pull-claim; user stats tracked.
  - Simple bankroll solvency checks; 25% per-bet cap consistent with your UI.

  NOTE:
  - This picks crashX10 at round start using block.prevrandao; OK for testnet demo.
  - For real fairness, use a VRF or commit-reveal; out of scope for now.
*/

abstract contract GameBase {
  address public immutable owner;
  uint256 public immutable minBet;
  uint256 public immutable maxBet;

  mapping(address => uint256) public pendingPrizes;
  uint256 internal totalPending;

  struct Stats { uint256 totalBet; uint256 totalWon; uint256 totalLost; }
  mapping(address => Stats) internal userStats;
  uint256 internal globalTotalBet;

  event Deposited(address indexed from, uint256 amount);
  event PrizeClaimed(address indexed player, uint256 amount);
  event Withdrawn(address indexed to, uint256 amount);

  error NotOwner();
  error InvalidBet();
  error InsufficientBankroll();

  bool private _locked;
  modifier nonReentrant() {
    require(!_locked, "REENTRANCY");
    _locked = true;
    _;
    _locked = false;
  }

  constructor(uint256 _minBet, uint256 _maxBet) payable {
    owner = msg.sender;
    minBet = _minBet;
    maxBet = _maxBet;
  }

  function deposit() external payable {
    emit Deposited(msg.sender, msg.value);
  }

  function claimPrize() external nonReentrant {
    uint256 amount = pendingPrizes[msg.sender];
    require(amount > 0, "Nothing to claim");
    pendingPrizes[msg.sender] = 0;
    totalPending -= amount;
    (bool ok, ) = payable(msg.sender).call{ value: amount }("");
    require(ok, "Transfer failed");
    emit PrizeClaimed(msg.sender, amount);
  }

  function withdraw() external nonReentrant {
    if (msg.sender != owner) revert NotOwner();
    uint256 free = address(this).balance - totalPending;
    require(free > 0, "Nothing to withdraw");
    (bool ok, ) = payable(owner).call{ value: free }("");
    require(ok, "Transfer failed");
    emit Withdrawn(owner, free);
  }

  function getBalance() external view returns (uint256) {
    return address(this).balance;
  }

  function getUserStats(address user) external view returns (uint256 totalBet, uint256 totalWon, uint256 totalLost) {
    Stats memory s = userStats[user];
    return (s.totalBet, s.totalWon, s.totalLost);
  }

  function getGlobalStats() external view returns (uint256 totalBet) {
    return globalTotalBet;
  }

  receive() external payable {
    emit Deposited(msg.sender, msg.value);
  }

  // 2% house edge
  uint256 internal constant EDGE_BPS = 9800; // 98%
  uint256 internal constant BPS_DEN  = 10000;

  function _applyEdge(uint256 gross) internal pure returns (uint256) {
    return gross * EDGE_BPS / BPS_DEN;
  }

  uint256 internal _nonce;
  function _rand() internal returns (uint256) {
    unchecked { _nonce++; }
    return uint256(keccak256(abi.encodePacked(block.prevrandao, block.timestamp, msg.sender, address(this), _nonce)));
  }

  function _freeBankroll() internal view returns (uint256) {
    return address(this).balance - totalPending;
  }

  function _requireValidBet(uint256 betAmount) internal view {
    if (betAmount < minBet || betAmount > maxBet) revert InvalidBet();
  }

  function _award(address player, uint256 betAmount, uint256 payout) internal {
    if (payout > 0) {
      if (payout > _freeBankroll()) revert InsufficientBankroll();
      pendingPrizes[player] += payout;
      totalPending += payout;
      userStats[player].totalWon += payout;
    } else {
      userStats[player].totalLost += betAmount;
    }
    userStats[player].totalBet += betAmount;
    globalTotalBet += betAmount;
  }
}

contract CrashGlobal is GameBase {
  // Phases are a UI convenience. Contract only enforces betting close time.
  // 0=betting, 1=post-bet (in-progress/crashed from UI point of view)
  struct RoundData {
    uint64 startTime;      // seconds
    uint64 bettingEndsAt;  // seconds
    uint16 crashX10;       // e.g. 150 => 15.0x
  }

  uint256 public roundId;
  RoundData public round;

  uint32 public immutable bettingWindowSec; // e.g., 5
  // Optional dev control
  event RoundStarted(uint256 indexed roundId, uint64 startTime, uint64 bettingEndsAt, uint16 crashX10);
  event BettingClosed(uint256 indexed roundId, uint64 when);
  event Played(address indexed player, uint256 indexed roundId, uint256 amount, uint16 autoX10, uint16 crashX10, bool won);

  constructor(uint256 _minBet, uint256 _maxBet, uint32 _bettingWindowSec) payable GameBase(_minBet, _maxBet) {
    bettingWindowSec = _bettingWindowSec;
    _startNewRound();
  }

  // Public view usable by frontend to synchronize curve
  function getRound() external view returns (
    uint256 id,
    uint64 startTime,
    uint64 bettingEndsAt,
    uint16 crashX10,
    uint8 phase
  ) {
    id = roundId;
    startTime = round.startTime;
    bettingEndsAt = round.bettingEndsAt;
    crashX10 = round.crashX10;
    phase = (block.timestamp < bettingEndsAt) ? 0 : 1;
  }

  // Place bet during betting window
  function play(uint256 betAmount, uint16 autoX10) external payable nonReentrant {
    _requireValidBet(betAmount);
    require(msg.value == betAmount, "Bad msg.value");
    require(block.timestamp < round.bettingEndsAt, "Betting closed");
    require(autoX10 >= 11 && autoX10 <= 300, "1.1x..30x");

    // Determine outcome for this round
    uint16 crashX10 = round.crashX10;
    bool won = (autoX10 <= crashX10);

    uint256 payout = 0;
    if (won) {
      payout = _applyEdge(betAmount * uint256(autoX10) / 10);

      uint256 free = _freeBankroll();
      // 25% cap (per-bet) and solvency
      uint256 cap = (free * 2500) / 10000;
      require(payout <= free, "Pool too low");
      require(payout <= cap,  "Exceeds 25% cap");
    }

    _award(msg.sender, betAmount, payout);
    emit Played(msg.sender, roundId, betAmount, autoX10, crashX10, won);
  }

  // Anyone can open next round once betting closed
  function openNextRound() external {
    require(block.timestamp >= round.bettingEndsAt, "Betting not closed");
    _startNewRound();
  }

  // Owner can close betting early (for testing/UI button)
  function forceCloseBetting() external {
    if (msg.sender != owner) revert NotOwner();
    if (block.timestamp < round.bettingEndsAt) {
      round.bettingEndsAt = uint64(block.timestamp);
      emit BettingClosed(roundId, uint64(block.timestamp));
    }
  }

  // Random heavy-tail: P(crash >= x) ~ 1/x, capped 30x
  function _pickCrashX10() internal returns (uint16) {
    uint256 r = _rand(); // big entropy
    // transform to [0,1)
    uint256 u1e9 = r % 1_000_000_000; // 0..1e9-1
    if (u1e9 == 0) u1e9 = 1;
    // inverse-like heavy tail: m = 1 / (1 - u)
    // x10 scale and clamp
    uint256 denom = 1_000_000_000 - u1e9; // avoid 0
    if (denom < 1) denom = 1;
    uint256 mX10 = (10 * 1_000_000_000) / denom;
    if (mX10 < 10) mX10 = 10;
    if (mX10 > 300) mX10 = 300;
    return uint16(mX10);
  }

  function _startNewRound() internal {
    roundId += 1;
    uint64 nowSec = uint64(block.timestamp);
    uint16 crashX10 = _pickCrashX10();
    round = RoundData({
      startTime: nowSec,
      bettingEndsAt: nowSec + bettingWindowSec,
      crashX10: crashX10
    });
    emit RoundStarted(roundId, round.startTime, round.bettingEndsAt, crashX10);
  }
}