// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HighRoll} from "../src/HighRoll.sol";
import {HighRollToken} from "../src/HighRollToken.sol";

contract FactoryFixture {
    function deploy() external returns (HighRollToken token, HighRoll game) {
        token = new HighRollToken{salt: bytes32(uint256(1))}();
        game = new HighRoll{salt: bytes32(uint256(2))}(address(token));
    }
}

contract DeploymentTest is Test {
    function test_factoryDeploymentPreservesSupplyAndRuntimePolicy() public {
        FactoryFixture factory = new FactoryFixture();
        (HighRollToken token, HighRoll game) = factory.deploy();
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(factory)), 1e27);
        assertEq(address(game.token()), address(token));
        assertEq(token.balanceOf(address(game)), 0);
        checkRuntime(address(token));
        checkRuntime(address(game));
    }

    function checkRuntime(address deployed) internal view {
        bytes memory code = deployed.code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff);
        }
    }
}
