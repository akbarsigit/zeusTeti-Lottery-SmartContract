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
        uint256 totalPayout;        // jackpot that are diveded for each winner
        uint256 commision;          // money for me (developer)
        uint256 winnerCount;
    }

    struct Ticket {
        uint256 ticketId;
        address owner;
        uint[4] chooseNumbers;
    }

    mapping(uint256 => Lottery) private _lotteries;
    mapping(uint256 => Ticket) private _tickets;
    mapping(address => mapping(uint256 => uint256[])) private _userTicketIdsPerLotteryId;

    // mapping if buyer is winning lottery on particular draw
    mapping(address => mapping(uint256 => uint256)) public _winnersPerLotteryId;

    event LotteryWinnerNumber(uint256 indexed lotteryId, uint[4] finalNumber);

    event LotteryClose(
        uint256 indexed lotteryId,
        uint256 lastTicketId
    );

    event LotteryOpen(
        uint256 indexed lotteryId,
        uint256 startTime,
        uint256 endTime,
        uint256 ticketPrice,
        uint256 firstTicketId,
        uint256 transferJackpot,
        uint256 lastTicketId,
        uint256 totalPayout
    );

    event TicketsPurchase(
        address indexed buyer,
        uint256 indexed lotteryId,
        uint[4] chooseNumbers
    );

    constructor(uint64 subscriptionId, IERC20 _paytoken) VRFConsumerBaseV2(vrfCoordinator) Ownable(msg.sender)
    {
        COORDINATOR = VRFCoordinatorV2Interface(vrfCoordinator);
        s_owner = msg.sender;
        s_subscriptionId = subscriptionId;
        paytoken = _paytoken;
    }

    
    function openLottery() external onlyOwner nonReentrant {
        currentLotteryId++; // draw 1, draw 2, draw 3
        currentTicketId++;  // last ticket id + 1
        // add a new jackpot value for each draw. prev draw + 1000
        uint256 fundJackpot = (_lotteries[currentLotteryId].transferJackpot).add(1000 ether);
        uint256 transferJackpot;
        uint256 totalPayout;
        uint256 lastTicketId;
        uint256 endTime;
        _lotteries[currentLotteryId] = Lottery({
            status: Status.Open,
            startTime: block.timestamp,
            endTime: (block.timestamp).add(1 hours),
            firstTicketId: currentTicketId,
            transferJackpot: fundJackpot,
            winningNumbers: [uint(0), uint(0), uint(0), uint(0)],
            lastTicketId: currentTicketId,
            totalPayout: 0, // prize for each winner. divide when more than one winner 
            commision: 0,
            winnerCount: 0
        });
        emit LotteryOpen(
            currentLotteryId,
            block.timestamp,
            endTime,
            ticketPrice,
            currentTicketId,
            transferJackpot,
            lastTicketId,
            totalPayout
        );
    }

    function buyTickets(uint[4] calldata numbers) public payable nonReentrant {
        // check the wallet/money of user
        uint256 walletBalance = paytoken.balanceOf(msg.sender);
        require(walletBalance >= ticketPrice, "Funds not available to complete transaction");
        paytoken.transferFrom(address(msg.sender), address(this), ticketPrice);

        // 10 x 5000 / 10000 = 5
        uint256 commisionFee = (ticketPrice.mul(serviceFee)).div(10000);

        // keep my commision  
        _lotteries[currentLotteryId].commision += commisionFee;
        // From ticket sale, remainder money to add to the jackpot 
        uint256 netEarn = ticketPrice - commisionFee;
        // adding jacpot price pool from ticket sale
        _lotteries[currentLotteryId].transferJackpot += netEarn;

        // add the purchased ticket to the buyer address per draw
        _userTicketIdsPerLotteryId[msg.sender][currentLotteryId].push(currentTicketId);

        // save the ticket that purchased
        _tickets[currentTicketId] = Ticket({ticketId:currentTicketId, owner: msg.sender, chooseNumbers: numbers });
        currentTicketId++;
        _lotteries[currentLotteryId].lastTicketId = currentTicketId;

        emit TicketsPurchase(msg.sender, currentLotteryId, numbers);
    }


    // function to finish each lottery => only owner that can close
    // this is also a call to obtain winning number to the vrf
    function closeLottery() external onlyOwner {
        require(_lotteries[currentLotteryId].status == Status.Open, "Lottery not open");
        require(block.timestamp > _lotteries[currentLotteryId].endTime, "Lottery not over");

        _lotteries[currentLotteryId].lastTicketId = currentTicketId;
        _lotteries[currentLotteryId].status = Status.Close;

        // ChainLink VRF request Id from calling the random number
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
            randomWords: new uint256[](0),
            exists: true,
            fulfilled: false
        });
        lastRequestId = requestId;
        emit LotteryClose(currentLotteryId, currentTicketId);
    }

    // Getting the from the called random number => lucky number for the winning numebr
    function getLuckyNumbers() external onlyOwner nonReentrant () {
        require(_lotteries[currentLotteryId].status == Status.Close, "Lottery not close");
        uint256[] memory numArray = s_requests[lastRequestId].randomWords;
        uint num1 = numArray[0] % 10;
        uint num2 = numArray[1] % 10;
        uint num3 = numArray[2] % 10;
        uint num4 = numArray[3] % 10;
        uint[4] memory finalNumbers = [num1, num2, num3, num4];
        _lotteries[currentLotteryId].winningNumbers = finalNumbers;

        // total payout is the jackpot pool => so that we can devide the winner jackpot price
       _lotteries[currentLotteryId].totalPayout = _lotteries[currentLotteryId].transferJackpot;
    }

    // sorting on off-chain to save gas fee
    function sortArrays(uint[4] memory numbers) internal pure returns (uint[4] memory) {
        bool swapped;
        // bubble sort 
        for (uint i = 1; i < numbers.length; i++) {
            swapped = false;
            for (uint j = 0; j < numbers.length - i; j++) {
                uint next = numbers[j + 1];
                uint actual = numbers[j];
                if (next < actual) {
                    numbers[j] = next;
                    numbers[j + 1] = actual;
                    swapped = true;
                }
            }
            if (!swapped) {
                return numbers;
            }
        }
        return numbers;
    }


    function countWinners(uint[4] memory luckNumber, uint256 _lottoId) external onlyOwner {
        require(_lotteries[_lottoId].status == Status.Close, "Lottery not close");
        require(_lotteries[_lottoId].status != Status.Claimable, "Lottery Already Counted");

        // reset the previous user that win in the last draw 
        delete numberWinner;

        uint256 firstTicketId = _lotteries[_lottoId].firstTicketId;
        uint256 lastTicketId = _lotteries[_lottoId].lastTicketId;

        uint[4] memory winOrder;
        // sort the lucky number
        winOrder = sortArrays(luckNumber);

        // hash the lucky number and compare to the user number  
        bytes32 encodeWin = keccak256(abi.encodePacked(winOrder));
        uint256 i = firstTicketId;
            for (i; i < lastTicketId; i++) {
                address buyer = _tickets[i].owner;
                uint[4] memory userNum = _tickets[i].chooseNumbers;
                // does not need to sort the number from user, because we dit it in the FE
                bytes32 encodeUser = keccak256(abi.encodePacked(userNum));
                if (encodeUser == encodeWin) {
                    numberWinner++;
                    _lotteries[_lottoId].winnerCount = numberWinner;
                    // store buyyer address that win => mark it as 1
                    _winnersPerLotteryId[buyer][_lottoId] = 1;
                }
            }
            // if no winner => transfer prize pool on this draw to the next draw
            if (numberWinner == 0){
                uint256 nextLottoId = (currentLotteryId).add(1);
                _lotteries[nextLottoId].transferJackpot = _lotteries[currentLotteryId].totalPayout;
            }
        // If all procedure was done => user can claim the reward
        _lotteries[currentLotteryId].status = Status.Claimable;
   }
   
   function claimPrize(uint256 _lottoId) external nonReentrant {
        require(_lotteries[_lottoId].status == Status.Claimable, "Not Payable");
        require(_lotteries[_lottoId].winnerCount > 0, "Not Payable");
        // if the user that call this function is not win on the particular draw => cant claim
        require(_winnersPerLotteryId[msg.sender][_lottoId] == 1, "Not Payable");
        uint256 winners = _lotteries[_lottoId].winnerCount;
        uint256 payout = (_lotteries[_lottoId].totalPayout).div(winners);
        paytoken.safeTransfer(msg.sender, payout);
        _winnersPerLotteryId[msg.sender][_lottoId] = 0;
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