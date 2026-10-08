# Local adversarial review

This file records the local implementation review, not an independent security audit. A separate independent contributor should review the contracts and deployment configuration before release with user funds. No chain deployment, wallet operation, fork test, Slither run, or Mythril run was performed.

## Recorded local validation

On 2026-10-08, using Foundry 1.8.3 and the pinned compiler configuration:

| Check | Result |
| --- | --- |
| `forge build --sizes` | Passed; BaskVault runtime 23,736 bytes |
| `forge test` | 78 tests passed, 0 failed; includes two fuzz tests with 256 cases each |
| `forge fmt --check` | Passed |
| Deployed-runtime escape-opcode scan | Passed |
| 250 unreadable assets, default settings | 26,567,535 gas |
| 350 unreadable assets, minimum balance allowance | 26,673,706 gas |
| 250 assets, 52,000 balance allowance, maximum accounting quantities and fees | 27,157,139 gas |
| 50 assets, 500,000 balance allowance, maximum accounting quantities and fees | 27,897,638 gas |
| 26 direct failures, 500,000 balance/payment allowances | 27,331,244 gas |
| 350 listed / 47 held, 20,000 balance / 500,000 payment allowance, maximum quantities, fees, full minima array | 26,985,824 gas |
| 254 listed / 45 held, 50,000 balance / 500,000 payment allowance, maximum quantities, fees, full minima array | 27,149,129 gas |

Gas figures include the measured call and its calling-harness overhead; they exclude construction/setup and transaction intrinsic gas. The runtime is below the 24,000-byte threshold, so all requested views remain on BaskVault.

## Tested attacks

- **Withdrawal denial by tokens:** paused transfers, blocked recipients, reverted reads/transfers, absent/short/malformed return values, false return after changing balances, extra sender deductions, gas exhaustion, large return payloads, and expensive upgraded balance/transfer logic. Direct-payment failures revert the entire self-call and create a claim. Tokens with unreadable balances use accounting quantities for entitlement. No price/pause read participates in redemption.
- **Withdrawal denial by roles/settings:** deposit pause, asset close, retirement, stale or failing feeds, changed owner/guardian, fee destination, low payment and balance gas allowances, high allowances, maximum asset count, and maximum direct limit. Claims use unrestricted calls to avoid making their success depend on administrative call allowances.
- **Reentrancy:** token callbacks attempt a share mutation during deposit, direct redemption, and claim. The common guard rejects them. The external payment helper is self-only. No role entry point bypasses the guard.
- **Accounting:** donations do not affect managed NAV until delayed resync; total claims are excluded from redemption availability; a balance below claims gives zero availability; partial claims reduce both counters together. Taxed deposits revert. Failed transfers do not leave token-side changes committed. Fuzzed deposit/redeem sequences check quantity and share conservation.
- **Governance:** ownership acceptance checks current guardian identity; replacement guardians cannot equal the current owner even if ownership changed while waiting; a guardian cannot cancel its own replacement. Later closes invalidate old reopen proposals. Retirement invalidates pending asset actions and permits only subsequent resync proposals. Cap reductions invalidate raises. Settings and listing dependencies are revalidated at execution. Proposal expiry and exact time boundaries are tested.
- **Price inputs:** stale, future, nonpositive, unavailable and malformed feed reads; band endpoints; optional pause detection; idle-asset freshness; UTC schedule endpoints/weekends; pool quote scaling, negative fractional ticks, wrapped cumulatives, harmonic liquidity, quote-feed staleness, deviation boundaries, and observe failure. Production constructors make no calls to these dependencies.

## Gas bounds

`test/RedemptionGas.t.sol` constructs actual funded vaults, then corrupts the mocked external tokens/feeds. All vault and token accounts/storage are made cold before measuring a real call with 28,000,000 gas. There is no test-only accounting mutation in these scenarios. The full test transaction includes construction of up to 350 assets and is much larger than a production redemption; only the separately bounded redemption call is the acceptance measurement.

Scenarios include 250 entirely unreadable assets at defaults, 350 unreadable assets with minimum `balanceGas`, 254 direct failures at minimum call allowances, 26 direct failures with 500,000-gas allowances, 50 unreadable assets with maximum balance allowance, paused/blocked baskets, and returndata bombs. The 50-asset and 250-asset exact-bound scenarios also enable fees and set managed quantities to `uint256.max` through real resync proposals, exercising the full-width multiplication path. Results are printed by `forge test --match-contract RedemptionGasTest -vv`.

The exact-bound 50-asset test exposed excessive overhead in the first implementation. Scratch-space balance reads, an initialized reentrancy guard, and the aggregate redemption event keep that configuration within the budget without changing any eligibility, accounting, payment, or governance check. Gas assertions also reject an anomalous near-zero measurement observed during the original boundary test.

The gas inequalities bound the configurable external-call work plus accounting overhead. Redemption never iterates proposals, oracle data, or claimants. Its asset loops are bounded by the configured asset count. Token returndata copying is fixed at 32 bytes for balance/transfer results and zero bytes for self-call failures. A malicious asset cannot force unbounded memory expansion in the caller by returning a large blob.

The revision reproduced both mixed idle/held failures in the reviewer's unchanged proof: the original redemption exhausted its 28-million allowance. The fix preserves both settings inequalities and caches the count and bitmap of nonzero managed holdings. Redemption skips cold token/accounting reads for idle slots and avoids the separate counting pass, while preserving minima checks for idle slots. Every managed zero crossing updates this internal cache; removal relocates a held last asset's bit with the existing swap-and-pop order. `HeldAccounting.t.sol` tests deposit, resync, partial/full loss, retirement, removal and relisting, including movement across bitmap slots 255/256. The unchanged proof passes at 27,055,311 and 26,869,697 gas; the permanent mixed-asset regressions additionally exercise maximum accounting values, fees and full minima arrays as recorded above.

`DepositDebt.t.sol` reproduces and fixes the advisory deposit denial after a full managed loss leaves uncovered claims. Shortfall uses nonnegative availability; only input tokens additionally require their balance to cover all claims. The tests confirm that unrelated deposits/previews succeed, depositing the indebted asset still fails, and unreadable idle assets still block deposits.

The measurements use Solidity 0.8.26 with the pinned Cancun settings and cold EVM access costs. They are regression evidence for these paths, not a guarantee against a future chain gas-schedule change. Large baskets or expensive oracles can make deposits/views costly; the 28-million requirement applies to redemption.

`MathAndDeployment.t.sol` scans the actual deployed runtime using the protected check's opcode rules and checks the stricter 24,000-byte size bound. The standard ERC-20 Transfer event topic is a private immutable so the compiler emits it in PUSH data; an ordinary pooled constant table was mistaken for opcodes by that linear scanner. This changes no event signature or constructor parameter, and the event topics are tested explicitly.

## Agreed trust and economic assumptions

The following are accepted by the assignment and are intentionally left unchanged:

1. Feed lag within `poolDeviation` can be profitable to a depositor.
2. The owner must pair each Stock Token with its genuine feed, pool and quote feed. Interface checks cannot establish economic identity.
3. There is no allocation or concentration limit per asset.
4. Moving a thin pool can prevent deposits.
5. Depositors after an asset's retirement share its remaining tokens, although those tokens have zero NAV for deposit pricing.

The owner can prevent deposits through prices, hours, caps or closing assets, and can retire assets after the delay. The guardian can stop deposits and veto most proposals. Neither role has a withdrawal pause, confiscation, rescue/sweep, arbitrary call, configurable fee rate, mint function outside deposit, or upgrade capability. Fee changes mean changes of recipient only; the fixed fee is 50 basis points per deposit/redemption when enabled.

Stock Token issuers and the chain can impose restrictions outside the vault. A claim records an entitlement; it cannot overcome a permanent upstream block, invalid token code, confiscation, or chain censorship. Unknown actual launch dependencies remain owner-configured at genesis. Share supply and live asset state must be checked by the deployment reviewer and monitored by the owner/operator.

Four further advisory behaviors were reproduced and left unchanged under the specified interface and accounting rules: dead-share dust can prevent retired-asset removal; a redemption to the vault creates unclaimable debt; permissionless asset removal can change positional minima before execution; and unaccounted balance increases can dilute existing holders before delayed Resync. README.md now describes each limitation and the operational implications. `.imd-responses.json` records the finding-specific reproductions and disputes; these are documented limitations, not claims that the behaviors are harmless.

## Interface interpretations

- No pool is represented by an all-zero pool tuple; fee-recipient zero means the initial inactive state. These are explicit optional states, not invented outside contract addresses.
- Trading hours use a single weekday interval, start inclusive and end exclusive; `(0, 0)` means always open, including weekends.
- Shortfall needs a readable balance. Unreadability is not evidence of a loss, so flag/recognize revert without deleting an existing record.
- Claim failures preserve debt. Callers may retry to another destination or claim tokens separately, using sufficient gas for expensive tokens.
- Exact outgoing checks measure the vault's debit. An ERC-20 implementation that taxes the receiver while debiting exactly the leg is not detected by that specified check.
- External dependencies are untrusted for liveness and return sizes. Arbitrary upgraded code can still lie about balances; the vault cannot infer assets from a dishonest token's reported state.
