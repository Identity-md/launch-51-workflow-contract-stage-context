# High Roll — contract contribution

High Roll is a two-player, equal-stake commit/reveal game using High Roll (ROLL).
This contribution contains the token and game, Foundry tests, ABI exports and
integration documentation. It is not an independent security review.

**Rolls are chosen by players, not randomly generated.** Choosing 6 is a dominant
strategy under these rules. Commit/reveal hides a choice until revelation; it
does not make that choice fair or random. This implementation follows the approved
chosen-roll rules and makes no randomness claim. A random-dice product would
require a separately approved design and verifiable randomness mechanism.

## Build and verify offline

Requires Foundry and Python 3. Solidity 0.8.26 for Linux x86-64 and forge-std v1.9.7
are included as ordinary files; there are no submodules or network dependencies.

```sh
export XDG_DATA_HOME="$PWD/toolchain"
forge build --offline
forge test --offline
forge fmt --check
python3 scripts/export_abi.py --check
# Or run the same checks together:
bash scripts/check.sh
```

The local compiler cache avoids writing to a read-only home directory. See
[toolchain provenance](toolchain/README.md) for its checksum, platform and SVM cache
selection caveat. Compiler selection in foundry.toml is a version, with Cancun EVM,
optimizer 200 runs, no bytecode metadata hash and no CBOR trailer. FFI and cheatcode
filesystem permissions are disabled. Test dependencies are vendored from
https://github.com/foundry-rs/forge-std/releases/tag/v1.9.7 under `lib/forge-std/src`,
with both upstream licenses preserved.

After changing source, run `forge build --offline` and
`python3 scripts/export_abi.py` to regenerate `docs/abi/HighRollToken.json` and
`docs/abi/HighRoll.json`. [ABI usage](docs/ABI.md) describes all game methods,
storage and events.

## Rules, custody and timeouts

1. Approve the game to spend the chosen positive stake in ROLL minor units.
   Call `openGame(stake, commitment)` to escrow that stake. IDs begin at zero.
2. A different account approves and calls `joinGame(id, expectedStake, commitment)`.
   The stake must exactly match; zero commitments and a commitment identical to
   the opener's are rejected. A game has exactly two players. The join starts
   one shared 24-hour reveal window.
3. Each player reveals a roll from 1 through 6 with the committed salt, strictly
   before the deadline. The second valid reveal immediately settles: higher roll
   receives both stakes, or equal rolls return one stake to each player.
4. At or after the deadline, if exactly one player revealed, anyone may call
   `settle(id)` to pay both stakes to that player, regardless of the roll. The
   caller receives no fee. If neither revealed, either player may call
   `cancel(id)` to refund both. There is no automatic transaction scheduler.
5. Until joined, the opener may cancel at any time and recover their stake.
   Unmatched games do not expire. Once joined, neither player can cancel early.
   Join/cancel races follow transaction ordering: the second transaction fails.

Each game escrows only its own stakes. No fees, owners, privileged beneficiaries,
admin recovery, upgrades, mint backdoors or initialization calls exist. Only the
immutable token is called externally. All mutating game entry points have a
reentrancy guard, and state changes precede transfers. Reverting/false token
transfers roll back the entire operation, including earlier payouts and reveals;
retry is possible if the token recovers and the action is still timely. With the
required ROLL token, there are no token hooks, pause switches, taxes or rebases.

The contract accepts no normal ETH transfers. Direct ROLL donations (and forced
ETH) have no recovery function. Never send tokens directly to the game. Deployment
with any token other than the supplied HighRollToken is unsupported: a code-size
check in the constructor is not an authenticity or transfer-behavior check.

## Secrets and gameplay limitations

Compute `keccak256(abi.encode(uint8(roll), bytes32(salt)))`, not packed encoding.
Use a fresh, cryptographically random 32-byte secret salt for each player and game.
Keep the roll and salt locally until a join is confirmed; preserve a reliable
backup. Weak salts can be brute-forced over only six rolls. Commitments intentionally
follow the approved roll/salt format and are not bound to player, chain, contract
or game ID, so never reuse salts/commitments across games or deployments. Identical
commitments within one game are rejected to prevent direct copying by the joiner;
this does not provide general cross-game replay protection.

A hash cannot prove a roll is valid at commitment time. An invalid commitment or
lost secret prevents a valid reveal, leading to forfeit if the other player
reveals, or refunds if neither does. A losing player can withhold a reveal and
delay payment for the rest of the window. Anyone can join an open game, including
a different account controlled by the opener; there is no identity check. Do not
reveal an unmatched game's secret in public or expose it to a third-party service.

Block timestamps determine the deadline. Congestion, transaction ordering and
validator timestamp influence can affect transactions near that boundary. Reveal
well in advance; a submitted transaction counts only when included successfully.
There is no keeper incentive, adjudicator or emergency withdrawal.

## Deployment handoff and responsibilities

| Artifact | Contract identifier | Constructor arguments |
| --- | --- | --- |
| `src/HighRollToken.sol` | `HighRollToken` | none |
| `src/HighRoll.sol` | `HighRoll` | one address: `$token` |

Use Sepolia, chain ID **11155111**, and the network's admitted ProjectFactory.
Deploy the token first. It has name **High Roll**, symbol **ROLL**, 18 decimals,
and immutable total supply **1,000,000,000 ROLL = 10^27 minor units** minted entirely
to its constructor caller (the factory). The game constructor takes only the
already-deployed token address, is nonpayable and neither moves supply nor assigns
a role to `msg.sender`. No constructor needs `$owner` and there is no post-deploy
initialization. The source identifiers are unique, under 32 ASCII characters,
and do not use the reserved MerkleDistributor name.

The separate manifest contributor must describe these accepted artifacts in
`launch.json` as `evm_project`, with HighRoll's token reference and dependency
ordering. It also records the approved pool settings: native ETH/zero address,
fee 3000, tick spacing 60, initial sqrtPriceX96
`79228162514264337593543950336`, no hook. The factory seeds launch-token-only
liquidity; those settings are not a promised token valuation. This source
contribution does not generate launch.json.

Services own policy, signed-artifact linkage, GitHub source publication,
attestation, admission and deployment. The policy-selected factory address,
resulting addresses, deployment block and admitted manifest remain service outputs;
there is no hard-coded wallet. No contributor transaction or wallet key is needed.
An independent contributor must adversarially review source **and the actual
manifest arguments** before release; these local checks are not that review.

The later frontend contributor uses React, Vite, TypeScript, RainbowKit, wagmi and
viem under `web/`, produces a relative-base static `dist/`, and loads the service's
`dist/imd-deployment.json` and embedded ABIs at runtime. It must manage secrets,
show the rules above, track event history and on-chain state, handle approvals and
failed transactions, and expose forfeit settlement and timeout refunds. Services
publish it to IPFS following a second independent review of the finished site.
Neither later service outputs nor website delivery are prerequisites of this
contract assignment.

## Validation coverage

Tests cover both winning players, ties and reveal order (fuzzed), conserved supply
and escrow, both forfeits, both no-reveal refund callers, unmatched cancellation,
join/reveal deadline boundaries, duplicate and invalid actions, authorization and
allowance failures, invalid committed rolls, concurrent game isolation, and events.
Adversarial-token tests attempt every mutating entry point during deposits and
payouts, and check complete rollback/retry after failed deposits, failed second
refunds, failed second tie payouts and reverting forfeit payouts. A factory-style
CREATE2 test checks constructor supply preservation, runtime limits and forbidden
opcodes. Supplied protected suites are deployment baselines requiring the service's
IMD_* inputs; local tests do not claim to replace their admission run.

Foundry's timestamp lint refers to the intentional deadline comparisons. Its
reentrancy lint flags token calls because the guard resets after the function
body; the guard is set before every such call, as the callback tests exercise.
