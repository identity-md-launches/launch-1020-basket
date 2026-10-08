# Basket Protocol

An immutable index vault for **Stock Tokens** on Robinhood Chain, chain id **4663**. `BaskVault` is both the custodian and the **Basket (BASK)** ERC-20 share, with 18 decimals. Supply starts at zero, has no configured cap, increases only through deposits, and decreases through redemption burns.

## Build and checks

```sh
forge build
forge test
forge fmt --check
```

`foundry.toml` pins Solidity 0.8.26, optimizer with 200 runs, IR compilation, Cancun, and no bytecode metadata hash. All imports are ordinary vendored source files. Builds and tests require no network, RPC, environment variables, filesystem cheatcodes, or FFI. The compiler itself is supplied by the Foundry environment.

The test suite covers accounting, decimal normalization, fee rounding, first-deposit locking, token transfer failures, claims, reentrancy, loss recognition, every governance action, price freshness and pool observations, and cold-storage redemption gas at the permitted settings boundaries. Gas tests explicitly give the redemption call 28,000,000 gas; fixture construction is outside that measurement. See [SECURITY.md](SECURITY.md) for the attack review and its limits.

## Deployment parameters

`launch.json` contains one application and these literal constructor arguments:

| Parameter | Value |
| --- | --- |
| Contract | `BaskVault` |
| `owner_` | `0x30B57ECf51D19ABcED7F6f70974e6fBb6f3b9Da3` |
| `guardian_` | `0x5ed39AF86f2C00ad99913B5d727bD68f2A904B68` |
| Chain id | `4663` |

The constructor rejects zero or equal role addresses, uses explicit arguments rather than the deployer's identity, and calls no other contract. There is no deployment transaction or signing script in this project. All views currently fit in the vault below the brief's 24,000-byte runtime threshold, so no `BaskLens` is required.

## After launch

The initial asset list is empty, genesis is unfinished, the fee recipient is unset, and deposits cannot run. No asset, feed, pool, quote-feed, or beneficiary address is guessed in the implementation.

1. The owner obtains the actual Stock Token and USD feed addresses for chain 4663 from their issuers/operators. Verify the feed answers in USD per **whole raw token**, including decimal units. Feed/token correctness is an explicit owner responsibility.
2. The owner calls `genesisList(token, feed, pool, quoteFeed, minLiquidity)` for at least three assets. A pool is configured in that same call. For an explicitly pool-free asset, use `(pool, quoteFeed, minLiquidity) = (address(0), address(0), 0)`; this is the specified absence of a pool, not a placeholder deployment dependency.
3. For a configured pool, verify its genuine Uniswap v3 observation interface, sorted token addresses, actual quote token, and the quote token's USD feed. Choose `minLiquidity` in the pool's raw harmonic-mean liquidity units. Supply live observations spanning `poolWindow`. The vault stores the token and feed decimals when configured; each must be at most 18, including quote dependencies.
4. The owner calls `finalizeGenesis()` once. Three listed assets are required. Deposits can then run when their checks pass. There is no minimum holding allocation for any asset.
5. If fees are desired, the owner proposes `FeeRecipient` with the intended actual beneficiary, waits two days, and executes. Fees are absent until this executes. The beneficiary cannot be zero or the vault. Once configured, there is no action to unset it; subsequent changes use the same timelock. The fee rate cannot change.
6. Monitor token/feed upgrades, pause capability, balances versus accounting and claims, observation availability, price ages, governance proposals, and gas costs. Close an affected asset or pause deposits as appropriate. Token/feed/pool changes after genesis use proposals. No listed asset configuration is needed to redeem shares or retry claims already recorded.

Neither this repository nor the vault verifies legal entitlements or the economic identity of an issuer's instrument. BASK represents the vault's raw Stock Token holdings. Chain execution and token issuer restrictions remain external dependencies.

## Accounting and user calls

`managed[token]` is the accounting quantity. NAV uses only managed quantities for unretired assets, never raw balances or pending claims. Direct donations change neither NAV nor shares until an owner `Resync` proposal executes. Resync only adds positive excess over managed quantities and total claims.

`deposit(tokens, amounts, receiver, minSharesOut, deadline)`:

- Uses matching, nonempty arrays of positive amounts with each open, listed token appearing once. The receiver cannot be zero or the vault. The deadline is inclusive.
- Requires finalized genesis, unpaused deposits, and the configured trading hours. Every unretired asset must have a readable balance and enough assets to cover managed quantities plus claims, even when managed is zero. Retired assets are skipped entirely.
- Validates prices for every input and every unretired nonzero holding. Closed holdings still count in NAV and its price checks. `freshCount` counts unretired assets with a positive, readable feed answer updated within `freshHours`; closed and zero-held assets can count.
- Requires each token pull to increase the vault balance by exactly the amount. A false/malformed return or nonexact increase reverts the whole deposit; empty return data is supported.
- Values amounts as `floor(amount * answer * 1e18 / 10^(tokenDecimals + feedDecimals))`. Gross shares equal deposit value at zero supply, otherwise `floor(value * supply / NAV)`; positive supply with zero NAV cannot accept a deposit.
- Mints `ceil(gross / 200)` shares to a configured fee recipient and the remainder to the receiver. On the first deposit, exactly `1e15` of that remainder instead goes to `address(0xdEaD)`, as specified by the brief. Receiver shares must be positive and meet the requested minimum. NAV after deposit must not exceed `NAV_CAP`.

`redeem(shares, receiver, minAmountsOut, deadline)` takes the caller's shares. It requires a positive share amount, sufficient shares, a nonzero receiver, and an unexpired inclusive deadline. It reads no oracle and ignores all deposit controls and retirement status. A configured fee of `ceil(shares / 200)` is transferred in BASK to the recipient; only the remainder burns. A one-wei redemption with fees enabled can therefore burn zero net shares.

For each asset, the entitlement is `floor(min(managed, available) * netShares / supplyBeforeBurn)`. Available is the nonnegative balance less total claims; an unreadable bounded balance call uses managed as the fallback. Managed is reduced only by the entitlement. Missing minimum entries mean zero. **Minimum arrays and returned amounts follow `assetTokens` order**, which changes by swap-and-pop when an asset is removed; fetch that order when preparing a redemption.

At most `directLimit` nonzero holdings enables direct payment attempts, each with `payGas`. Otherwise all legs become claims. Each payment runs through a self-only external function so a failed balance check, malformed/false return, revert, or gas exhaustion rolls back that token's transfer. The measured vault balance must fall by exactly the leg. Failure records `owed[receiver][token]` and `totalOwed[token]`; it does not block the redemption. Minimum outputs constrain entitlements, not whether they are paid immediately. Recipient-side transfer taxes are not separately measured; sender-side extra deductions fail the exact-debit check.

`claim(tokens, to)` acts on the caller's claims and permits any nonzero destination. For each token, it attempts the smaller of the claim and the current vault balance. Claims are reserved ahead of managed assets. A successful exact-debit payment reduces both claim counters; a failed payment preserves them and processing continues when gas remains. Claim reads and payment attempts have no vault-imposed gas limit, so a user can retry an expensive upgraded token with enough transaction gas and can isolate a troublesome token in its own call. Pause settings, roles, and retirement do not control claims. No contract can make a permanently blocked token transfer succeed.

The ERC-20 share exposes standard `approve`, `transfer`, and `transferFrom`. Infinite allowance is supported. Every public user mutation is guarded against reentrancy and emits events. The self-only `pay` helper runs within the calling redemption/claim guard and cannot be invoked by a user or token.

## Prices

The positive primary answer must be current, not future-dated, and within the inclusive `[centre / band, centre * band]` interval. The lower endpoint uses integer division. Its call has `feedGas`. If `oraclePaused()` returned a valid bool at listing, every deposit price check requires that method to read as false within `pauseGas`. Missing or malformed pause reads after detection fail that price check. An absent/malformed method at listing leaves `hasPause` false.

An asset without a pool also needs the tighter `noPoolAge`. With a pool, a `poolGas`-bounded `observe([poolWindow, 0])` must succeed. Mean tick rounds toward negative infinity, cumulative differences wrap at their interface widths, and harmonic mean liquidity follows [Uniswap OracleLibrary.consult](https://github.com/Uniswap/v3-periphery/blob/v1.3.0/contracts/libraries/OracleLibrary.sol). The mean-tick quote is normalized into whole quote tokens with 18 decimal places before multiplying by the positive, current quote-feed answer. Fractional quote tokens are preserved even for low-decimal quote assets. Pool USD price must differ from primary USD price by at most `poolDeviation` basis points of the primary price, inclusively. Fixed return buffers avoid copying arbitrary returndata.

## Roles and proposals

The owner can immediately list during genesis, finalize genesis, close assets, pause/unpause deposits, and lower `NAV_CAP`. Lowering the cap invalidates all pending cap raises. Owner transfer is two-step (`transferOwnership`, `acceptOwnership`), cannot target zero or the current guardian, and has no renounce operation. Acceptance rechecks that the pending owner has not since become guardian.

The guardian can pause deposits, close assets, and cancel proposals except its own replacement. The owner can cancel any proposal. A later close invalidates every earlier reopen proposal for that asset, even if it was already closed.

`propose(action, token, data)` is owner-only and returns a monotonically increasing id. `execute(id)` is owner-only from `readyAt = proposedAt + 2 days` through `readyAt + 7 days`, inclusive. Proposals are checked again when executed. Configuration and bounds can change while a proposal waits, making its execution fail. There is no execution by third parties.

Use ABI encoding for payloads:

| `T.Action` (ordinal) | `token` | `data = abi.encode(...)` |
| --- | --- | --- |
| List (0) | new asset | `address feed, address pool, address quoteFeed, uint128 minLiquidity` |
| Feed (1) | asset | `address newFeed` |
| Centre (2) | asset | empty bytes |
| Reopen (3) | asset | empty bytes |
| Retire (4) | asset | empty bytes |
| Pool (5) | asset | `address pool, address quoteFeed, uint128 minLiquidity` |
| Resync (6) | asset | empty bytes |
| Guardian (7) | zero (global action) | `address newGuardian` |
| NavCap (8) | zero (global action) | `uint256 cap` |
| FeeRecipient (9) | zero (global action) | `address recipient` |
| Setting (10) | zero (global action) | `T.Setting key, uint256 value` |

Listing checks capacity, unlisted status, token/feed decimals, feed uniqueness among unretired assets, and a positive current answer at both proposal and execution. Feed changes also check uniqueness and take the new answer as centre. Centre proposals read their actual centre at execution and require a current positive answer then; a stale asset can have a centre proposal queued.

Retirement requires the asset closed at both proposal and execution. It is permanent, excludes the asset from all deposit checks and NAV, and invalidates every outstanding proposal associated with that asset, including older resyncs. Only new resync proposals are then accepted for it. Retired holdings and claims remain redeemable. Anyone can `removeRetired(token)` only after both managed and total owed are zero. A removed token can be listed afresh.

## Settings

`settings()` returns the full configuration. `Setting` ordinals follow the table; `Hours` changes the pair atomically with `(from << 32) | to`.

| Setting (ordinal) | Initial | Bounds / units |
| --- | --- | --- |
| Band (0) | 4 | 2–100 |
| MaxAge (1) | 80 hours | 1 hour–30 days, seconds |
| NoPoolAge (2) | 26 hours | 1 hour–30 days, seconds |
| FreshCount (3) | 0 | 0–10 |
| FreshHours (4) | 4 | 1–48, hours |
| Hours (5) | 0–0 | Always open when both zero; otherwise Mon–Fri UTC, `0 <= from < to <= 86400`, start inclusive/end exclusive |
| PoolWindow (6) | 1,800 | 300–86,400 seconds |
| PoolDeviation (7) | 300 | 50–2,000 basis points |
| FeedGas (8) | 100,000 | 20,000–500,000 |
| PauseGas (9) | 100,000 | 20,000–500,000 |
| PoolGas (10) | 150,000 | 20,000–500,000 |
| BalanceGas (11) | 50,000 | 20,000–500,000 |
| PayGas (12) | 250,000 | 20,000–500,000 |
| MaxAssets (13) | 250 | At least current asset count, subject to gas inequality |
| DirectLimit (14) | 50 | Subject to gas inequality; zero disables direct attempts |

Every setting proposal and execution preserves both inequalities:

```text
maxAssets * (balanceGas + 60,000) <= 28,000,000
directLimit * (balanceGas + payGas + 70,000) <= 28,000,000
```

Consequently the maximum possible asset count is 350 at a 20,000 balance allowance. There is no extra fixed 250-asset ceiling. A proposal changing a limit can fail if another setting changes first.

`NAV_CAP` initially equals `1_000_000e18` USD units and can never rise above `10_000_000_000e18`. Decreases are immediate, including below current NAV or to zero, and affect only future deposits.

## Losses and views

`flagDeficit(token)` is permissionless and requires a readable balance. If available is below managed, it records the shortfall and time only when the shortfall exceeds the recorded amount. An unchanged/smaller deficit does not restart the clock; a healthy balance clears the record. `recognizeLoss(token)` is permissionless at least seven days after the record, reduces managed by the smaller of recorded and current shortfall, and clears it. An unreadable balance cannot create, clear, or recognize a loss. Successful deposits clear unretired deficit records. No automatic loss write-down occurs during redemption.

Views: `allAssets()` returns each config, raw primary answer, update time, validated pool USD price, managed amount, short/readable flags, total owed, and price reason. A failed check can leave the pool price zero. `asset(token)`, `assetTokens(i)`, and `assetCount()` expose the configuration and order individually. `previewDeposit` performs deposit eligibility/valuation checks and returns receiver shares after fees and the initial lock; it does not simulate allowance or token transfers. `previewRedeem` returns proportional entitlements and fee without price reads or simulating transfer success. A deposit preview can revert with the same deposit errors.

`depositStatus(tokens)` returns `T.Reason` and the first asset at fault. Global failures use no asset address. It checks configuration, hours, duplicate/input-token eligibility, balance solvency, prices and freshness; amount, receiver, deadline, allowance, cap and slippage checks need the full deposit arguments. The enum is defined in `src/BaskTypes.sol`.

`proposal(id)` exposes the stored proposal, `proposalValid(id)` checks cancellation/expiry/version invalidation, and `pendingProposals(start, limit)` filters a bounded **range of ids** for pending proposals. Validity here does not promise current execution eligibility: the timelock and configuration checks still apply. `proposalCount()` is the last allocated id.

## Dependencies

`lib/forge-std/src` is vendored from forge-std **v1.9.7**, with its MIT/Apache licenses. Production math is adapted from Uniswap v3-core **v1.0.0**: `FullMath` retains MIT attribution; `TickMath` and the observation/quote formulas use GPL-2.0-or-later. Changes pin Solidity, use custom errors, mark safe assembly, preserve required unchecked modular arithmetic, and retain only the required tick-to-price routine. See [THIRD_PARTY.md](THIRD_PARTY.md) and `src/libraries/UNISWAP-LICENSE`.
