// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HighRollToken} from "../src/HighRollToken.sol";

contract HighRollTokenTest is Test {
    HighRollToken token;
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public {
        token = new HighRollToken();
    }

    function test_metadataAndSupply() public view {
        assertEq(token.name(), "High Roll");
        assertEq(token.symbol(), "ROLL");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(this)), 1e27);
    }

    function testFuzz_transferConservesSupply(uint256 amount) public {
        amount = bound(amount, 0, 1e27);
        assertTrue(token.transfer(alice, amount));
        assertEq(token.balanceOf(alice), amount);
        assertEq(token.balanceOf(address(this)), 1e27 - amount);
        vm.prank(alice);
        token.transfer(alice, amount);
        assertEq(token.balanceOf(alice), amount);
        assertEq(token.totalSupply(), 1e27);
    }

    function test_allowanceSpendingReplacementAndRevocation() public {
        token.approve(bob, 100);
        vm.prank(bob);
        token.transferFrom(address(this), alice, 40);
        assertEq(token.allowance(address(this), bob), 60);
        token.approve(bob, 20);
        assertEq(token.allowance(address(this), bob), 20);
        token.approve(bob, 0);
        vm.prank(bob);
        vm.expectRevert(HighRollToken.InsufficientAllowance.selector);
        token.transferFrom(address(this), alice, 1);
        assertEq(token.balanceOf(alice), 40);
    }

    function test_infiniteAllowance() public {
        token.approve(bob, type(uint256).max);
        vm.prank(bob);
        token.transferFrom(address(this), alice, 100);
        assertEq(token.allowance(address(this), bob), type(uint256).max);
    }

    function test_rejectsZeroAddressesInsufficientBalanceAndUnauthorizedSpend() public {
        vm.expectRevert(HighRollToken.ZeroAddress.selector);
        token.transfer(address(0), 1);
        vm.expectRevert(HighRollToken.ZeroAddress.selector);
        token.approve(address(0), 1);
        vm.prank(alice);
        vm.expectRevert(HighRollToken.InsufficientBalance.selector);
        token.transfer(bob, 1);
        vm.prank(bob);
        vm.expectRevert(HighRollToken.InsufficientAllowance.selector);
        token.transferFrom(address(this), alice, 1);
        vm.prank(alice);
        token.approve(bob, 100);
        vm.prank(bob);
        vm.expectRevert(HighRollToken.InsufficientBalance.selector);
        token.transferFrom(alice, bob, 100);
        assertEq(token.allowance(alice, bob), 100);
    }

    function test_noMintOrAdminEntryPointsEvenForDeployer() public {
        string[5] memory signatures = [
            "mint(address,uint256)",
            "initialize(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "setMinter(address)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            (bool ok,) = address(token).call(abi.encodeWithSignature(signatures[i], alice, 1e27));
            assertFalse(ok);
        }
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(alice), 0);
    }
}
