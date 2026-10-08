# Basket adversarial tests

Run `forge build` and `forge test`. The suite uses local Stock Token, feed, and
Uniswap v3 observation mocks. It requires no network, forks, environment variables,
or additional dependencies. Production source and configuration are unchanged.

`BasketInvariant.t.sol` runs 256 sequences of 64 handler calls with unexpected
reverts treated as failures. Four actors hold and transfer shares, including the
fee recipient. Three Stock Tokens have 18, 6, and 0 decimals. Operations include
deposits, partial and full redemptions, redirected claims, donations, resync,
external burns, deficit flags, loss recognition, token failures, deposit pauses,
fee recipient changes, and payment settings. Every sequence ends by attempting
full redemption for every actor and claims after token recovery.

The properties follow the assignment's accounting rules:

- Total supply equals all holders' balances, and cumulative minting less burning.
  The initial 1e15 locked shares remain locked.
- Total owed equals the sum of individual claims. Every redeemed leg has either
  been paid or remains owed.
- Managed balances change only through deposits, redemptions, resync, and explicit
  loss recognition. External token burns never silently lower managed balances.
- Actual custody plus payouts and external burns equals deposits plus donations.
  A mock-only observation getter allows this check even when ERC-20 reads fail.
- Deposit and redeem rounding satisfy independent integer inequalities; fees and
  receivers' balances are checked separately. Payment failures are atomic.

The accounting campaign uses fixed $1 prices and does not retire its three assets.
Deposits restore external dependency health to allow continued exploration, but
still exercise rejection during a vault pause or deficit. Other actions preserve
token failure states. Failed claims and deficits can coexist: solvency is not
incorrectly asserted after deliberate external burns. Full gas exhaustion is
tested in the gas suite rather than in the claim handler, because claims explicitly
forward uncapped gas. A deterministic handler sequence verifies that deferred
claims, losses, and recovery are reachable.

The handler distinguishes a managed shortfall from uncovered claims on a fully
written-down asset. Those claims block deposits of that asset, but do not block
deposits of other assets. A pinned regression and 1,000 fuzz cases exercise this
distinction across all three decimal formats, then cover the debt exactly, verify
resync adds no managed surplus, deposit again, and pay the preserved claim.

`AdversarialFlows.t.sol` adds batch rollback, claim ownership and duplicate claims,
token code removal/recovery, resync excluding debt, zero NAV, retirement, empty and
invalid inputs, allowance rollback, and exact minimum-share boundaries. Two fuzz
properties each run 1,000 cases: mixed-decimal initial valuation and repeated
deposit/redeem/claim cycles with fees, donations, resync, and deferred payments.

`RedemptionGas.t.sol` additionally redeems 250 retired assets whose balance reads
consume the entire allowance. It checks the cold redemption call succeeds within
28,000,000 gas and credits every asset's claim. Existing cases cover other legal
gas-setting extremes and paused, blocked, and malformed dependencies.

These tests complement the existing oracle, governance, loss, deployment, and gas
tests. They do not establish the identity or behavior of live Robinhood Chain
dependencies; live integration is outside this offline assignment.
