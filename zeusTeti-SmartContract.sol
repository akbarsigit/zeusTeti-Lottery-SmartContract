// SPDX-License-Identifier: MIT
pragma solidity ^0.8.7;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@chainlink/contracts/src/v0.8/interfaces/VRFCoordinatorV2Interface.sol";
import "@chainlink/contracts/src/v0.8/VRFConsumerBaseV2.sol";
import "teticoin.sol";


contract ZeusTeti is ReentrancyGuard, VRFConsumerBaseV2, Ownable {

    // for safe token interaction /interface on erc20
    using SafeERC20 for IERC20;
    // for safe formula calculation
    using SafeMath for uint256;

    VRFCoordinatorV2Interface COORDINATOR;

    uint64 private s_subscriptionId;

    // address to call to the blockchain
    address private vrfCoordinator = 0x7a1BaC17Ccc5b313516C5E16fb24f7659aA5ebed;
    bytes32 private keyHash = 0x4b09e658ed251bcafeebbc69400383d49f344ace09b9576fe248bb02c003fe9f;
    uint16 private requestConfirmations = 3;
    
    // asking 4 random number
    uint32 private numWords =  4;
    uint32 private callbackGasLimit = 2500000;
    address private s_owner;

    // storing the request send by vrf
    struct RequestStatus {
        bool fulfilled;
        bool exists;
        uint[] randomWords;
    }

    // mapping s_request to requestStatus => just call s_request later
    // mapping is used to store these statuses with unique request IDs.
    mapping(uint256 => RequestStatus) public s_requests;
    uint256 public lastRequestId;

    IERC20 paytoken;
    // Keep track of the curret draw
    uint256 public currentLotteryId;
    // Keep track of the currect ticket
    uint256 public currentTicketId;
    uint256 public ticketPrice = 10 ether;
    // Fee for the provider. Get 50% of every ticket purchase. 10*50%
    uint256 public serviceFee = 5000; // BASIS POINTS 5000 is 50%
    // Get the lucky number, then for display in FE
    uint256 public numberWinner;

    // draw status
    enum Status {
        Open,       // the ticket can be buy in the draw
        Close,      // no winner decided, cannot buy or cashed out the ticket (the draw is close)
        Claimable   // winner dedicedd. the price for each lotto can be draw
    }

    struct Lottery {
        Status status;
        uint256 startTime;
        uint256 endTime;
        uint256 firstTicketId;      // fist ticket id of each draw
        uint256 lastTicketId;       // last ticket id of each draw
        uint256 transferJackpot;    // Safe the price Pool for each draw. Open at 1000 token 
        uint[4] winningNumbers;
        uint256 totalPayout;
        uint256 commision;
        uint256 winnerCount;
    }

    constructor(uint64 subscriptionId) VRFConsumerBaseV2(vrfCoordinator) Ownable(msg.sender)
    {
        COORDINATOR = VRFCoordinatorV2Interface(vrfCoordinator);
        s_owner = msg.sender;
        s_subscriptionId = subscriptionId;
    }

    // function to finish each lottery => only owner that can close
    // this is also a call to obtain winning number to the vrf
    function lotteryFinish() external onlyOwner {
        uint256 requestId;

        // call ChainLink VRFv2 and obtain the winning numbers from the randomness generator.
        requestId = COORDINATOR.requestRandomWords(
            keyHash,
            s_subscriptionId,
            requestConfirmations,
            callbackGasLimit,
            numWords
        );
        s_requests[requestId] = RequestStatus({
            fulfilled: false,
            exists: true,
            randomWords: new uint256[](0)
        });
        lastRequestId = requestId;
    }

    // Getting the lucky number for the winning numebr
    function getLuckyNumbers() external view onlyOwner returns (uint[4] memory) {
       uint256[] memory numArray = s_requests[lastRequestId].randomWords;
       uint num1 = numArray[0] % 10;
       uint num2 = numArray[1] % 10;
       uint num3 = numArray[2] % 10;
       uint num4 = numArray[3] % 10;
       uint[4] memory finalNumbers = [num1, num2, num3, num4];
       return finalNumbers;
    }

    // call this to get the random number
    // view => not change the contract state && external => can be called outside the contract 
    function getRequestStatus() external view returns (bool fulfilled, uint256[] memory randomWords) {
        require(s_requests[lastRequestId].exists, "request not found");
        RequestStatus memory request = s_requests[lastRequestId];
        return (request.fulfilled, request.randomWords);
    }

    function fulfillRandomWords(uint256 _requestId, uint256[] memory _randomWords) internal override {
        require(s_requests[_requestId].exists, "request not found");
        s_requests[_requestId].fulfilled = true;
        s_requests[_requestId].randomWords = _randomWords;
    }
}