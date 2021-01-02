// SPDX-License-Identifier: UNLICENSED

pragma solidity 0.6.11;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./aave/ILendingPoolAddressesProvider.sol";
import "./aave/ILendingPool.sol";
import "./aave/AToken.sol";

/**
 * Play the save game.
 *
 */

contract GoodGhosting is Ownable, Pausable {
    using SafeMath for uint256;

    // Controls if tokens were redeemed or not from the pool
    bool public redeemed;
    // Stores the total amount of interest received in the game.
    uint256 public totalGameInterest;
    //  total principal amount
    uint256 public totalGamePrincipal;

    // Token that players use to buy in the game - DAI
    IERC20 public immutable daiToken;
    // Pointer to aDAI
    AToken public immutable adaiToken;
    // Which Aave instance we use to swap DAI to interest bearing aDAI
    ILendingPoolAddressesProvider public immutable lendingPoolAddressProvider;
    ILendingPool public lendingPool;

    uint256 public immutable segmentPayment;
    uint256 public immutable lastSegment;
    uint256 public immutable firstSegmentStart;
    uint256 public immutable segmentLength;
    uint256 public immutable earlyWithdrawalFee;

    struct Player {
        address addr;
        bool withdrawn;
        uint256 mostRecentSegmentPaid;
        uint256 amountPaid;
    }
    mapping(address => Player) public players;
    // we need to differentiate the deposit amount to aave or any other protocol for each window hence this mapping segment no => total deposit amount for that
    mapping(uint256 => uint256) public segmentDeposit;
    address[] public iterablePlayers;
    address[] public winners;

    event JoinedGame(address indexed player, uint256 amount);
    event Deposit(
        address indexed player,
        uint256 indexed segment,
        uint256 amount
    );
    event Withdrawal(address indexed player, uint256 amount);
    event FundsDepositedIntoExternalPool(uint256 amount);
    event FundsRedeemedFromExternalPool(
        uint256 totalAmount,
        uint256 totalGamePrincipal,
        uint256 totalGameInterest
    );
    event WinnersAnnouncement(address[] winners);
    event EarlyWithdrawal(address indexed player, uint256 amount);

    modifier whenGameIsCompleted() {
        require(isGameCompleted(), "Game is not completed");
        _;
    }

    modifier whenGameIsNotCompleted() {
        require(!isGameCompleted(), "Game is already completed");
        _;
    }

    /**
        Creates a new instance of GoodGhosting game
        @param _inboundCurrency Smart contract address of inbound currency used for the game.
        @param _lendingPoolAddressProvider Smart contract address of the lending pool adddress provider.
        @param _segmentCount Number of segments in the game.
        @param _segmentLength Lenght of each segment, in seconds (i.e., 180 (sec) => 3 minutes).
        @param _segmentPayment Amount of tokens each player needs to contribute per segment (i.e. 10*10**18 equals to 10 DAI - note that DAI uses 18 decimal places).
        @param _earlyWithdrawalFee Fee paid by users on early withdrawals (before the game completes). Used as an integer percentage (i.e., 10 represents 10%).
        @param _dataProvider id for getting the data provider contract address 0x1 to be passed.
     */
    constructor(
        IERC20 _inboundCurrency,
        ILendingPoolAddressesProvider _lendingPoolAddressProvider,
        uint256 _segmentCount,
        uint256 _segmentLength,
        uint256 _segmentPayment,
        uint256 _earlyWithdrawalFee,
        address _dataProvider
    ) public {
        // Initializes default variables
        firstSegmentStart = block.timestamp; //gets current time
        lastSegment = _segmentCount;
        segmentLength = _segmentLength;
        segmentPayment = _segmentPayment;
        earlyWithdrawalFee = _earlyWithdrawalFee;
        daiToken = _inboundCurrency;
        lendingPoolAddressProvider = _lendingPoolAddressProvider;
        AaveProtocolDataProvider dataProvider = AaveProtocolDataProvider(
            _dataProvider
        );
        // lending pool needs to be approved in v2 since it is the core contract in v2 and not lending pool core
        lendingPool = ILendingPool(
            _lendingPoolAddressProvider.getLendingPool()
        );
        // atoken address in v2 is fetched from data provider contract
        (address adaiTokenAddress, , ) = dataProvider.getReserveTokensAddresses(
            address(_inboundCurrency)
        );
        // require(adaiTokenAddress != address(0), "Aave doesn't support _inboundCurrency");
        adaiToken = AToken(adaiTokenAddress);

        // Allows the lending pool to convert DAI deposited on this contract to aDAI on lending pool
        uint256 MAX_ALLOWANCE = 2**256 - 1;
        require(_inboundCurrency.approve(address(lendingPool), MAX_ALLOWANCE), "Fail to approve allowance to lending pool");
    }

    function pause() external onlyOwner whenNotPaused {
        _pause();
    }

    function unpause() external onlyOwner whenPaused {
        _unpause();
    }

    function _transferDaiToContract() internal {
        // users pays dai in to the smart contract, which he pre-approved to spend the DAI for him
        // convert DAI to aDAI using the lending pool
        // this doesn't make sense since we are already transferring
        require(
            daiToken.allowance(msg.sender, address(this)) >= segmentPayment,
            "You need to have allowance to do transfer DAI on the smart contract"
        );

        uint256 currentSegment = getCurrentSegment();

        players[msg.sender].mostRecentSegmentPaid = currentSegment;
        players[msg.sender].amountPaid = players[msg.sender].amountPaid.add(
            segmentPayment
        );
        totalGamePrincipal = totalGamePrincipal.add(segmentPayment);
        segmentDeposit[currentSegment] = segmentDeposit[currentSegment].add(
            segmentPayment
        );
        // SECURITY NOTE:
        // Interacting with the external contracts should be the last action in the logic to avoid re-entracy attacks.
        // Re-entrancy: https://solidity.readthedocs.io/en/v0.6.12/security-considerations.html#re-entrancy
        // Check-Effects-Interactions Pattern: https://solidity.readthedocs.io/en/v0.6.12/security-considerations.html#use-the-checks-effects-interactions-pattern
        require(
            daiToken.transferFrom(msg.sender, address(this), segmentPayment),
            "Transfer failed"
        );
    }

    /**
        Returns the current segment of the game using a 0-based index (returns 0 for the 1st segment ).
        @dev solidity does not return floating point numbers this will always return a whole number
     */
    function getCurrentSegment() public view returns (uint256) {
        return block.timestamp.sub(firstSegmentStart).div(segmentLength);
    }

    function isGameCompleted() public view returns (bool) {
        // Game is completed when the current segment is greater than "lastSegment" of the game.
        return getCurrentSegment() > lastSegment;
    }

    function joinGame() external whenNotPaused {
        require(getCurrentSegment() == 0, "Game has already started");
        require(
            players[msg.sender].addr != msg.sender,
            "Cannot join the game more than once"
        );
        Player memory newPlayer = Player({
            addr: msg.sender,
            mostRecentSegmentPaid: 0,
            amountPaid: 0,
            withdrawn: false
        });
        players[msg.sender] = newPlayer;
        iterablePlayers.push(msg.sender);
        emit JoinedGame(msg.sender, segmentPayment);

        // payment for first segment
        _transferDaiToContract();
    }

    /**
       @dev Allows anyone to deposit the previous segment funds into the underlying protocol.
       Deposits into the protocol can happen at any moment after segment 0 (first deposit window)
       is completed, as long as the game is not completed.
    */
    function depositIntoExternalPool()
        external
        whenNotPaused
        whenGameIsNotCompleted
    {
        uint256 currentSegment = getCurrentSegment();
        require(
            currentSegment > 0,
            "Cannot deposit into underlying protocol during segment zero"
        );
        uint256 amount = segmentDeposit[currentSegment.sub(1)];
        require(
            amount > 0,
            "No amount from previous segment to deposit into protocol"
        );
        // Sets deposited amount for previous segment to 0, avoiding double deposits into the protocol using funds from the current segment
        segmentDeposit[currentSegment.sub(1)] = 0;

        emit FundsDepositedIntoExternalPool(amount);

        lendingPool.deposit(address(daiToken), amount, address(this), 0);
    }

    /**
       @dev Allows player to withdraw funds in the middle of the game with an early withdrawal fee deducted from the user's principal.
       earlyWithdrawalFee is set via constructor
    */
    function earlyWithdraw() external whenNotPaused whenGameIsNotCompleted {
        Player storage player = players[msg.sender];
        // Makes sure player didn't withdraw; otherwise, player could withdraw multiple times.
        require(!player.withdrawn, "Player has already withdrawn");
        // since atokenunderlying has 1:1 ratio so we redeem the amount paid by the player
        player.withdrawn = true;
        // In an early withdraw, users get their principal minus the earlyWithdrawalFee % defined in the constructor.
        // So if earlyWithdrawalFee is 10% and deposit amount is 10 dai, player will get 9 dai back, keeping 1 dai in the pool.
        uint256 withdrawAmount = player.amountPaid.sub(
            player.amountPaid.mul(earlyWithdrawalFee).div(100)
        );
        // Decreases the totalGamePrincipal on earlyWithdraw
        totalGamePrincipal = totalGamePrincipal.sub(withdrawAmount);
        // BUG FIX - Deposit External Pool Tx reverted after an early withdraw
        // Fixed by first checking at what segment early withdraw happens if > 0 then re-assign current segment as -1
        // Since in deposit external pool the amount is calculated from the segmentDeposit mapping
        // and the amount is reduced by withdrawAmount
        uint256 currentSegment = getCurrentSegment();
        if (currentSegment > 0) {
            currentSegment = currentSegment.sub(1);
        }
        if (segmentDeposit[currentSegment] > 0) {
            segmentDeposit[currentSegment] = segmentDeposit[currentSegment].sub(
            withdrawAmount
        );
        }

        uint256 contractBalance = IERC20(daiToken).balanceOf(address(this));

        emit EarlyWithdrawal(msg.sender, withdrawAmount);

        // Only withdraw funds from underlying pool if contract doesn't have enough balance to fulfill the early withdraw.
        // there is no redeem function in v2 it is replaced by withdraw in v2
        if (contractBalance < withdrawAmount) {
            lendingPool.withdraw(
                address(daiToken),
                withdrawAmount.sub(contractBalance),
                address(this)
            );
        }
        require(IERC20(daiToken).transfer(msg.sender, withdrawAmount), "Fail to transfer ERC20 tokens on early withdraw");
    }


    /**
        Reedems funds from external pool and calculates total amount of interest for the game.
        @dev This method only redeems funds from the external pool, without doing any allocation of balances
             to users. This helps to prevent running out of gas and having funds locked into the external pool.
    */
    function redeemFromExternalPool() public whenGameIsCompleted {
        require(!redeemed, "Redeem operation already happened for the game");
        redeemed = true;
        // aave has 1:1 peg for tokens and atokens
        // there is no redeem function in v2 it is replaced by withdraw in v2
        // Aave docs recommends using uint(-1) to withdraw the full balance. This is actually an overflow that results in the max uint256 value.
        lendingPool.withdraw(address(daiToken), uint(-1), address(this));
        uint256 totalBalance = IERC20(daiToken).balanceOf(address(this));
        // recording principal amount separately since adai balance will have interest has well
        totalGameInterest = totalBalance.sub(totalGamePrincipal);

        emit FundsRedeemedFromExternalPool(
            totalBalance,
            totalGamePrincipal,
            totalGameInterest
        );
        emit WinnersAnnouncement(winners);

        if (winners.length == 0) {
            require(IERC20(daiToken).transfer(owner(), totalGameInterest), "Fail to transfer ER20 tokens to owner");
        }
    }

    // to be called by individual players to get the amount back once it is redeemed following the solidity withdraw pattern
    function withdraw() external {
        Player storage player = players[msg.sender];
        require(!player.withdrawn, "Player has already withdrawn");
        player.withdrawn = true;

        uint256 payout = player.amountPaid;
        if (player.mostRecentSegmentPaid == lastSegment.sub(1)) {
            // Player is a winner and gets a bonus!
            // No need to worry about if winners.length = 0
            // If we're in this block then the user is a winner
            // only add interest if there are winners
            if (winners.length > 0) {
                payout = payout.add(totalGameInterest / winners.length);
            }
        }
        emit Withdrawal(msg.sender, payout);

        // First player to withdraw redeems everyone's funds
        if (!redeemed) {
            redeemFromExternalPool();
        }

        require(IERC20(daiToken).transfer(msg.sender, payout), "Fail to transfer ERC20 tokens on withdraw");
    }

    function makeDeposit() external whenNotPaused {
        // only registered players can deposit
        require(
            !players[msg.sender].withdrawn,
            "Player already withdraw from game"
        );
        require(
            players[msg.sender].addr == msg.sender,
            "Sender is not a player"
        );

        uint256 currentSegment = getCurrentSegment();
        // User can only deposit between segment 1 and segmetn n-1 (where n the number of segments for the game).
        // Details:
        // Segment 0 is paid when user joins the game (the first deposit window).
        // Last segment doesn't accept payments, because the payment window for the last
        // segment happens on segment n-1 (penultimate segment).
        // Any segment greather than the last segment means the game is completed, and cannot
        // receive payments
        require(
            currentSegment > 0 && currentSegment < lastSegment,
            "Deposit available only between segment 1 and segment n-1 (penultimate)"
        );

        //check if current segment is currently unpaid
        require(
            players[msg.sender].mostRecentSegmentPaid != currentSegment,
            "Player already paid current segment"
        );

        // check player has made payments up to the previous segment
        require(
            players[msg.sender].mostRecentSegmentPaid == currentSegment.sub(1),
            "Player didn't pay the previous segment - game over!"
        );

        // check if this is deposit for the last segment
        // if so, the user is a winner
        if (currentSegment == lastSegment.sub(1)) {
            winners.push(msg.sender);
        }

        emit Deposit(msg.sender, currentSegment, segmentPayment);

        //:moneybag:allow deposit to happen
        _transferDaiToContract();
    }
}
