// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BaskVault} from "../src/BaskVault.sol";
import {FullMath} from "../src/libraries/FullMath.sol";
import {TickMath} from "../src/libraries/TickMath.sol";
import {BaskOracle as O} from "../src/libraries/BaskOracle.sol";

contract MathHarness {
    function mulDiv(uint256 a, uint256 b, uint256 d) external pure returns (uint256) {
        return FullMath.mulDiv(a, b, d);
    }
}

contract MathAndDeploymentTest is Test {
    function testRuntimeHasNoEscapeInstructions() public {
        BaskVault v = new BaskVault(makeAddr("owner"), makeAddr("guardian"));
        bytes memory code = address(v).code;
        assertLe(code.length, 24_000);
        assertLt(type(BaskVault).creationCode.length + 64, 49_152);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff);
        }
    }

    function testFullMathOverflowAndZeroDenominator() public {
        MathHarness h = new MathHarness();
        vm.expectRevert(FullMath.MathOverflow.selector);
        h.mulDiv(1, 1, 0);
        vm.expectRevert(FullMath.MathOverflow.selector);
        h.mulDiv(type(uint256).max, type(uint256).max, 1);
        assertEq(h.mulDiv(type(uint256).max, type(uint256).max, type(uint256).max), type(uint256).max);
    }

    function testFuzzFullWidthDivisionIdentity(uint256 value) public pure {
        assertEq(FullMath.mulDiv(type(uint256).max, value, type(uint256).max), value);
    }

    function testTickExtremesAndSubUnitValue() public pure {
        assertEq(TickMath.getSqrtRatioAtTick(0), 1 << 96);
        assertEq(TickMath.getSqrtRatioAtTick(-887272), 4295128739);
        assertEq(TickMath.getSqrtRatioAtTick(887272), 1461446703485210103287273052203988822378723970342);
        assertEq(O.value(1e18 + 1, 1, 18, 18), 1);
        assertEq(O.value(1, 1, 0, 0), 1e18);
        assertEq(O.value(1e18 - 1, 1, 18, 18), 0);
    }
}
