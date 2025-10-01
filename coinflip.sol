// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract CoinFlip {
    address public owner;
    uint256 public minBet;
    uint256 public maxBet;

    mapping(address => uint256) public pendingPrizes;
    uint256 public totalPending;

    struct UserStats { uint256 totalBet; uint256 totalWon; uint256 totalLost; }
    mapping(address => UserStats) private _stats;
    uint256 public globalTotalBet;

    uint256 private _entropy;
    mapping(address => uint256) private _nonces;
    uint256 private _lock;

    event Deposited(address from, uint256 amount);
    event Flipped(address player, uint256 amount, bool guess, bool result, bool won);
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
        return bal > totalPending ? bal - totalPending : 0;
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

    function flip(bool guess, uint256 betAmount) external payable nonReentrant {
        if (msg.value != betAmount || betAmount < minBet || betAmount > maxBet) revert InvalidBet();
        // Ensure worst-case (win) is coverable before rolling
        if (availableBank() < betAmount * 2) revert InsufficientBank();

        uint256 r = _rand();
        bool result = (r & 1) == 1; // true=heads
        bool won = (result == guess);
        uint256 payout = won ? betAmount * 2 : 0;

        _stats[msg.sender].totalBet += betAmount;
        globalTotalBet += betAmount;

        if (won) {
            // now guaranteed by pre-check, but keep guard
            if (availableBank() < payout) revert InsufficientBank();
            pendingPrizes[msg.sender] += payout;
            totalPending += payout;
            _stats[msg.sender].totalWon += payout;
        } else {
            _stats[msg.sender].totalLost += betAmount;
        }

        emit Flipped(msg.sender, betAmount, guess, result, won);
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

    function getUserStats(address user) external view returns (uint256 totalBet, uint256 totalWon, uint256 totalLost) {
        UserStats memory s = _stats[user];
        return (s.totalBet, s.totalWon, s.totalLost);
    }

    function getGlobalStats() external view returns (uint256 totalBet) {
        return globalTotalBet;
    }
}