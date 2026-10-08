// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BaskVault} from "src/BaskVault.sol";
import {BaskTypes as T} from "src/BaskTypes.sol";
import {MockToken, MockFeed} from "./Mocks.sol";

/// @dev Observation for the harness only: an upgraded ERC-20 balanceOf may be unreadable.
contract ObservedStockToken is MockToken {
    constructor(uint8 d) MockToken(d) {}

    function actualBalance(address who) external view returns (uint256) {
        return balances[who];
    }
}

contract BasketHandler is Test {
    struct DepositState {
        uint256 nav;
        uint256 supply;
        uint256 receiverShares;
        uint256 feeShares;
        uint256 payerTokens;
        address feeRecipient;
    }

    BaskVault public immutable vault;
    ObservedStockToken[3] public stocks;
    MockFeed[3] public feeds;
    address[4] public actors;
    uint256[3] public deposited;
    uint256[3] public donated;
    uint256[3] public destroyed;
    uint256[3] public paid;
    uint256[3] public redeemed;
    uint256[3] public resynced;
    uint256[3] public losses;
    uint256 public mintedShares;
    uint256 public burnedShares;
    uint256 public depositCalls;
    uint256 public redeemCalls;
    uint256 public claimCalls;
    uint256 public lossCalls;

    constructor(BaskVault v, ObservedStockToken[3] memory ts, MockFeed[3] memory fs) {
        vault = v;
        stocks = ts;
        feeds = fs;
        for (uint256 i; i < 4; ++i) {
            actors[i] = makeAddr(string.concat("invariant actor ", vm.toString(i)));
            for (uint256 j; j < 3; ++j) {
                ts[j].mint(actors[i], 100_000 * 10 ** ts[j].decimals());
                vm.prank(actors[i]);
                ts[j].approve(address(v), type(uint256).max);
            }
        }
    }

    function _one(address token) private pure returns (address[] memory a) {
        a = new address[](1);
        a[0] = token;
    }

    function _execute(T.Action action, address token, bytes memory data) private {
        address owner = vault.owner();
        vm.prank(owner);
        uint256 id = vault.propose(action, token, data);
        vm.warp(block.timestamp + 2 days);
        vm.prank(owner);
        vault.execute(id);
    }

    // Deposit drives healthy external dependencies; failures persist between all other actions.
    // All prices are $1, so NAV can be calculated independently of the production oracle library.
    function deposit(uint256 actorSeed, uint256 tokenSeed, uint256 raw, uint256 receiverSeed) public {
        uint256 ix = tokenSeed % 3;
        address payer = actors[actorSeed % 4];
        address receiver = actors[receiverSeed % 4];
        uint256 unit = 10 ** stocks[ix].decimals();
        uint256 amount = bound(raw, unit, 100 * unit);
        if (stocks[ix].actualBalance(payer) < amount) return;
        DepositState memory before;
        address shortToken;
        for (uint256 j; j < 3; ++j) {
            stocks[j].setModes(0, 0);
            stocks[j].setPaused(false);
            stocks[j].setOraclePaused(false);
            feeds[j].setMode(0);
            feeds[j].set(1e8, block.timestamp);
            address token = address(stocks[j]);
            before.nav += vault.managed(token) * (1e18 / 10 ** stocks[j].decimals());
            if (
                shortToken == address(0)
                    && stocks[j].actualBalance(address(vault)) < vault.managed(token) + vault.totalOwed(token)
            ) {
                shortToken = token;
            }
        }
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        before.supply = vault.totalSupply();
        bytes memory rejection;
        if (vault.depositsPaused()) {
            rejection = abi.encodeWithSelector(BaskVault.DepositUnavailable.selector, T.Reason.Paused, address(0));
        } else if (shortToken != address(0)) {
            rejection = abi.encodeWithSelector(BaskVault.DepositUnavailable.selector, T.Reason.Deficit, shortToken);
        } else if (before.supply != 0 && before.nav == 0) {
            rejection = abi.encodeWithSelector(BaskVault.ZeroNAV.selector);
        }
        if (rejection.length != 0) {
            vm.prank(payer);
            vm.expectRevert(rejection);
            vault.deposit(_one(address(stocks[ix])), amounts, receiver, 0, block.timestamp);
            return;
        }
        before.receiverShares = vault.balanceOf(receiver);
        before.feeRecipient = vault.feeRecipient();
        before.feeShares = vault.balanceOf(before.feeRecipient);
        before.payerTokens = stocks[ix].actualBalance(payer);
        vm.prank(payer);
        uint256 shares = vault.deposit(_one(address(stocks[ix])), amounts, receiver, 0, block.timestamp);
        uint256 gross = vault.totalSupply() - before.supply;
        uint256 value = amount * (1e18 / unit);
        if (before.supply == 0) {
            assertEq(gross, value, "initial shares equal deposited dollars");
        } else {
            assertLe(gross * before.nav, value * before.supply, "deposit must round down");
            assertGt((gross + 1) * before.nav, value * before.supply, "deposit loses at most one share wei");
        }
        uint256 fee = before.feeRecipient == address(0) ? 0 : (gross * 50 + 9999) / 10000;
        assertEq(shares + fee + (before.supply == 0 ? 1e15 : 0), gross);
        assertEq(
            vault.balanceOf(receiver), before.receiverShares + shares + (receiver == before.feeRecipient ? fee : 0)
        );
        if (before.feeRecipient != address(0)) {
            assertEq(
                vault.balanceOf(before.feeRecipient),
                before.feeShares + fee + (receiver == before.feeRecipient ? shares : 0)
            );
        }
        assertEq(stocks[ix].actualBalance(payer), before.payerTokens - amount);
        deposited[ix] += amount;
        mintedShares += gross;
        ++depositCalls;
    }

    function redeem(uint256 actorSeed, uint256 raw, uint256 receiverSeed, bool full) public {
        address actor = actors[actorSeed % 4];
        address receiver = actors[receiverSeed % 4];
        uint256 sharesBefore = vault.balanceOf(actor);
        if (sharesBefore == 0) return;
        uint256 shares = full ? sharesBefore : bound(raw, 1, sharesBefore);
        uint256 supply = vault.totalSupply();
        address feeRecipient = vault.feeRecipient();
        uint256 feeBefore = vault.balanceOf(feeRecipient);
        uint256 fee = feeRecipient == address(0) ? 0 : (shares * 50 + 9999) / 10000;
        uint256 net = shares - fee;
        uint256[3] memory custody;
        uint256[3] memory m;
        uint256[3] memory debt;
        uint256[3] memory base;
        for (uint256 i; i < 3; ++i) {
            address token = address(stocks[i]);
            custody[i] = stocks[i].actualBalance(address(vault));
            m[i] = vault.managed(token);
            debt[i] = vault.owed(receiver, token);
            uint256 totalDebt = vault.totalOwed(token);
            uint256 available =
                stocks[i].balanceMode() != 0 ? m[i] : custody[i] > totalDebt ? custody[i] - totalDebt : 0;
            base[i] = available < m[i] ? available : m[i];
        }
        // No try/catch: arbitrary dependency/role states must never stop a valid redemption.
        vm.prank(actor);
        uint256[] memory legs = vault.redeem(shares, receiver, new uint256[](0), block.timestamp);
        assertEq(legs.length, 3);
        assertEq(vault.totalSupply(), supply - net);
        assertEq(vault.balanceOf(actor), sharesBefore - shares + (actor == feeRecipient ? fee : 0));
        if (feeRecipient != address(0)) {
            assertEq(vault.balanceOf(feeRecipient), feeBefore + fee - (actor == feeRecipient ? shares : 0));
        }
        for (uint256 i; i < 3; ++i) {
            address token = address(stocks[i]);
            assertLe(legs[i] * supply, base[i] * net, "redeem must round down");
            assertGt((legs[i] + 1) * supply, base[i] * net, "redeem loses at most one token unit");
            uint256 sent = custody[i] - stocks[i].actualBalance(address(vault));
            assertTrue(sent == 0 || sent == legs[i], "payment must be atomic");
            assertEq(vault.managed(token), m[i] - legs[i]);
            assertEq(vault.owed(receiver, token), debt[i] + legs[i] - sent);
            redeemed[i] += legs[i];
            paid[i] += sent;
        }
        burnedShares += net;
        ++redeemCalls;
    }

    function claim(uint256 actorSeed, uint256 tokenSeed, uint256 receiverSeed) public {
        uint256 ix = tokenSeed % 3;
        address actor = actors[actorSeed % 4];
        address receiver = actors[receiverSeed % 4];
        address token = address(stocks[ix]);
        uint256 debt = vault.owed(actor, token);
        uint256 custody = stocks[ix].actualBalance(address(vault));
        uint256 beforeReceiver = stocks[ix].actualBalance(receiver);
        vm.prank(actor);
        vault.claim(_one(token), receiver);
        uint256 sent = stocks[ix].actualBalance(receiver) - beforeReceiver;
        assertEq(stocks[ix].actualBalance(address(vault)), custody - sent);
        assertEq(vault.owed(actor, token), debt - sent, "claim consumes only caller's paid debt");
        assertTrue(sent == 0 || sent == (debt < custody ? debt : custody));
        paid[ix] += sent;
        ++claimCalls;
    }

    function donate(uint256 tokenSeed, uint256 raw) public {
        uint256 ix = tokenSeed % 3;
        uint256 amount = bound(raw, 1, 1000 * 10 ** stocks[ix].decimals());
        stocks[ix].mint(address(vault), amount);
        donated[ix] += amount;
    }

    function slash(uint256 tokenSeed, uint256 raw) public {
        uint256 ix = tokenSeed % 3;
        uint256 balance = stocks[ix].actualBalance(address(vault));
        if (balance == 0) return;
        uint256 amount = bound(raw, 1, balance);
        stocks[ix].burn(address(vault), amount);
        destroyed[ix] += amount;
    }

    function resync(uint256 tokenSeed) public {
        uint256 ix = tokenSeed % 3;
        address token = address(stocks[ix]);
        stocks[ix].setModes(0, stocks[ix].transferMode());
        uint256 m = vault.managed(token);
        uint256 debt = vault.totalOwed(token);
        uint256 balance = stocks[ix].actualBalance(address(vault));
        _execute(T.Action.Resync, token, "");
        assertEq(vault.managed(token) + debt, balance > m + debt ? balance : m + debt);
        resynced[ix] += balance > m + debt ? balance - m - debt : 0;
    }

    function flag(uint256 tokenSeed) public {
        uint256 ix = tokenSeed % 3;
        stocks[ix].setModes(0, stocks[ix].transferMode());
        vault.flagDeficit(address(stocks[ix]));
    }

    function recognize(uint256 tokenSeed) public {
        uint256 ix = tokenSeed % 3;
        address token = address(stocks[ix]);
        (uint256 recorded, uint256 since) = vault.deficits(token);
        if (recorded == 0) return;
        if (block.timestamp < since + 7 days) vm.warp(since + 7 days);
        stocks[ix].setModes(0, stocks[ix].transferMode());
        uint256 balance = stocks[ix].actualBalance(address(vault));
        uint256 debt = vault.totalOwed(token);
        uint256 available = balance > debt ? balance - debt : 0;
        uint256 m = vault.managed(token);
        uint256 shortfall = m > available ? m - available : 0;
        uint256 loss = shortfall < recorded ? shortfall : recorded;
        vault.recognizeLoss(token);
        assertEq(vault.managed(token), m - loss);
        losses[ix] += loss;
        ++lossCalls;
    }

    function tokenState(uint256 tokenSeed, uint256 mode, bool paused) public {
        uint256 ix = tokenSeed % 3;
        // Reverting/short balance data and transfer faults; full gas exhaustion is covered by RedemptionGasTest.
        uint256[8] memory transfers = [uint256(0), 1, 3, 4, 5, 7, 8, 9];
        stocks[ix].setModes(mode % 3, transfers[(mode / 3) % 8]);
        // Mode 2 would burn every remaining unit of claim gas; use malformed data instead.
        if (mode % 3 == 2) stocks[ix].setModes(3, transfers[(mode / 3) % 8]);
        stocks[ix].setPaused(paused);
        stocks[ix].setOraclePaused(paused);
        feeds[ix].setMode(paused ? 1 : 0);
    }

    function governance(uint256 raw) public {
        uint256 choice = raw % 8;
        if (choice < 2) {
            address role = choice == 0 ? vault.guardian() : vault.owner();
            vm.prank(role);
            if (choice == 0) vault.pauseDeposits();
            else vault.unpauseDeposits();
        } else if (choice < 5) {
            _execute(T.Action.Setting, address(0), abi.encode(T.Setting.DirectLimit, choice == 2 ? 0 : choice - 2));
        } else if (choice < 7) {
            if (choice == 6 && vault.settings().directLimit > 45) {
                _execute(T.Action.Setting, address(0), abi.encode(T.Setting.DirectLimit, uint256(3)));
            }
            _execute(T.Action.Setting, address(0), abi.encode(T.Setting.PayGas, choice == 5 ? 20_000 : 500_000));
        } else {
            _execute(T.Action.FeeRecipient, address(0), abi.encode(actors[(raw / 8) % 4]));
        }
    }

    function transferShares(uint256 actorSeed, uint256 receiverSeed, uint256 raw, bool viaAllowance) public {
        address actor = actors[actorSeed % 4];
        address receiver = actors[receiverSeed % 4];
        uint256 senderBefore = vault.balanceOf(actor);
        uint256 receiverBefore = vault.balanceOf(receiver);
        uint256 amount = bound(raw, 0, senderBefore);
        if (viaAllowance) {
            vm.prank(actor);
            vault.approve(address(this), amount);
            vault.transferFrom(actor, receiver, amount);
            assertEq(vault.allowance(actor, address(this)), 0);
        } else {
            vm.prank(actor);
            vault.transfer(receiver, amount);
        }
        assertEq(vault.balanceOf(actor), senderBefore - (actor == receiver ? 0 : amount));
        assertEq(vault.balanceOf(receiver), receiverBefore + (actor == receiver ? 0 : amount));
    }
}

/// @dev Prices remain $1; external burns and donations are tracked rather than assumed away.
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract BasketInvariantTest is Test {
    BaskVault private vault;
    BasketHandler private handler;
    ObservedStockToken[3] private stocks;

    function setUp() public {
        vm.warp(1_800_000_000);
        vm.chainId(4663);
        address owner = address(bytes20(hex"30B57ECf51D19ABcED7F6f70974e6fBb6f3b9Da3"));
        address guardian = address(bytes20(hex"5ed39AF86f2C00ad99913B5d727bD68f2A904B68"));
        vault = new BaskVault(owner, guardian);
        MockFeed[3] memory feeds;
        for (uint256 i; i < 3; ++i) {
            stocks[i] = new ObservedStockToken(i == 0 ? 18 : i == 1 ? 6 : 0);
            feeds[i] = new MockFeed(8, 1e8);
            vm.prank(owner);
            vault.genesisList(address(stocks[i]), address(feeds[i]), address(0), address(0), 0);
        }
        vm.prank(owner);
        vault.finalizeGenesis();
        handler = new BasketHandler(vault, stocks, feeds);
        for (uint256 i; i < 3; ++i) {
            handler.deposit(i, i, 10 * 10 ** stocks[i].decimals(), i);
        }
        handler.governance(31); // Enable fees to the fourth actor, who also transfers and redeems.
        bytes4[] memory selectors = new bytes4[](11);
        selectors[0] = handler.deposit.selector;
        selectors[1] = handler.redeem.selector;
        selectors[2] = handler.claim.selector;
        selectors[3] = handler.donate.selector;
        selectors[4] = handler.slash.selector;
        selectors[5] = handler.resync.selector;
        selectors[6] = handler.flag.selector;
        selectors[7] = handler.recognize.selector;
        selectors[8] = handler.tokenState.selector;
        selectors[9] = handler.governance.selector;
        selectors[10] = handler.transferShares.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_ShareSupplyAndPermanentLock() public view {
        uint256 sum = vault.balanceOf(address(0xdEaD));
        for (uint256 i; i < 4; ++i) {
            sum += vault.balanceOf(handler.actors(i));
        }
        assertEq(sum, vault.totalSupply(), "every share belongs to a tracked holder");
        assertEq(vault.totalSupply() + handler.burnedShares(), handler.mintedShares());
        assertEq(vault.balanceOf(address(0xdEaD)), 1e15);
        assertEq(vault.balanceOf(address(0)), 0);
    }

    function invariant_CustodyManagedAndClaimsConserveStockTokens() public view {
        for (uint256 i; i < 3; ++i) {
            address token = address(stocks[i]);
            uint256 sum;
            for (uint256 j; j < 4; ++j) {
                sum += vault.owed(handler.actors(j), token);
            }
            assertEq(sum, vault.totalOwed(token), "aggregate claim debt equals individual entitlements");
            assertEq(sum + handler.paid(i), handler.redeemed(i), "each redeemed leg is paid or still owed");
            assertEq(
                vault.managed(token) + handler.redeemed(i) + handler.losses(i),
                handler.deposited(i) + handler.resynced(i),
                "managed changes only on authorized accounting paths"
            );
            assertEq(
                stocks[i].actualBalance(address(vault)) + handler.paid(i) + handler.destroyed(i),
                handler.deposited(i) + handler.donated(i),
                "physical Stock Tokens are conserved"
            );
        }
    }

    function afterInvariant() public {
        // Attempt full redemption from every holder in the final adversarial state.
        for (uint256 i; i < 4; ++i) {
            handler.redeem(i, 0, i, true);
        }
        for (uint256 j; j < 3; ++j) {
            handler.tokenState(j, 0, false);
            for (uint256 i; i < 4; ++i) {
                handler.claim(i, j, i);
            }
        }
        invariant_ShareSupplyAndPermanentLock();
        invariant_CustodyManagedAndClaimsConserveStockTokens();
    }

    // A deterministic sequence proves loss, deferred-payment, and recovery branches are reachable.
    function test_HandlerExercisesClaimsLossesAndRecovery() public {
        handler.governance(2);
        handler.redeem(0, 1e18, 1, false);
        assertGt(vault.owed(handler.actors(1), address(stocks[0])), 0);
        handler.claim(1, 0, 2);
        handler.slash(0, 1e18);
        handler.flag(0);
        handler.recognize(0);
        assertEq(handler.lossCalls(), 1);
        handler.donate(0, 2e18);
        handler.resync(0);
        handler.governance(0);
        handler.deposit(0, 0, 1e18, 1); // Exact paused-deposit rejection.
        handler.tokenState(1, 1, true);
        handler.redeem(1, 1, 2, true);
        handler.governance(1);
        handler.deposit(2, 2, 2, 3);
        handler.transferShares(3, 0, 1, true);
        invariant_ShareSupplyAndPermanentLock();
        invariant_CustodyManagedAndClaimsConserveStockTokens();
        assertGt(handler.depositCalls(), 3);
        assertGt(handler.redeemCalls(), 1);
        assertGt(handler.claimCalls(), 0);
    }
}
