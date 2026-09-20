# High Roll ABI integration

The adjacent `abi/*.json` files are standard ABI arrays generated from compiler
artifacts, including constructors, functions, events and custom errors.
Amounts are uint256 ROLL minor units (18 decimals). Game IDs are uint256.

## Token

`HighRollToken()` mints exactly 10^27 units to its deployer.
`name()`, `symbol()`, `decimals()`, `totalSupply()`, `balanceOf(address)` and
`allowance(address,address)` are reads. `approve(spender,amount)`,
`transfer(to,amount)` and `transferFrom(from,to,amount)` return bool and emit
standard Approval/Transfer events. Approval replaces the previous value;
uint256.max is unlimited and is not decremented. Revoke unused approvals with
zero; prefer exact game stake allowances. Changing a live nonzero allowance can
race a spender, as with standard ERC-20 approvals. Zero recipient/spender
addresses, insufficient balances and insufficient allowances revert.

## Game

| Function | Behavior |
| --- | --- |
| `HighRoll(address tokenAddress)` | Nonpayable constructor; immutable token with deployed code required |
| `token()` | Token address |
| `REVEAL_WINDOW()` | 86400 seconds |
| `nextGameId()` | Count of successfully opened games; enumerate `[0, nextGameId)` |
| `commitmentHash(uint8 roll, bytes32 salt)` | Pure keccak256 of standard ABI encoding; helper does not validate range |
| `openGame(uint256 stake, bytes32 commitment)` | Pull stake from caller; returns game ID |
| `joinGame(uint256 id, uint256 expectedStake, bytes32 commitment)` | Pull exact matching stake, start window |
| `reveal(uint256 id, uint8 roll, bytes32 salt)` | Reveal as a participant; settle atomically on second valid reveal |
| `settle(uint256 id)` | Anyone triggers single-reveal forfeit at/after deadline |
| `cancel(uint256 id)` | Opener cancels unmatched, or either player refunds expired zero-reveal game |
| `games(uint256 id)` | Flat tuple described below; unknown IDs return zero fields |

`games` returns, in order: player1 (address), player2 (address), stake (uint256),
commitment1 (bytes32), commitment2 (bytes32), deadline (uint256 UNIX seconds),
roll1 (uint8), roll2 (uint8), state (uint8 enum). State numbers are None=0, Open=1,
Active=2, Settled=3, Cancelled=4. Roll zero means not revealed. Deadline is zero
before join. Records remain readable after terminal transitions; derive the
winner from rolls or the Settled event. All write functions are nonpayable.

For viem, the hash expression is
`keccak256(encodeAbiParameters([{type:'uint8'}, {type:'bytes32'}], [roll, salt]))`.
Do not use `encodePacked`. The pure contract helper is a cross-check, but do not
send a secret to a public RPC to compute it; calculate locally.

## Events and indexing

- `Opened(uint256 indexed gameId, address indexed player, uint256 stake, bytes32 commitment)`
- `Joined(uint256 indexed gameId, address indexed player, bytes32 commitment, uint256 deadline)`
- `Revealed(uint256 indexed gameId, address indexed player, uint8 roll)`
- `Settled(uint256 indexed gameId, address indexed winner, uint256 pot)` — zero winner means tie;
  pot is both stakes even for ties, with half returned to each player.
- `Cancelled(uint256 indexed gameId)` — distinguish unmatched versus expired by the stored player2.

Index from the service-provided deployment block, handle reorgs and confirm with
`games(id)`. Events from reverted transactions do not survive. No owner or fee
recipient exists, and settle callers never receive the pot. There is no enumeration
of a user's games beyond event indexing or scanning IDs.

Custom errors: InvalidToken, InvalidStake, InvalidCommitment, InvalidState,
NotPlayer, SamePlayer, InvalidRoll, AlreadyRevealed, DeadlinePassed, TooEarly,
TransferFailed, Reentrancy. Token errors can bubble through game calls.
Checks occur in source order, so a transaction violating several rules may return
only the first error. Simulate against current state, and surface an actionable
retry/refund/settlement option without exposing the user's secret.
