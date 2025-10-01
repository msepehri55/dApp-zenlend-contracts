// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract Wheel {
    address public owner;
    uint256 public minBet;
    uint256 public maxBet;

    mapping(address => uint256) public pendingPrizes;
    uint256 public totalPending;

    struct UserStats { uint256 totalBet; uint256 totalWon; uint256 totalLost; }
    mapping(address => UserStats) private _stats;

    struct LastOutcome {
        uint8 outcomeIndex;      // 0..6
        uint16 multiplierX10;    // 0, 15, 20, 30, 50, 100
        bool won;                // multiplier > 0
        uint256 amount;          // bet amount for this outcome
        uint64 nonce;            // per-user spin counter
    }
    mapping(address => LastOutcome) private _lastOutcome;
    mapping(address => uint64) private _userNonce;

    uint256 private _entropy;
    mapping(address => uint256) private _nonces;
    uint256 private _lock;

    event Deposited(address from, uint256 amount);
    event Spun(address player, uint256 amount, uint8 outcomeIndex, int256 multiplierX10, bool won);
    event PrizeClaimed(address player, uint256 amount);
    event Withdrawn(address to, uint256 amount);

    error NotOwner();
    error InvalidBet();
    error InvalidAmount();
    error InsufficientBank();
    error NothingToClaim();
    error Reentrancy();

    modifier onlyOwner() { if (msg.sender != owner) revert NotOwner(); _; }
    modifier nonReentrant() { if (_lock == 1) revert Reentrancy(); _lock = 1; _; _lock = 0; }

    constructor(uint256 _minBet, uint256 _maxBet) payable {
        require(_minBet > 0 && _maxBet >= _minBet, "Invalid limits");
        owner = msg.sender;
        minBet = _minBet;
        maxBet = _maxBet;
        _entropy = uint256(keccak256(abi.encodePacked(
            blockhash(block.number - 1), block.prevrandao, block.timestamp, msg.sender, address(this)
        )));
        if (msg.value > 0) emit Deposited(msg.sender, msg.value);
    }

    receive() external payable { emit Deposited(msg.sender, msg.value); }
    function deposit() external payable { if (msg.value == 0) revert InvalidAmount(); emit Deposited(msg.sender, msg.value); }
    function getBalance() external view returns (uint256) { return address(this).balance; }

    function availableBank() public view returns (uint256) {
        uint256 bal = address(this).balance;
        return bal > totalPending ? (bal - totalPending) : 0;
    }

    function claimPrize() external nonReentrant {
        uint256 amount = pendingPrizes[msg.sender];
        if (amount == 0) revert NothingToClaim();
        pendingPrizes[msg.sender] = 0;
        totalPending -= amount;
        (bool ok, ) = payable(msg.sender).call{ value: amount }("");
        require(ok, "Transfer failed");
        emit PrizeClaimed(msg.sender, amount);
    }

    function withdraw() external onlyOwner nonReentrant {
        uint256 amount = availableBank();
        if (amount == 0) revert InsufficientBank();
        (bool ok, ) = payable(owner).call{ value: amount }("");
        require(ok, "Withdraw failed");
        emit Withdrawn(owner, amount);
    }

    // Index mapping: 0..6 -> [Lose, Lose, 1.5x, 2x, 3x, 5x, 10x]
    // Probabilities (basis points): [2250, 2250, 1800, 1800, 1000, 600, 300] => 10000
    function spin(uint256 betAmount) external payable nonReentrant {
        if (msg.value != betAmount || betAmount < minBet || betAmount > maxBet) revert InvalidBet();

        // Ensure worst-case payout (10x) is coverable before accepting
        if (availableBank() < betAmount * 10) revert InsufficientBank();

        uint16[7] memory weights = [uint16(1900), uint16(1900), uint16(2200), uint16(2100), uint16(1000), uint16(600), uint16(300)];
        uint16[7] memory M       = [uint16(0),    uint16(0),    uint16(15),   uint16(20),   uint16(30),   uint16(50),  uint16(100)];

        uint256 r = _randBound(10000); // unbiased 0..9999
        uint16 acc = 0;
        uint8 idx = 0;
        for (uint8 i = 0; i < 7; i++) {
            acc += weights[i];
            if (r < acc) { idx = i; break; }
        }

        uint16 mx10u = M[idx];
        bool won = mx10u > 0;

        _stats[msg.sender].totalBet += betAmount;

        if (won) {
            uint256 payout = (betAmount * mx10u) / 10;
            // Pre-check assures solvency; reserve payout
            pendingPrizes[msg.sender] += payout;
            totalPending += payout;
            _stats[msg.sender].totalWon += payout;
        } else {
            _stats[msg.sender].totalLost += betAmount;
        }

        // Record last outcome for reliable UI retrieval
        uint64 n = ++_userNonce[msg.sender];
        _lastOutcome[msg.sender] = LastOutcome({
            outcomeIndex: idx,
            multiplierX10: mx10u,
            won: won,
            amount: betAmount,
            nonce: n
        });

        emit Spun(msg.sender, betAmount, idx, int256(uint256(mx10u)), won);
    }

    function _rand() internal returns (uint256 out) {
        unchecked {
            out = uint256(keccak256(abi.encodePacked(
                _entropy,
                block.prevrandao,
                blockhash(block.number - 1),
                msg.sender,
                address(this),
                _nonces[msg.sender]++,
                gasleft()
            )));
            _entropy ^= out;
        }
    }

    // Rejection sampling to avoid modulo bias
    function _randBound(uint256 mod) internal returns (uint256) {
        uint256 x = _rand();
        uint256 limit = type(uint256).max - (type(uint256).max % mod);
        while (x >= limit) {
            x = uint256(keccak256(abi.encodePacked(x, blockhash(block.number - 1), msg.sender, gasleft())));
        }
        return x % mod;
    }

    // Reliable read for frontend (fallback if event logs parsing fails)
    function getLastOutcome(address user) external view returns (
        uint8 outcomeIndex,
        uint16 multiplierX10,
        bool won,
        uint256 amount,
        uint64 nonce
    ) {
        LastOutcome memory o = _lastOutcome[user];
        return (o.outcomeIndex, o.multiplierX10, o.won, o.amount, o.nonce);
    }

    function getUserStats(address user) external view returns (uint256 totalBet, uint256 totalWon, uint256 totalLost) {
        UserStats memory s = _stats[user];
        return (s.totalBet, s.totalWon, s.totalLost);
    }
}