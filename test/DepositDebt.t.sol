// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {VaultFixture} from "./BaskVault.t.sol";
import {BaskVault} from "../src/BaskVault.sol";
import {BaskTypes as T} from "../src/BaskTypes.sol";

contract DepositDebtTest is VaultFixture {
    function _uncoveredClaims() private {
        _setting(T.Setting.DirectLimit, 0);
        _deposit(10e18);
        vm.prank(alice);
        vault.deposit(_one(address(tokens[1])), _amount(10e18), alice, 0, block.timestamp);
        _redeem(vault.balanceOf(alice) / 2);
        tokens[0].burn(address(vault), tokens[0].balanceOf(address(vault)));
        vault.flagDeficit(address(tokens[0]));
        vm.warp(block.timestamp + 7 days);
        vault.recognizeLoss(address(tokens[0]));
        _refresh();
        assertEq(vault.managed(address(tokens[0])), 0);
        assertGt(vault.totalOwed(address(tokens[0])), 0);
        vault.flagDeficit(address(tokens[0]));
        (uint256 recorded,) = vault.deficits(address(tokens[0]));
        assertEq(recorded, 0);
    }

    function testUncoveredClaimsOnZeroManagedNonInputDoNotBlockDeposit() public {
        _uncoveredClaims();
        address[] memory input = _one(address(tokens[1]));
        (T.Reason reason, address fault) = vault.depositStatus(input);
        assertEq(uint256(reason), uint256(T.Reason.OK));
        assertEq(fault, address(0));
        (uint256 preview,,) = vault.previewDeposit(input, _amount(1e18));
        vm.prank(alice);
        uint256 received = vault.deposit(input, _amount(1e18), alice, preview, block.timestamp);
        assertEq(received, preview);
        assertGt(received, 0);
    }

    function testUncoveredClaimsStillBlockDepositingThatToken() public {
        _uncoveredClaims();
        _status(T.Reason.Deficit, address(tokens[0]));
        vm.expectRevert(abi.encodeWithSelector(BaskVault.DepositUnavailable.selector, T.Reason.Deficit, tokens[0]));
        _deposit(1e18);
    }

    function testZeroManagedNonInputMustStillHaveReadableBalance() public {
        _uncoveredClaims();
        tokens[0].setModes(1, 0);
        address[] memory input = _one(address(tokens[1]));
        (T.Reason reason, address fault) = vault.depositStatus(input);
        assertEq(uint256(reason), uint256(T.Reason.BalanceUnreadable));
        assertEq(fault, address(tokens[0]));
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(BaskVault.DepositUnavailable.selector, T.Reason.BalanceUnreadable, tokens[0])
        );
        vault.deposit(input, _amount(1e18), alice, 0, block.timestamp);
    }
}
