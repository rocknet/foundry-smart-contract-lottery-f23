// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {DeployRaffle} from "../../script/DeployRaffle.s.sol";
import {Raffle} from "../../src/Raffle.sol";
import {Test, console} from "forge-std/Test.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {Vm} from "forge-std/Vm.sol";
import {VRFCoordinatorV2Mock} from "@chainlink/contracts/src/v0.8/mocks/VRFCoordinatorV2Mock.sol";

contract RaffleTest is Test {
    Raffle raffle;
    HelperConfig helperConfig;

    uint256 entranceFee;
    uint256 interval;
    address vrfCoordinator;
    bytes32 gasLane;
    uint64 chainLinkSubscriptionId;
    uint32 callbackGasLimit;
    address linkToken;

    address public PLAYER = makeAddr("player");
    uint256 public constant STARTING_USER_BALANCE = 10 ether;

    event RaffleEntered(address indexed player);

    function setUp() external {
        DeployRaffle deployer = new DeployRaffle();
        (raffle, helperConfig) = deployer.run();
        (
            entranceFee,
            interval,
            vrfCoordinator,
            gasLane,
            chainLinkSubscriptionId,
            callbackGasLimit,
            linkToken,

        ) = helperConfig.activeNetworkConfig();

        vm.deal(PLAYER, STARTING_USER_BALANCE);
    }

    function testRaffleInitializesInOpenState() public view {
        assert(raffle.getRaffleState() == Raffle.RaffleState.OPEN);
    }

    /** Enter Raffle */

    function testRaffleRevertsWhenYouDontPayEnough() public {
        vm.prank(PLAYER);

        vm.expectRevert(Raffle.Raffle__NotEnoughEthSent.selector);
        raffle.enterRaffle();
    }

    function testRaffleRecordsPlayerWhenTheyEnter() public playerEntered {
        assertEq(raffle.getPlayer(0), PLAYER);
    }

    function testEmitsEventOnEntry() public {
        vm.prank(PLAYER);

        vm.expectEmit(true, false, false, false);

        emit RaffleEntered(address(PLAYER));

        raffle.enterRaffle{value: entranceFee}();
    }

    function testCantEnterWhenRaffleIsCalculating()
        public
        playerEntered
        timePassed
    {
        raffle.performUpkeep("");

        vm.expectRevert(Raffle.Raffle__NotOpen.selector);
        vm.prank(PLAYER);
        raffle.enterRaffle{value: entranceFee}();
    }

    /** Check Upkeep */

    function testCheckUpkeepReturnsFalseIfItHasNoBalance() public timePassed {
        (bool upkeepNeeded, ) = raffle.checkUpkeep("");

        assertEq(upkeepNeeded, false);
    }

    function testCheckUpkeepReturnsFalseIfRaffleNotOpen()
        public
        playerEntered
        timePassed
    {
        raffle.performUpkeep("");

        (bool upkeepNeeded, ) = raffle.checkUpkeep("");

        assertEq(upkeepNeeded, false);
    }

    function testCheckUpkeepReturnsFalseIfEnoughTimeHasntPassed()
        public
        playerEntered
    {
        (bool upkeepNeeded, ) = raffle.checkUpkeep("");

        assertEq(upkeepNeeded, false);
    }

    function testCheckUpkeepReturnsTrueWhenParametersAreGood()
        public
        playerEntered
        timePassed
    {
        (bool upkeepNeeded, ) = raffle.checkUpkeep("");

        assertEq(upkeepNeeded, true);
    }

    /** Perform Upkeep */
    function testPerformUpkeepCanOnlyRunIfCheckUpkeepIsTrue()
        public
        playerEntered
        timePassed
    {
        raffle.performUpkeep("");
    }

    function testPerformUpkeepRevertsIfCheckUpkeepIsFalse() public {
        uint256 currentBalance = 0;
        uint256 numPlayers = 0;
        Raffle.RaffleState raffleState = Raffle.RaffleState.OPEN;

        vm.expectRevert(
            abi.encodeWithSelector(
                Raffle.Raffle__UpkeepNotNeeded.selector,
                currentBalance,
                numPlayers,
                raffleState
            )
        );

        raffle.performUpkeep("");
    }

    function testPerformUpkeepUpdatesRaffleStateAndEmitsRequestId()
        public
        playerEntered
        timePassed
    {
        vm.recordLogs();
        raffle.performUpkeep("");
        Vm.Log[] memory entries = vm.getRecordedLogs();

        bytes32 requestId = entries[1].topics[1];

        assert(uint256(requestId) > 0);
        assert(raffle.getRaffleState() == Raffle.RaffleState.CALCULATING);
    }

    /** Fullfull Random Words */

    function testFulfillRandomWordsCanOnlyBeCalledAfterPerformUpkeep(
        uint256 randomReqestId
    ) public playerEntered timePassed skipFork {
        vm.expectRevert("nonexistent request");
        VRFCoordinatorV2Mock(vrfCoordinator).fulfillRandomWords(
            randomReqestId,
            address(raffle)
        );
    }

    function testFulfillRandomWordsPicksAWinnerResetsAndSendsMoney()
        public
        playerEntered
        timePassed
        skipFork
    {
        uint256 additionalEntrants = 5;
        for (uint256 i = 1; i <= additionalEntrants; i++) {
            address player = address(uint160(i));
            hoax(player, STARTING_USER_BALANCE);
            raffle.enterRaffle{value: entranceFee}();
        }

        uint256 prize = entranceFee * (additionalEntrants + 1);

        vm.recordLogs();
        raffle.performUpkeep("");
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 requestId = entries[1].topics[1];

        uint256 previousTimestamp = raffle.getLastTimestamp();

        VRFCoordinatorV2Mock(vrfCoordinator).fulfillRandomWords(
            uint256(requestId),
            address(raffle)
        );

        assert(raffle.getRaffleState() == Raffle.RaffleState.OPEN);
        assert(raffle.getRecentWinner() != address(0));
        assert(raffle.getLengthOfPlayers() == 0);
        assert(previousTimestamp < raffle.getLastTimestamp());
        assert(
            raffle.getRecentWinner().balance ==
                STARTING_USER_BALANCE + prize - entranceFee
        );
    }

    /** Modifiers */
    modifier playerEntered() {
        vm.prank(PLAYER);
        raffle.enterRaffle{value: entranceFee}();
        _;
    }

    modifier timePassed() {
        vm.warp(block.timestamp + interval + 1);
        vm.roll(block.number + 1);
        _;
    }

    modifier skipFork() {
        if (block.chainid != 31337) {
            return;
        }
        _;
    }
}
