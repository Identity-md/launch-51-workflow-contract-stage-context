// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HighRoll} from "../src/HighRoll.sol";

/// @dev Test-only token: callbacks, false returns, and transfer reverts are configurable.
contract AdversarialToken {
    mapping(address => uint256) public balanceOf;
    HighRoll public target;
    bytes public callback;
    bytes public callbackResult;
    bool public callbackSucceeded;
    bool public bubbleCallback;
    bool public failInbound;
    uint256 public failOutboundAt;
    uint256 public outboundCalls;
    bool public revertOutbound;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function configure(HighRoll game, bytes calldata data, bool bubble) external {
        target = game;
        callback = data;
        bubbleCallback = bubble;
    }

    function setFailure(bool inbound, uint256 outbound, bool revertCall) external {
        failInbound = inbound;
        failOutboundAt = outbound;
        revertOutbound = revertCall;
        outboundCalls = 0;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (failInbound) return false;
        _move(from, to, amount);
        _callback();
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        outboundCalls++;
        if (outboundCalls == failOutboundAt) {
            require(!revertOutbound, "token payout reverted");
            return false;
        }
        _move(msg.sender, to, amount);
        _callback();
        return true;
    }

    function _move(address from, address to, uint256 amount) private {
        require(balanceOf[from] >= amount, "balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }

    function _callback() private {
        if (callback.length == 0) return;
        (callbackSucceeded, callbackResult) = address(target).call(callback);
        if (bubbleCallback && !callbackSucceeded) {
            bytes memory reason = callbackResult;
            assembly ("memory-safe") { revert(add(reason, 32), mload(reason)) }
        }
    }
}

contract AdversarialTokenTest is Test {
    AdversarialToken token;
    HighRoll game;
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    bytes32 salt1 = bytes32(uint256(1));
    bytes32 salt2 = bytes32(uint256(2));

    function setUp() public {
        token = new AdversarialToken();
        game = new HighRoll(address(token));
        token.mint(alice, 100);
        token.mint(bob, 100);
    }

    function state(uint256 id) internal view returns (HighRoll.Game memory) {
        (bool ok, bytes memory data) = address(game).staticcall(abi.encodeWithSignature("games(uint256)", id));
        assertTrue(ok);
        return abi.decode(data, (HighRoll.Game));
    }

    function open() internal returns (uint256 id) {
        bytes32 commitment = game.commitmentHash(3, salt1);
        vm.prank(alice);
        return game.openGame(10, commitment);
    }

    function join(uint256 id, uint8 roll) internal {
        bytes32 commitment = game.commitmentHash(roll, salt2);
        vm.prank(bob);
        game.joinGame(id, 10, commitment);
    }

    function assertCallbackBlocked() internal view {
        assertFalse(token.callbackSucceeded());
        assertEq(token.callbackResult(), abi.encodeWithSelector(HighRoll.Reentrancy.selector));
    }

    function test_allMutatorsBlockedOnInboundAndOutboundCallbacks() public {
        bytes[5] memory calls = [
            abi.encodeCall(game.openGame, (10, salt1)),
            abi.encodeCall(game.joinGame, (0, 10, salt2)),
            abi.encodeCall(game.reveal, (0, 3, salt1)),
            abi.encodeCall(game.settle, (0)),
            abi.encodeCall(game.cancel, (0))
        ];
        for (uint256 i; i < calls.length; ++i) {
            token.configure(game, calls[i], false);
            uint256 id = open();
            assertCallbackBlocked();
            join(id, 2);
            assertCallbackBlocked();
            vm.prank(alice);
            game.reveal(id, 3, salt1);
            vm.prank(bob);
            game.reveal(id, 2, salt2);
            assertCallbackBlocked();
            assertEq(token.balanceOf(address(game)), 0);
            assertEq(uint256(state(id).state), uint256(HighRoll.State.Settled));
        }
        assertEq(token.balanceOf(alice), 150);
        assertEq(token.balanceOf(bob), 50);
    }

    function test_bubbledReentrancyRollsBackAndCanRetry() public {
        token.configure(game, abi.encodeCall(game.cancel, (0)), true);
        vm.prank(alice);
        vm.expectRevert(HighRoll.Reentrancy.selector);
        game.openGame(10, salt1);
        assertEq(game.nextGameId(), 0);
        assertEq(token.balanceOf(alice), 100);
        token.configure(game, "", false);
        uint256 id = open();
        assertEq(id, 0);
        token.configure(game, abi.encodeCall(game.openGame, (10, salt1)), true);
        vm.prank(alice);
        vm.expectRevert(HighRoll.Reentrancy.selector);
        game.cancel(id);
        assertEq(uint256(state(id).state), uint256(HighRoll.State.Open));
        assertEq(token.balanceOf(address(game)), 10);
        token.configure(game, "", false);
        vm.prank(alice);
        game.cancel(id);
        assertEq(token.balanceOf(alice), 100);
    }

    function test_falseInboundRollsBackOpenAndJoin() public {
        token.setFailure(true, 0, false);
        vm.prank(alice);
        vm.expectRevert(HighRoll.TransferFailed.selector);
        game.openGame(10, salt1);
        assertEq(game.nextGameId(), 0);
        token.setFailure(false, 0, false);
        uint256 id = open();
        token.setFailure(true, 0, false);
        vm.prank(bob);
        vm.expectRevert(HighRoll.TransferFailed.selector);
        game.joinGame(id, 10, salt2);
        assertEq(state(id).player2, address(0));
        assertEq(uint256(state(id).state), uint256(HighRoll.State.Open));
    }

    function test_failedSecondTiePayoutRollsBackBothTransfersAndReveal() public {
        uint256 id = open();
        join(id, 3);
        vm.prank(alice);
        game.reveal(id, 3, salt1);
        token.setFailure(false, 2, false);
        vm.prank(bob);
        vm.expectRevert(HighRoll.TransferFailed.selector);
        game.reveal(id, 3, salt2);
        assertEq(state(id).roll2, 0);
        assertEq(state(id).roll1, 3);
        assertEq(uint256(state(id).state), uint256(HighRoll.State.Active));
        assertEq(token.balanceOf(alice), 90);
        assertEq(token.balanceOf(bob), 90);
        assertEq(token.balanceOf(address(game)), 20);
        token.setFailure(false, 0, false);
        vm.prank(bob);
        game.reveal(id, 3, salt2);
        assertEq(token.balanceOf(alice), 100);
        assertEq(token.balanceOf(bob), 100);
    }

    function test_revertingForfeitPayoutCanBeRetried() public {
        uint256 id = open();
        join(id, 1);
        vm.prank(alice);
        game.reveal(id, 3, salt1);
        vm.warp(state(id).deadline);
        token.setFailure(false, 1, true);
        vm.expectRevert(bytes("token payout reverted"));
        game.settle(id);
        assertEq(uint256(state(id).state), uint256(HighRoll.State.Active));
        assertEq(token.balanceOf(address(game)), 20);
        token.setFailure(false, 0, false);
        game.settle(id);
        assertEq(token.balanceOf(alice), 110);
    }

    function test_failedSecondRefundRollsBackAndRetry() public {
        uint256 id = open();
        join(id, 2);
        vm.warp(state(id).deadline);
        token.setFailure(false, 2, false);
        vm.prank(bob);
        vm.expectRevert(HighRoll.TransferFailed.selector);
        game.cancel(id);
        assertEq(token.balanceOf(alice), 90);
        assertEq(token.balanceOf(address(game)), 20);
        assertEq(uint256(state(id).state), uint256(HighRoll.State.Active));
        token.setFailure(false, 0, false);
        vm.prank(alice);
        game.cancel(id);
        assertEq(token.balanceOf(alice), 100);
        assertEq(token.balanceOf(bob), 100);
    }
}
