// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IRollToken {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @notice Two players commit chosen rolls, escrow equal ROLL stakes and reveal within 24 hours.
/// @dev Only deploy with HighRollToken; arbitrary fee-bearing or dishonest tokens are unsupported.
contract HighRoll {
    enum State {
        None,
        Open,
        Active,
        Settled,
        Cancelled
    }

    struct Game {
        address player1;
        address player2;
        uint256 stake;
        bytes32 commitment1;
        bytes32 commitment2;
        uint256 deadline;
        uint8 roll1;
        uint8 roll2;
        State state;
    }

    IRollToken public immutable token;
    uint256 public constant REVEAL_WINDOW = 24 hours;
    uint256 public nextGameId;
    mapping(uint256 => Game) public games;
    uint256 private entered;

    error InvalidToken();
    error InvalidStake();
    error InvalidCommitment();
    error InvalidState();
    error NotPlayer();
    error SamePlayer();
    error InvalidRoll();
    error AlreadyRevealed();
    error DeadlinePassed();
    error TooEarly();
    error TransferFailed();
    error Reentrancy();

    event Opened(uint256 indexed gameId, address indexed player, uint256 stake, bytes32 commitment);
    event Joined(uint256 indexed gameId, address indexed player, bytes32 commitment, uint256 deadline);
    event Revealed(uint256 indexed gameId, address indexed player, uint8 roll);
    /// @dev winner == address(0) denotes a tie; pot is the total returned or paid.
    event Settled(uint256 indexed gameId, address indexed winner, uint256 pot);
    event Cancelled(uint256 indexed gameId);

    constructor(address tokenAddress) {
        if (tokenAddress.code.length == 0) revert InvalidToken();
        token = IRollToken(tokenAddress);
    }

    modifier nonReentrant() {
        if (entered != 0) revert Reentrancy();
        entered = 1;
        _;
        entered = 0;
    }

    /// @notice Hash with ABI encoding (not packed encoding). Use a fresh secret 32-byte salt per game/player.
    function commitmentHash(uint8 roll, bytes32 salt) public pure returns (bytes32) {
        return keccak256(abi.encode(roll, salt));
    }

    function openGame(uint256 stake, bytes32 commitment) external nonReentrant returns (uint256 id) {
        if (stake == 0 || stake > type(uint256).max / 2) revert InvalidStake();
        if (commitment == bytes32(0)) revert InvalidCommitment();
        id = nextGameId++;
        games[id] = Game(msg.sender, address(0), stake, commitment, bytes32(0), 0, 0, 0, State.Open);
        emit Opened(id, msg.sender, stake, commitment);
        _take(msg.sender, stake);
    }

    /// @notice expectedStake protects against joining an unintended wager amount.
    function joinGame(uint256 id, uint256 expectedStake, bytes32 commitment) external nonReentrant {
        Game storage game = games[id];
        if (game.state != State.Open) revert InvalidState();
        if (msg.sender == game.player1) revert SamePlayer();
        if (expectedStake != game.stake) revert InvalidStake();
        if (commitment == bytes32(0) || commitment == game.commitment1) revert InvalidCommitment();
        game.player2 = msg.sender;
        game.commitment2 = commitment;
        game.deadline = block.timestamp + REVEAL_WINDOW;
        game.state = State.Active;
        emit Joined(id, msg.sender, commitment, game.deadline);
        _take(msg.sender, game.stake);
    }

    /// @notice The second valid reveal settles atomically. Reveals are allowed strictly before deadline.
    function reveal(uint256 id, uint8 roll, bytes32 salt) external nonReentrant {
        Game storage game = games[id];
        if (game.state != State.Active) revert InvalidState();
        if (block.timestamp >= game.deadline) revert DeadlinePassed();
        if (roll < 1 || roll > 6) revert InvalidRoll();
        bytes32 commitment = commitmentHash(roll, salt);
        if (msg.sender == game.player1) {
            if (game.roll1 != 0) revert AlreadyRevealed();
            if (commitment != game.commitment1) revert InvalidCommitment();
            game.roll1 = roll;
        } else if (msg.sender == game.player2) {
            if (game.roll2 != 0) revert AlreadyRevealed();
            if (commitment != game.commitment2) revert InvalidCommitment();
            game.roll2 = roll;
        } else {
            revert NotPlayer();
        }
        emit Revealed(id, msg.sender, roll);
        if (game.roll1 != 0 && game.roll2 != 0) _settle(id, game);
    }

    /// @notice Anyone can trigger forfeit settlement at or after the deadline; callers receive nothing.
    function settle(uint256 id) external nonReentrant {
        Game storage game = games[id];
        if (game.state != State.Active) revert InvalidState();
        if (block.timestamp < game.deadline) revert TooEarly();
        if (game.roll1 == 0 && game.roll2 == 0) revert InvalidState();
        _settle(id, game);
    }

    /// @notice Opener cancels an unmatched game; either player cancels an expired game with no reveals.
    function cancel(uint256 id) external nonReentrant {
        Game storage game = games[id];
        if (msg.sender != game.player1 && msg.sender != game.player2) revert NotPlayer();
        if (game.state == State.Active) {
            if (block.timestamp < game.deadline) revert TooEarly();
            if (game.roll1 != 0 || game.roll2 != 0) revert InvalidState();
        } else if (game.state != State.Open) {
            revert InvalidState();
        }
        game.state = State.Cancelled;
        emit Cancelled(id);
        _pay(game.player1, game.stake);
        if (game.player2 != address(0)) _pay(game.player2, game.stake);
    }

    function _settle(uint256 id, Game storage game) private {
        game.state = State.Settled;
        address winner = address(0);
        if (game.roll1 > game.roll2) winner = game.player1;
        else if (game.roll2 > game.roll1) winner = game.player2;
        emit Settled(id, winner, 2 * game.stake);
        if (winner == address(0)) {
            _pay(game.player1, game.stake);
            _pay(game.player2, game.stake);
        } else {
            _pay(winner, 2 * game.stake);
        }
    }

    function _take(address from, uint256 amount) private {
        if (!token.transferFrom(from, address(this), amount)) revert TransferFailed();
    }

    function _pay(address to, uint256 amount) private {
        if (!token.transfer(to, amount)) revert TransferFailed();
    }
}
