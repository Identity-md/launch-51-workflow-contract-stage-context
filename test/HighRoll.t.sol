// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HighRoll} from "../src/HighRoll.sol";
import {HighRollToken} from "../src/HighRollToken.sol";

contract HighRollTest is Test {
    HighRollToken token;
    HighRoll game;
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address outsider = address(0xCAFE);
    uint256 constant STAKE = 10 ether;
    bytes32 constant SALT1 = keccak256("alice secret");
    bytes32 constant SALT2 = keccak256("bob secret");

    event Opened(uint256 indexed gameId, address indexed player, uint256 stake, bytes32 commitment);
    event Joined(uint256 indexed gameId, address indexed player, bytes32 commitment, uint256 deadline);
    event Revealed(uint256 indexed gameId, address indexed player, uint8 roll);
    event Settled(uint256 indexed gameId, address indexed winner, uint256 pot);
    event Cancelled(uint256 indexed gameId);

    function test_lifecycleEventsForIndexer() public {
        bytes32 c1 = game.commitmentHash(3, SALT1);
        bytes32 c2 = game.commitmentHash(2, SALT2);
        vm.expectEmit(true, true, false, true, address(game));
        emit Opened(0, alice, STAKE, c1);
        vm.prank(alice);
        game.openGame(STAKE, c1);
        vm.expectEmit(true, true, false, true, address(game));
        emit Joined(0, bob, c2, block.timestamp + 24 hours);
        vm.prank(bob);
        game.joinGame(0, STAKE, c2);
        vm.expectEmit(true, true, false, true, address(game));
        emit Revealed(0, alice, 3);
        revealAs(alice, 0, 3, SALT1);
        vm.expectEmit(true, true, false, true, address(game));
        emit Revealed(0, bob, 2);
        vm.expectEmit(true, true, false, true, address(game));
        emit Settled(0, alice, 2 * STAKE);
        revealAs(bob, 0, 2, SALT2);
        uint256 id = open(1);
        vm.expectEmit(true, false, false, true, address(game));
        emit Cancelled(id);
        vm.prank(alice);
        game.cancel(id);
    }

    function setUp() public {
        token = new HighRollToken();
        game = new HighRoll(address(token));
        token.transfer(alice, 100 ether);
        token.transfer(bob, 100 ether);
        vm.prank(alice);
        token.approve(address(game), type(uint256).max);
        vm.prank(bob);
        token.approve(address(game), type(uint256).max);
    }

    function state(uint256 id) internal view returns (HighRoll.Game memory g) {
        (bool ok, bytes memory data) = address(game).staticcall(abi.encodeWithSignature("games(uint256)", id));
        assertTrue(ok);
        g = abi.decode(data, (HighRoll.Game));
    }

    function open(uint8 roll) internal returns (uint256 id) {
        bytes32 commitment = game.commitmentHash(roll, SALT1);
        vm.prank(alice);
        id = game.openGame(STAKE, commitment);
    }

    function join(uint256 id, uint8 roll) internal {
        bytes32 commitment = game.commitmentHash(roll, SALT2);
        vm.prank(bob);
        game.joinGame(id, STAKE, commitment);
    }

    function revealAs(address who, uint256 id, uint8 roll, bytes32 salt) internal {
        vm.prank(who);
        game.reveal(id, roll, salt);
    }

    function test_constructorRejectsNonContracts() public {
        vm.expectRevert(HighRoll.InvalidToken.selector);
        new HighRoll(address(0));
        vm.expectRevert(HighRoll.InvalidToken.selector);
        new HighRoll(alice);
        assertEq(address(game.token()), address(token));
    }

    function test_openJoinAndWindowBeginsAtJoin() public {
        uint256 id = open(3);
        assertEq(id, 0);
        assertEq(game.nextGameId(), 1);
        assertEq(state(id).deadline, 0);
        assertEq(token.balanceOf(address(game)), STAKE);
        vm.warp(10 days);
        join(id, 4);
        assertEq(state(id).deadline, 11 days);
        assertEq(uint256(state(id).state), uint256(HighRoll.State.Active));
        assertEq(token.balanceOf(address(game)), 2 * STAKE);
    }

    function testFuzz_allRollsConserveFunds(uint8 a, uint8 b, bool reverse) public {
        a = uint8(bound(a, 1, 6));
        b = uint8(bound(b, 1, 6));
        uint256 id = open(a);
        join(id, b);
        if (reverse) {
            revealAs(bob, id, b, SALT2);
            revealAs(alice, id, a, SALT1);
        } else {
            revealAs(alice, id, a, SALT1);
            revealAs(bob, id, b, SALT2);
        }
        assertEq(token.balanceOf(alice), a > b ? 110 ether : a == b ? 100 ether : 90 ether);
        assertEq(token.balanceOf(bob), b > a ? 110 ether : a == b ? 100 ether : 90 ether);
        assertEq(token.balanceOf(address(game)), 0);
        assertEq(uint256(state(id).state), uint256(HighRoll.State.Settled));
        assertEq(token.totalSupply(), 1e27);
    }

    function test_forfeitEitherPlayerAndPermissionlessSettlement() public {
        for (uint256 i; i < 2; ++i) {
            uint256 id = open(1);
            join(id, 6);
            address winner = i == 0 ? alice : bob;
            uint256 before = token.balanceOf(winner);
            revealAs(winner, id, i == 0 ? 1 : 6, i == 0 ? SALT1 : SALT2);
            vm.expectRevert(HighRoll.TooEarly.selector);
            game.settle(id);
            vm.warp(state(id).deadline);
            vm.prank(outsider);
            game.settle(id);
            assertEq(token.balanceOf(winner), before + 2 * STAKE);
            assertEq(token.balanceOf(address(game)), 0);
            vm.expectRevert(HighRoll.InvalidState.selector);
            game.settle(id);
            vm.prank(alice);
            vm.expectRevert(HighRoll.InvalidState.selector);
            game.cancel(id);
        }
    }

    function test_noRevealsEitherPlayerCanRefund() public {
        for (uint256 i; i < 2; ++i) {
            uint256 id = open(3);
            join(id, 2);
            vm.prank(alice);
            vm.expectRevert(HighRoll.TooEarly.selector);
            game.cancel(id);
            vm.warp(state(id).deadline);
            vm.expectRevert(HighRoll.InvalidState.selector);
            game.settle(id);
            vm.prank(outsider);
            vm.expectRevert(HighRoll.NotPlayer.selector);
            game.cancel(id);
            vm.prank(i == 0 ? alice : bob);
            game.cancel(id);
            assertEq(token.balanceOf(alice), 100 ether);
            assertEq(token.balanceOf(bob), 100 ether);
            assertEq(token.balanceOf(address(game)), 0);
            assertEq(uint256(state(id).state), uint256(HighRoll.State.Cancelled));
        }
    }

    function test_cancelUnmatchedAndRejectLateJoin() public {
        uint256 id = open(4);
        vm.prank(bob);
        vm.expectRevert(HighRoll.NotPlayer.selector);
        game.cancel(id);
        vm.prank(alice);
        game.cancel(id);
        assertEq(token.balanceOf(alice), 100 ether);
        vm.prank(alice);
        vm.expectRevert(HighRoll.InvalidState.selector);
        game.cancel(id);
        vm.expectRevert(HighRoll.InvalidState.selector);
        game.joinGame(id, STAKE, SALT2);
    }

    function test_revealDeadlineBoundary() public {
        uint256 id = open(2);
        join(id, 5);
        vm.warp(state(id).deadline - 1);
        revealAs(alice, id, 2, SALT1);
        vm.warp(state(id).deadline);
        vm.prank(bob);
        vm.expectRevert(HighRoll.DeadlinePassed.selector);
        game.reveal(id, 5, SALT2);
        vm.prank(bob);
        vm.expectRevert(HighRoll.InvalidState.selector);
        game.cancel(id);
        game.settle(id);
        assertEq(token.balanceOf(alice), 110 ether);
    }

    function test_invalidOpenStakeOrCommitment() public {
        vm.expectRevert(HighRoll.InvalidStake.selector);
        game.openGame(0, SALT1);
        vm.expectRevert(HighRoll.InvalidStake.selector);
        game.openGame(type(uint256).max, SALT1);
        vm.expectRevert(HighRoll.InvalidCommitment.selector);
        game.openGame(STAKE, bytes32(0));
        assertEq(game.nextGameId(), 0);
    }

    function test_joinRejectsWrongStakeSelfZeroCopiedAndDuplicate() public {
        uint256 id = open(3);
        vm.prank(alice);
        vm.expectRevert(HighRoll.SamePlayer.selector);
        game.joinGame(id, STAKE, SALT2);
        vm.expectRevert(HighRoll.InvalidStake.selector);
        game.joinGame(id, STAKE + 1, SALT2);
        vm.expectRevert(HighRoll.InvalidCommitment.selector);
        game.joinGame(id, STAKE, bytes32(0));
        bytes32 copied = state(id).commitment1;
        vm.expectRevert(HighRoll.InvalidCommitment.selector);
        game.joinGame(id, STAKE, copied);
        join(id, 4);
        vm.expectRevert(HighRoll.InvalidState.selector);
        game.joinGame(id, STAKE, SALT2);
    }

    function test_rejectsInvalidRevealsAndDuplicate() public {
        uint256 id = open(3);
        vm.prank(alice);
        vm.expectRevert(HighRoll.InvalidState.selector);
        game.reveal(id, 3, SALT1);
        join(id, 4);
        vm.prank(alice);
        vm.expectRevert(HighRoll.InvalidRoll.selector);
        game.reveal(id, 0, SALT1);
        vm.prank(alice);
        vm.expectRevert(HighRoll.InvalidRoll.selector);
        game.reveal(id, 7, SALT1);
        vm.prank(alice);
        vm.expectRevert(HighRoll.InvalidCommitment.selector);
        game.reveal(id, 4, SALT1);
        vm.prank(bob);
        vm.expectRevert(HighRoll.InvalidCommitment.selector);
        game.reveal(id, 4, SALT1);
        vm.prank(outsider);
        vm.expectRevert(HighRoll.NotPlayer.selector);
        game.reveal(id, 3, SALT1);
        revealAs(alice, id, 3, SALT1);
        vm.prank(alice);
        vm.expectRevert(HighRoll.AlreadyRevealed.selector);
        game.reveal(id, 3, SALT1);
        revealAs(bob, id, 4, SALT2);
        vm.prank(bob);
        vm.expectRevert(HighRoll.InvalidState.selector);
        game.reveal(id, 4, SALT2);
    }

    function test_invalidCommittedRollCannotRevealAndLosesByForfeit() public {
        uint256 id = open(7);
        join(id, 1);
        vm.prank(alice);
        vm.expectRevert(HighRoll.InvalidRoll.selector);
        game.reveal(id, 7, SALT1);
        revealAs(bob, id, 1, SALT2);
        vm.warp(state(id).deadline);
        game.settle(id);
        assertEq(token.balanceOf(bob), 110 ether);
    }

    function test_approvalFailuresRollbackOpeningAndJoining() public {
        vm.prank(alice);
        token.approve(address(game), 0);
        vm.prank(alice);
        vm.expectRevert(HighRollToken.InsufficientAllowance.selector);
        game.openGame(STAKE, SALT1);
        assertEq(game.nextGameId(), 0);
        vm.prank(alice);
        token.approve(address(game), STAKE);
        uint256 id = open(3);
        vm.prank(bob);
        token.approve(address(game), STAKE - 1);
        vm.prank(bob);
        vm.expectRevert(HighRollToken.InsufficientAllowance.selector);
        game.joinGame(id, STAKE, SALT2);
        assertEq(uint256(state(id).state), uint256(HighRoll.State.Open));
        assertEq(state(id).player2, address(0));
        assertEq(token.balanceOf(address(game)), STAKE);
    }

    function test_unknownGamesRejectActions() public {
        vm.expectRevert(HighRoll.InvalidState.selector);
        game.joinGame(42, STAKE, SALT1);
        vm.expectRevert(HighRoll.InvalidState.selector);
        game.reveal(42, 1, SALT1);
        vm.expectRevert(HighRoll.InvalidState.selector);
        game.settle(42);
        vm.expectRevert(HighRoll.NotPlayer.selector);
        game.cancel(42);
    }

    function test_multipleGamesAreIsolated() public {
        uint256 first = open(6);
        uint256 second = open(1);
        join(first, 2);
        join(second, 5);
        revealAs(alice, first, 6, SALT1);
        revealAs(bob, first, 2, SALT2);
        assertEq(token.balanceOf(address(game)), 2 * STAKE);
        assertEq(uint256(state(second).state), uint256(HighRoll.State.Active));
        vm.warp(state(second).deadline);
        vm.prank(bob);
        game.cancel(second);
        assertEq(token.balanceOf(address(game)), 0);
        assertEq(token.balanceOf(alice) + token.balanceOf(bob), 200 ether);
    }
}
