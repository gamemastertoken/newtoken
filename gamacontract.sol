// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "@chainlink/contracts/src/v0.8/vrf/VRFV2WrapperConsumerBase.sol";
import "@chainlink/contracts/src/v0.8/automation/AutomationCompatible.sol";

contract GameMasterToken is ERC20, Ownable, ReentrancyGuard, Pausable {

    uint256 public constant FOUNDER_SUPPLY = 20_000 * 10**18;
    uint256 public constant PUBLIC_SUPPLY  = 50_000 * 10**18;
    uint256 public constant RESERVE_SUPPLY = 30_000 * 10**18;

    address public immutable founder;
    address public immutable reserveWallet;
    address public minter;

    uint256 public publicPrice  = 0.01 ether;
    uint256 public publicSold;
    bool    public publicSaleOpen;
    uint256 public totalMinted;

    bool    public tradingEnabled;
    uint256 public maxWalletAmount = 2_000 * 10**18;
    mapping(address => bool)    public isWhitelisted;
    mapping(address => bool)    public proposalTargetWhitelist;
    mapping(address => uint256) public lockedGMT;

    struct Proposal {
        string  description;
        uint256 voteEnd;
        uint256 votesFor;
        uint256 votesAgainst;
        bool    executed;
        address target;
        bytes   callData;
    }
    Proposal[] public proposals;
    mapping(uint256 => mapping(address => bool)) public hasVoted;
    uint256 public proposalThreshold = 100 * 10**18;
    uint256 public votingPeriod      = 7 days;

    error NotMinter();
    error NotAllowed();
    error InvalidParam();
    error InsufficientBalance();
    error InsufficientLocked();
    error SupplyExceeded();
    error ExecutionFailed();
    error InvalidAddress();

    event TokenMinted(address indexed to, uint256 amount);
    event TradingEnabled();
    event PublicSaleOpened();
    event PublicSaleClosed();
    event ProposalCreated(uint256 indexed proposalId, address proposer, string description);
    event VoteCast(uint256 indexed proposalId, address voter, bool support, uint256 weight);
    event ProposalExecuted(uint256 indexed proposalId);
    event MinterSet(address indexed minter);
    event UniswapPoolSet(address indexed pool);
    event GMTLocked(address indexed user, uint256 amount);
    event GMTUnlocked(address indexed user, uint256 amount);
    event PublicPriceUpdated(uint256 newPrice);
    event MaxWalletAmountUpdated(uint256 newAmount);
    event ProposalThresholdUpdated(uint256 newThreshold);
    event VotingPeriodUpdated(uint256 newPeriod);
    event ProposalTargetWhitelisted(address indexed target, bool status);

    modifier onlyMinter() {
        if (msg.sender != minter) revert NotMinter();
        _;
    }

    constructor(address _founder, address _reserveWallet) ERC20("GameMasterToken", "GMT") Ownable() {
        if (_founder == address(0) || _reserveWallet == address(0)) revert InvalidAddress();
        founder       = _founder;
        reserveWallet = _reserveWallet;

        isWhitelisted[_founder]       = true;
        isWhitelisted[_reserveWallet] = true;
        isWhitelisted[address(this)]  = true;

        _mint(_founder, FOUNDER_SUPPLY);
        _mint(_reserveWallet, RESERVE_SUPPLY);
        _mint(address(this), PUBLIC_SUPPLY);
    }

    function setMinter(address _minter) external onlyOwner {
        if (_minter == address(0)) revert InvalidAddress();
        minter = _minter;
        isWhitelisted[_minter] = true;
        emit MinterSet(_minter);
    }

    function mint(address to, uint256 amount) external onlyMinter {
        if (totalMinted + amount > PUBLIC_SUPPLY) revert SupplyExceeded();
        totalMinted += amount;
        _mint(to, amount);
        emit TokenMinted(to, amount);
    }

    function lockGMT(address user) external onlyMinter {
        if (balanceOf(user) - lockedGMT[user] < 1e18) revert InsufficientBalance();
        lockedGMT[user] += 1e18;
        emit GMTLocked(user, 1e18);
    }

    function unlockGMT(address user) external onlyMinter {
        if (lockedGMT[user] < 1e18) revert InsufficientLocked();
        lockedGMT[user] -= 1e18;
        emit GMTUnlocked(user, 1e18);
    }

    function availableGMT(address user) external view returns (uint256) {
        return balanceOf(user) - lockedGMT[user];
    }

    function enableTrading() external onlyOwner {
        tradingEnabled = true;
        emit TradingEnabled();
    }

    function setUniswapPool(address pool) external onlyOwner {
        if (pool == address(0)) revert InvalidAddress();
        isWhitelisted[pool] = true;
        emit UniswapPoolSet(pool);
    }

    function setWhitelisted(address wallet, bool status) external onlyOwner {
        isWhitelisted[wallet] = status;
    }

    function setMaxWalletAmount(uint256 amount) external onlyOwner {
        maxWalletAmount = amount;
        emit MaxWalletAmountUpdated(amount);
    }

    function _transfer(address from, address to, uint256 amount) internal override whenNotPaused {
        if (!tradingEnabled && !isWhitelisted[from] && !isWhitelisted[to]) revert NotAllowed();
        if (!isWhitelisted[to] && balanceOf(to) + amount > maxWalletAmount) revert NotAllowed();
        super._transfer(from, to, amount);
    }

    function openPublicSale() external onlyOwner {
        publicSaleOpen = true;
        emit PublicSaleOpened();
    }

    function closePublicSale() external onlyOwner {
        publicSaleOpen = false;
        emit PublicSaleClosed();
    }

    function buyTokens(uint256 amount) external payable nonReentrant whenNotPaused {
        if (!publicSaleOpen || amount == 0)     revert NotAllowed();
        if (msg.value != publicPrice * amount)   revert InvalidParam();
        if (publicSold + amount > PUBLIC_SUPPLY) revert SupplyExceeded();
        publicSold += amount;
        isWhitelisted[msg.sender] = true;
        super._transfer(address(this), msg.sender, amount);
        isWhitelisted[msg.sender] = false;
        _sendETH(owner(), msg.value);
    }

    function setPublicPrice(uint256 newPrice) external onlyOwner {
        if (newPrice == 0) revert InvalidParam();
        publicPrice = newPrice;
        emit PublicPriceUpdated(newPrice);
    }

    function setProposalTargetWhitelist(address target, bool status) external onlyOwner {
        proposalTargetWhitelist[target] = status;
        emit ProposalTargetWhitelisted(target, status);
    }

    function createProposal(string calldata description, address target, bytes calldata callData) external returns (uint256) {
        if (balanceOf(msg.sender) < proposalThreshold) revert InsufficientBalance();
        if (!proposalTargetWhitelist[target])           revert NotAllowed();
        proposals.push(Proposal({
            description:  description,
            voteEnd:      block.timestamp + votingPeriod,
            votesFor:     0,
            votesAgainst: 0,
            executed:     false,
            target:       target,
            callData:     callData
        }));
        uint256 proposalId = proposals.length - 1;
        emit ProposalCreated(proposalId, msg.sender, description);
        return proposalId;
    }

    function vote(uint256 proposalId, bool support) external {
        Proposal storage p = proposals[proposalId];
        if (block.timestamp >= p.voteEnd)     revert NotAllowed();
        if (hasVoted[proposalId][msg.sender]) revert NotAllowed();
        uint256 weight = balanceOf(msg.sender);
        if (weight == 0) revert InsufficientBalance();
        hasVoted[proposalId][msg.sender] = true;
        if (support) p.votesFor += weight;
        else         p.votesAgainst += weight;
        emit VoteCast(proposalId, msg.sender, support, weight);
    }

    function executeProposal(uint256 proposalId) external nonReentrant {
        Proposal storage p = proposals[proposalId];
        if (block.timestamp < p.voteEnd || p.executed) revert NotAllowed();
        if (p.votesFor <= p.votesAgainst)               revert NotAllowed();
        if (p.votesFor + p.votesAgainst < (FOUNDER_SUPPLY + PUBLIC_SUPPLY + RESERVE_SUPPLY) / 10) revert NotAllowed();
        if (!proposalTargetWhitelist[p.target]) revert NotAllowed();
        p.executed = true;
        (bool success, ) = p.target.call(p.callData);
        if (!success) revert ExecutionFailed();
        emit ProposalExecuted(proposalId);
    }

    function setProposalThreshold(uint256 newThreshold) external onlyOwner {
        if (newThreshold == 0) revert InvalidParam();
        proposalThreshold = newThreshold;
        emit ProposalThresholdUpdated(newThreshold);
    }

    function setVotingPeriod(uint256 newPeriod) external onlyOwner {
        if (newPeriod < 1 days || newPeriod > 30 days) revert InvalidParam();
        votingPeriod = newPeriod;
        emit VotingPeriodUpdated(newPeriod);
    }

    function getProposalCount() external view returns (uint256) {
        return proposals.length;
    }

    function setPaused(bool paused) external onlyOwner {
        paused ? _pause() : _unpause();
    }

    function _sendETH(address to, uint256 amount) internal {
        (bool success, ) = payable(to).call{value: amount}("");
        if (!success) revert ExecutionFailed();
    }

    receive() external payable {}
}

contract CustomTicket is ERC20, ReentrancyGuard, Pausable {

    uint256 public constant PLATFORM_TAX  = 5;
    uint256 public constant FREEZE_PERIOD = 20 minutes;

    address public immutable gameFactory;
    address public immutable creator;
    address public immutable platformWallet;
    GameMasterToken public immutable gameMasterToken;

    uint256 public immutable gameId;
    uint256 public immutable ticketPrice;
    uint256 public immutable maxTickets;
    uint256 public immutable gameEndTime;
    uint256 public immutable prizePoolTax;
    uint256 public immutable gameMasterTax;

    bool    public gameActive;
    bool    public gameCancelled;
    uint256 public ticketsSold;
    uint256 public lastSalePrice;
    uint256 public refundPerTicket;
    uint256 public nextTicketId = 1;

    mapping(uint256 => address)   public ticketOwner;
    mapping(address => uint256[]) public ownedTickets;
    mapping(uint256 => uint256)   public ticketIndex;
    mapping(uint256 => bool)      public ticketHasReported;
    mapping(uint256 => bool)      public ticketHasVotedEarlyEnd;
    mapping(uint256 => bool)      public ticketRefunded;

    struct PricePoint {
        uint256 price;
        uint256 timestamp;
    }
    PricePoint[] public priceHistory;

    struct SellOrder {
        address seller;
        uint256 remainingAmount;
        uint256 pricePerToken;
        bool    isActive;
    }
    SellOrder[] public sellOrders;

    error NotAllowed();
    error InvalidParam();
    error InsufficientTickets();
    error InvalidAddress();
    error SendFailed();

    event TicketBought(address indexed buyer, uint256 ticketId, uint256 price);
    event TicketBurned(uint256 indexed ticketId, address indexed owner);
    event TicketRefunded(uint256 indexed ticketId, address indexed owner, uint256 amount);
    event SellOrderCreated(uint256 indexed orderId, address seller, uint256 amount, uint256 price);
    event SellOrderPartiallyFilled(uint256 indexed orderId, address indexed buyer, uint256 amount, uint256 remaining);
    event SellOrderFilled(uint256 indexed orderId, address indexed buyer, uint256 amount, uint256 totalPrice);
    event SellOrderCancelled(uint256 indexed orderId);
    event GameDeactivated(uint256 timestamp);

    modifier onlyFactory() {
        if (msg.sender != gameFactory) revert NotAllowed();
        _;
    }

    modifier whileActive() {
        if (!gameActive || block.timestamp >= gameEndTime - FREEZE_PERIOD) revert NotAllowed();
        _;
    }

    constructor(
        uint256 _gameId,
        string memory name,
        string memory symbol,
        uint256 _ticketPrice,
        uint256 _maxTickets,
        uint256 _gameEndTime,
        uint256 _prizePoolTax,
        uint256 _gameMasterTax,
        address _creator,
        address _gameMasterToken,
        address _platformWallet
    ) ERC20(name, symbol) {
        if (_gameMasterToken == address(0) || _platformWallet == address(0)) revert InvalidAddress();
        if (_gameEndTime <= FREEZE_PERIOD) revert InvalidParam();
        if (_ticketPrice < 0.001 ether)   revert InvalidParam();
        gameFactory     = msg.sender;
        gameId          = _gameId;
        ticketPrice     = _ticketPrice;
        maxTickets      = _maxTickets;
        gameEndTime     = _gameEndTime;
        prizePoolTax    = _prizePoolTax;
        gameMasterTax   = _gameMasterTax;
        creator         = _creator;
        platformWallet  = _platformWallet;
        gameMasterToken = GameMasterToken(payable(_gameMasterToken));
        gameActive      = true;
        lastSalePrice   = _ticketPrice;
    }

    receive() external payable {}

    function _sendETH(address to, uint256 amount) internal {
        (bool ok, ) = payable(to).call{value: amount}("");
        if (!ok) revert SendFailed();
    }

    function _assignTicket(address to) internal returns (uint256) {
        uint256 id      = nextTicketId++;
        ticketOwner[id] = to;
        ticketIndex[id] = ownedTickets[to].length;
        ownedTickets[to].push(id);
        return id;
    }

    function _moveTicket(uint256 id, address from, address to) internal {
        uint256[] storage fromT = ownedTickets[from];
        uint256 idx             = ticketIndex[id];
        uint256 lastId          = fromT[fromT.length - 1];
        fromT[idx]              = lastId;
        ticketIndex[lastId]     = idx;
        fromT.pop();
        ticketIndex[id]         = ownedTickets[to].length;
        ownedTickets[to].push(id);
        ticketOwner[id]         = to;
    }

    function _transfer(address from, address to, uint256 amount) internal override {
        if (from != address(this) && to != address(this) && gameCancelled) revert NotAllowed();
        super._transfer(from, to, amount);
    }

    function _distributeTaxes(uint256 total, address seller) internal {
        uint256 platform = (total * PLATFORM_TAX)  / 1000;
        uint256 gmaster  = (total * gameMasterTax) / 100;
        uint256 toSeller = total - platform - (total * prizePoolTax / 100) - gmaster;
        if (platform > 0) _sendETH(platformWallet, platform);
        if (gmaster  > 0) _sendETH(creator, gmaster);
        if (toSeller > 0) _sendETH(seller, toSeller);
    }

    function buyPrimary(address buyer) external payable onlyFactory whileActive nonReentrant {
        if (msg.value != ticketPrice || ticketsSold >= maxTickets) revert InvalidParam();
        uint256 gmAmount = (msg.value * gameMasterTax) / 100;
        if (gmAmount > 0) _sendETH(creator, gmAmount);
        uint256 id = _assignTicket(buyer);
        unchecked { ++ticketsSold; }
        _mint(buyer, 1e18);
        _approve(buyer, gameFactory, type(uint256).max);
        emit TicketBought(buyer, id, msg.value);
    }

    function createSellOrder(uint256 amount, uint256 pricePerToken) external whileActive whenNotPaused nonReentrant {
        if (amount == 0 || pricePerToken == 0) revert InvalidParam();
        if (balanceOf(msg.sender) < amount || ownedTickets[msg.sender].length < amount) revert InsufficientTickets();
        _transfer(msg.sender, address(this), amount);
        for (uint256 i = 0; i < amount;) {
            _moveTicket(ownedTickets[msg.sender][0], msg.sender, address(this));
            unchecked { ++i; }
        }
        sellOrders.push(SellOrder(msg.sender, amount, pricePerToken, true));
        emit SellOrderCreated(sellOrders.length - 1, msg.sender, amount, pricePerToken);
    }

    function fillSellOrder(uint256 orderId, uint256 amountToBuy) external payable whileActive whenNotPaused nonReentrant {
        SellOrder storage order = sellOrders[orderId];
        if (!order.isActive)                                         revert NotAllowed();
        if (order.seller == msg.sender)                              revert NotAllowed();
        if (amountToBuy == 0 || amountToBuy > order.remainingAmount) revert InvalidParam();
        if (msg.value != order.pricePerToken * amountToBuy)          revert InvalidParam();

        order.remainingAmount -= amountToBuy;
        if (order.remainingAmount == 0) order.isActive = false;

        priceHistory.push(PricePoint(order.pricePerToken, block.timestamp));
        lastSalePrice = order.pricePerToken;

        _distributeTaxes(msg.value, order.seller);

        _transfer(address(this), msg.sender, amountToBuy);
        for (uint256 i = 0; i < amountToBuy;) {
            _moveTicket(ownedTickets[address(this)][0], address(this), msg.sender);
            unchecked { ++i; }
        }
        _approve(msg.sender, gameFactory, type(uint256).max);

        if (order.remainingAmount == 0) emit SellOrderFilled(orderId, msg.sender, amountToBuy, msg.value);
        else emit SellOrderPartiallyFilled(orderId, msg.sender, amountToBuy, order.remainingAmount);
    }

    function cancelSellOrder(uint256 orderId) external nonReentrant {
        SellOrder storage order = sellOrders[orderId];
        if (order.seller != msg.sender || !order.isActive) revert NotAllowed();
        uint256 remaining     = order.remainingAmount;
        order.isActive        = false;
        order.remainingAmount = 0;
        _transfer(address(this), msg.sender, remaining);
        for (uint256 i = 0; i < remaining;) {
            _moveTicket(ownedTickets[address(this)][0], address(this), msg.sender);
            unchecked { ++i; }
        }
        emit SellOrderCancelled(orderId);
    }

    function setGameInactive(bool cancelled) external onlyFactory {
        gameActive    = false;
        gameCancelled = cancelled;

        uint256 len = sellOrders.length;
        for (uint256 i = 0; i < len;) {
            SellOrder storage o = sellOrders[i];
            if (o.isActive) {
                uint256 rem       = o.remainingAmount;
                o.isActive        = false;
                o.remainingAmount = 0;
                if (rem > 0) {
                    super._transfer(address(this), o.seller, rem);
                    for (uint256 j = 0; j < rem;) {
                        _moveTicket(ownedTickets[address(this)][0], address(this), o.seller);
                        unchecked { ++j; }
                    }
                }
                emit SellOrderCancelled(i);
            }
            unchecked { ++i; }
        }

        if (cancelled && ticketsSold > 0) {
            refundPerTicket = address(this).balance / ticketsSold;
        }

        emit GameDeactivated(block.timestamp);
    }

    function _burnTicketInternal(uint256 ticketId, address owner) internal {
        ticketOwner[ticketId]   = address(0);
        uint256[] storage myT   = ownedTickets[owner];
        uint256 idx             = ticketIndex[ticketId];
        uint256 lastId          = myT[myT.length - 1];
        myT[idx]                = lastId;
        ticketIndex[lastId]     = idx;
        myT.pop();
        _burn(owner, 1e18);
        emit TicketBurned(ticketId, owner);
    }

    function claimRefund(uint256 ticketId) external nonReentrant {
        if (!gameCancelled)                      revert NotAllowed();
        if (ticketOwner[ticketId] != msg.sender) revert NotAllowed();
        if (ticketRefunded[ticketId])            revert NotAllowed();
        if (refundPerTicket == 0)                revert InvalidParam();
        ticketRefunded[ticketId] = true;
        _burnTicketInternal(ticketId, msg.sender);
        _sendETH(msg.sender, refundPerTicket);
        emit TicketRefunded(ticketId, msg.sender, refundPerTicket);
    }

    function burnMyTicket(uint256 ticketId) external nonReentrant {
        if (ticketOwner[ticketId] != msg.sender) revert NotAllowed();
        if (gameActive)                          revert NotAllowed();
        _burnTicketInternal(ticketId, msg.sender);
    }

    function recoverDust(address payable to) external onlyFactory nonReentrant {
        if (gameActive) revert NotAllowed();
        uint256 dust = address(this).balance;
        if (dust == 0) revert InvalidParam();
        _sendETH(to, dust);
    }

    function withdrawPrize(address payable winner) external onlyFactory nonReentrant {
        uint256 prize = address(this).balance;
        if (prize == 0) revert InvalidParam();
        _sendETH(winner, prize);
    }

    function setPaused(bool paused) external onlyFactory {
        paused ? _pause() : _unpause();
    }

    function getFirstTicketId(address wallet) external view returns (uint256) {
        if (ownedTickets[wallet].length == 0) revert InsufficientTickets();
        return ownedTickets[wallet][0];
    }

    function getOwnedTickets(address wallet) external view returns (uint256[] memory) {
        return ownedTickets[wallet];
    }

    function getTicketOwners(uint256 fromId, uint256 toId) external view returns (
        uint256[] memory ids,
        address[] memory owners
    ) {
        if (fromId < 1 || toId >= nextTicketId || fromId > toId || toId - fromId > 1000) revert InvalidParam();
        uint256 count = toId - fromId + 1;
        ids    = new uint256[](count);
        owners = new address[](count);
        for (uint256 i = 0; i < count;) {
            ids[i]    = fromId + i;
            owners[i] = ticketOwner[fromId + i];
            unchecked { ++i; }
        }
    }

    function isTicketForSale(uint256 ticketId) external view returns (bool forSale, uint256 price) {
        if (ticketOwner[ticketId] != address(this)) return (false, 0);
        uint256 len = sellOrders.length;
        for (uint256 i = 0; i < len;) {
            SellOrder storage o = sellOrders[i];
            if (o.isActive && o.remainingAmount > 0) return (true, o.pricePerToken);
            unchecked { ++i; }
        }
        return (false, 0);
    }

    function markTicketReported(uint256 ticketId)      external onlyFactory { ticketHasReported[ticketId]      = true; }
    function markTicketVotedEarlyEnd(uint256 ticketId) external onlyFactory { ticketHasVotedEarlyEnd[ticketId] = true; }

    function getActiveSellOrders() external view returns (
        uint256[] memory ids,
        address[] memory sellers,
        uint256[] memory amounts,
        uint256[] memory prices
    ) {
        uint256 len   = sellOrders.length;
        uint256 count = 0;
        for (uint256 i = 0; i < len;) {
            if (sellOrders[i].isActive) {
                unchecked { ++count; }
            }
            unchecked { ++i; }
        }
        ids     = new uint256[](count);
        sellers = new address[](count);
        amounts = new uint256[](count);
        prices  = new uint256[](count);
        uint256 idx = 0;
        for (uint256 i = 0; i < len;) {
            if (sellOrders[i].isActive) {
                ids[idx]     = i;
                sellers[idx] = sellOrders[i].seller;
                amounts[idx] = sellOrders[i].remainingAmount;
                prices[idx]  = sellOrders[i].pricePerToken;
                unchecked { ++idx; }
            }
            unchecked { ++i; }
        }
    }

    function getPriceHistory()  external view returns (PricePoint[] memory) { return priceHistory; }
    function getPrizePool()     external view returns (uint256) { return address(this).balance; }
    function getLastPrice()     external view returns (uint256) { return lastSalePrice; }
    function isInFreezePeriod() external view returns (bool)    { return block.timestamp >= gameEndTime - FREEZE_PERIOD; }

    function getTimeUntilFreeze() external view returns (uint256) {
        uint256 freeze = gameEndTime - FREEZE_PERIOD;
        return block.timestamp >= freeze ? 0 : freeze - block.timestamp;
    }
}

contract GameFactory is VRFV2WrapperConsumerBase, AutomationCompatibleInterface, Ownable, ReentrancyGuard, Pausable {
    using Strings for uint256;

    GameMasterToken public immutable gameMasterToken;
    address public platformWallet;
    uint256 public gameMasterTokenPrice = 0.1 ether;

    struct Game {
        address creator;
        uint256 endTime;
        uint256 ticketPrice;
        uint256 maxTickets;
        uint256 prizePoolTax;
        uint256 gameMasterTax;
        address ticketToken;
        bool    isActive;
        bool    isEarlyEnded;
        bool    almostOverNotified;
    }

    Game[] public games;

    uint256[] public activeGameIds;
    mapping(uint256 => uint256) public activeGameIndex;
    mapping(uint256 => bool)    public isActiveGame;

    struct GameMasterReputation {
        uint256 gamesCompleted;
        uint256 gamesCancelled;
        uint256 blockedUntil;
    }
    mapping(address => GameMasterReputation) public reputation;

    uint256 public constant MIN_GAMES_FOR_SCORE = 3;
    uint256 public constant MIN_SCORE_X100      = 200;
    uint256 public constant BLOCK_DURATION      = 30 days;
    uint256 public constant ALMOST_OVER_DELAY   = 1 hours;

    mapping(address => bool)    public bannedWallets;
    mapping(uint256 => uint256) public gameReports;
    mapping(address => uint256) public banVotes;
    mapping(uint256 => uint256) public earlyEndVotes;
    mapping(address => mapping(address => bool)) public hasVotedBan;
    mapping(uint256 => bool)    public drawPending;

    uint256 public reportThresholdPct   = 20;
    uint256 public earlyEndThresholdPct = 20;
    uint256 public banThresholdPct      = 20;

    uint32 public callbackGasLimit     = 100_000;
    uint16 public requestConfirmations = 3;
    mapping(uint256 => uint256) public requestToGameId;
    mapping(uint256 => bool)    public requestExists;
    mapping(uint256 => uint256) public vrfRequestTime;
    uint256 public vrfTimeout = 24 hours;

    error NotAllowed();
    error InvalidParam();
    error InvalidAddress();
    error InsufficientGMT();
    error SendFailed();

    event GMTMinted(address indexed buyer, uint256 amount);
    event GameCreated(uint256 indexed gameId, address indexed creator, address ticketToken);
    event TicketBought(uint256 indexed gameId, address buyer);
    event WinnerDrawn(uint256 indexed gameId, address winner, uint256 prize);
    event WalletBanned(address indexed wallet, address bannedBy);
    event GameReported(uint256 indexed gameId, uint256 count, uint256 threshold);
    event GameEndedEarly(uint256 indexed gameId);
    event GameAlmostOver(uint256 indexed gameId, uint256 endTime);
    event GMTPriceUpdated(uint256 newPrice);
    event PlatformWalletUpdated(address newWallet);

    modifier notBanned() {
        if (bannedWallets[msg.sender]) revert NotAllowed();
        _;
    }

    constructor(
        address _linkToken,
        address _vrfWrapper,
        address _platformWallet,
        address _reserveWallet
    )
        VRFV2WrapperConsumerBase(_linkToken, _vrfWrapper)
        Ownable()
    {
        if (_platformWallet == address(0)) revert InvalidAddress();
        platformWallet  = _platformWallet;
        gameMasterToken = new GameMasterToken(msg.sender, _reserveWallet);
        gameMasterToken.setMinter(address(this));
    }

    function _getTicket(uint256 gameId) internal view returns (CustomTicket) {
        return CustomTicket(payable(games[gameId].ticketToken));
    }

    function _addActiveGame(uint256 gameId) internal {
        if (isActiveGame[gameId]) return;
        isActiveGame[gameId]    = true;
        activeGameIndex[gameId] = activeGameIds.length;
        activeGameIds.push(gameId);
    }

    function _removeActiveGame(uint256 gameId) internal {
        if (!isActiveGame[gameId]) return;
        isActiveGame[gameId]    = false;
        uint256 idx             = activeGameIndex[gameId];
        uint256 lastId          = activeGameIds[activeGameIds.length - 1];
        activeGameIds[idx]      = lastId;
        activeGameIndex[lastId] = idx;
        activeGameIds.pop();
    }

    function _sendETH(address to, uint256 amount) internal {
        (bool success, ) = payable(to).call{value: amount}("");
        if (!success) revert SendFailed();
    }

    function buyGMT(uint256 amount) external payable notBanned nonReentrant whenNotPaused {
        if (amount == 0 || msg.value != gameMasterTokenPrice * amount) revert InvalidParam();
        gameMasterToken.mint(msg.sender, amount);
        _sendETH(platformWallet, msg.value);
        emit GMTMinted(msg.sender, amount);
    }

    function setGMTPrice(uint256 newPrice) external onlyOwner {
        if (newPrice == 0) revert InvalidParam();
        gameMasterTokenPrice = newPrice;
        emit GMTPriceUpdated(newPrice);
    }

    function _updateReputation(address gameMaster, bool completed) internal {
        GameMasterReputation storage rep = reputation[gameMaster];
        if (completed) {
            unchecked { ++rep.gamesCompleted; }
        } else {
            unchecked { ++rep.gamesCancelled; }
        }
        uint256 total = rep.gamesCompleted + rep.gamesCancelled;
        if (total >= MIN_GAMES_FOR_SCORE) {
            uint256 score = (rep.gamesCompleted * 500) / total;
            if (score < MIN_SCORE_X100) {
                rep.blockedUntil = block.timestamp + BLOCK_DURATION;
            }
        }
    }

    function createGame(
        uint256 _duration,
        uint256 _ticketPrice,
        uint256 _maxTickets,
        uint256 _prizePoolTax,
        uint256 _gameMasterTax
    ) external notBanned nonReentrant whenNotPaused {
        if (gameMasterToken.availableGMT(msg.sender) < 1e18)       revert InsufficientGMT();
        if (_maxTickets == 0 || _maxTickets > 1_000_000)           revert InvalidParam();
        if (_duration == 0 || _duration > 604800)                  revert InvalidParam();
        if (_ticketPrice < 0.001 ether)                            revert InvalidParam();
        if (_prizePoolTax + _gameMasterTax > 49)                   revert InvalidParam();
        if (block.timestamp < reputation[msg.sender].blockedUntil) revert NotAllowed();

        gameMasterToken.lockGMT(msg.sender);

        uint256 gameId  = games.length;
        uint256 endTime = block.timestamp + _duration;

        CustomTicket newTicket = new CustomTicket(
            gameId,
            string(abi.encodePacked("Game", gameId.toString(), "Ticket")),
            string(abi.encodePacked("GT", gameId.toString())),
            _ticketPrice,
            _maxTickets,
            endTime,
            _prizePoolTax,
            _gameMasterTax,
            msg.sender,
            address(gameMasterToken),
            platformWallet
        );

        games.push(Game({
            creator:            msg.sender,
            endTime:            endTime,
            ticketPrice:        _ticketPrice,
            maxTickets:         _maxTickets,
            prizePoolTax:       _prizePoolTax,
            gameMasterTax:      _gameMasterTax,
            ticketToken:        address(newTicket),
            isActive:           true,
            isEarlyEnded:       false,
            almostOverNotified: false
        }));

        _addActiveGame(gameId);
        emit GameCreated(gameId, msg.sender, address(newTicket));
    }

    function buyTicket(uint256 gameId) external payable notBanned nonReentrant whenNotPaused {
        Game storage game = games[gameId];
        if (!game.isActive || game.isEarlyEnded) revert NotAllowed();
        if (block.timestamp >= game.endTime)     revert NotAllowed();
        if (msg.value != game.ticketPrice)       revert InvalidParam();
        _getTicket(gameId).buyPrimary{value: msg.value}(msg.sender);
        emit TicketBought(gameId, msg.sender);
    }

    function checkUpkeep(bytes calldata) external view override returns (bool upkeepNeeded, bytes memory performData) {
        uint256 len = activeGameIds.length;
        for (uint256 i = 0; i < len;) {
            uint256 gameId = activeGameIds[i];
            Game storage g = games[gameId];
            if (!g.almostOverNotified && block.timestamp >= g.endTime - ALMOST_OVER_DELAY) {
                return (true, abi.encode(gameId));
            }
            unchecked { ++i; }
        }
        return (false, "");
    }

    function performUpkeep(bytes calldata performData) external override {
        uint256 gameId = abi.decode(performData, (uint256));
        Game storage g = games[gameId];
        if (!g.isActive || g.almostOverNotified)              revert NotAllowed();
        if (block.timestamp < g.endTime - ALMOST_OVER_DELAY) revert NotAllowed();
        g.almostOverNotified = true;
        emit GameAlmostOver(gameId, g.endTime);
    }

    function drawWinner(uint256 gameId) external notBanned nonReentrant whenNotPaused {
        Game storage game = games[gameId];
        if (block.timestamp < game.endTime)        revert NotAllowed();
        if (!game.isActive || game.isEarlyEnded)   revert NotAllowed();
        if (drawPending[gameId])                   revert NotAllowed();
        if (_getTicket(gameId).ticketsSold() == 0) revert InvalidParam();
        drawPending[gameId]        = true;
        uint256 requestId          = requestRandomness(callbackGasLimit, requestConfirmations, 1);
        requestToGameId[requestId] = gameId;
        requestExists[requestId]   = true;
        vrfRequestTime[gameId]     = block.timestamp;
    }

    function fulfillRandomWords(uint256 requestId, uint256[] memory randomWords) internal override {
        if (!requestExists[requestId]) return;
        uint256 gameId      = requestToGameId[requestId];
        CustomTicket ticket = _getTicket(gameId);
        uint256 sold        = ticket.ticketsSold();
        if (sold == 0) return;

        address winner   = address(0);
        uint256 attempts = 0;
        while (winner == address(0) || winner == address(ticket)) {
            uint256 id = ((randomWords[0] + attempts) % sold) + 1;
            winner     = ticket.ticketOwner(id);
            unchecked { ++attempts; }
            if (attempts > sold) break;
        }
        if (winner == address(0) || winner == address(ticket)) return;

        address creator        = games[gameId].creator;
        games[gameId].isActive = false;
        drawPending[gameId]    = false;
        _removeActiveGame(gameId);
        _updateReputation(creator, true);

        ticket.setGameInactive(false);
        gameMasterToken.unlockGMT(creator);
        uint256 prize = ticket.getPrizePool();
        if (prize > 0) ticket.withdrawPrize(payable(winner));

        emit WinnerDrawn(gameId, winner, prize);
    }

    function emergencyRefund(uint256 gameId) external notBanned nonReentrant {
        if (vrfRequestTime[gameId] == 0)                            revert InvalidParam();
        if (block.timestamp <= vrfRequestTime[gameId] + vrfTimeout) revert NotAllowed();
        if (_getTicket(gameId).getPrizePool() == 0)                 revert InvalidParam();

        address creator        = games[gameId].creator;
        games[gameId].isActive = false;
        drawPending[gameId]    = false;
        _removeActiveGame(gameId);
        _updateReputation(creator, false);

        _getTicket(gameId).setGameInactive(true);
        gameMasterToken.unlockGMT(creator);
    }

    function reportGame(uint256 gameId) external notBanned {
        Game storage game = games[gameId];
        if (!game.isActive)                                revert NotAllowed();
        if (drawPending[gameId])                           revert NotAllowed();
        if (block.timestamp >= game.endTime - 20 minutes) revert NotAllowed();

        CustomTicket ticket = _getTicket(gameId);
        uint256 ticketId    = ticket.getFirstTicketId(msg.sender);
        if (ticket.ticketHasReported(ticketId)) revert NotAllowed();
        ticket.markTicketReported(ticketId);
        unchecked { ++gameReports[gameId]; }
        uint256 threshold = _threshold(ticket.ticketsSold(), reportThresholdPct);
        if (gameReports[gameId] >= threshold) {
            address creator        = game.creator;
            games[gameId].isActive = false;
            _removeActiveGame(gameId);
            _updateReputation(creator, false);
            ticket.setGameInactive(true);
            gameMasterToken.unlockGMT(creator);
        }
        emit GameReported(gameId, gameReports[gameId], threshold);
    }

    function voteEarlyEnd(uint256 gameId) external notBanned {
        Game storage game = games[gameId];
        if (!game.isActive)      revert NotAllowed();
        if (drawPending[gameId]) revert NotAllowed();

        CustomTicket ticket = _getTicket(gameId);
        uint256 ticketId    = ticket.getFirstTicketId(msg.sender);
        if (ticket.ticketHasVotedEarlyEnd(ticketId)) revert NotAllowed();
        ticket.markTicketVotedEarlyEnd(ticketId);
        unchecked { ++earlyEndVotes[gameId]; }
        uint256 threshold = _threshold(ticket.ticketsSold(), earlyEndThresholdPct);
        if (earlyEndVotes[gameId] >= threshold) {
            address creator            = game.creator;
            games[gameId].isActive     = false;
            games[gameId].isEarlyEnded = true;
            _removeActiveGame(gameId);
            _updateReputation(creator, false);
            ticket.setGameInactive(true);
            gameMasterToken.unlockGMT(creator);
            emit GameEndedEarly(gameId);
        }
    }

    function voteBanWallet(address wallet) external notBanned {
        if (hasVotedBan[wallet][msg.sender])            revert NotAllowed();
        if (gameMasterToken.balanceOf(msg.sender) == 0) revert InsufficientGMT();
        hasVotedBan[wallet][msg.sender] = true;
        unchecked { ++banVotes[wallet]; }
        uint256 threshold = _threshold(gameMasterToken.totalSupply() / 1e18, banThresholdPct);
        if (threshold > 1000) threshold = 1000;
        if (banVotes[wallet] >= threshold) {
            bannedWallets[wallet] = true;
            emit WalletBanned(wallet, msg.sender);
        }
    }

    function _threshold(uint256 total, uint256 pct) internal pure returns (uint256 t) {
        t = (total * pct) / 100;
        if (t == 0) t = 1;
    }

    function banWallet(address wallet)   external onlyOwner { bannedWallets[wallet] = true;  emit WalletBanned(wallet, msg.sender); }
    function unbanWallet(address wallet) external onlyOwner { bannedWallets[wallet] = false; }

    function recoverDust(uint256 gameId) external onlyOwner nonReentrant {
        _getTicket(gameId).recoverDust(payable(platformWallet));
    }

    function withdrawStuckETH() external onlyOwner nonReentrant {
        uint256 bal = address(this).balance;
        if (bal == 0) revert InvalidParam();
        _sendETH(platformWallet, bal);
    }

    function getActiveGames() external view returns (uint256[] memory) { return activeGameIds; }

    function setThreshold(uint8 kind, uint256 pct) external onlyOwner {
        if (pct == 0 || pct > 100) revert InvalidParam();
        if (kind == 0)      reportThresholdPct   = pct;
        else if (kind == 1) earlyEndThresholdPct = pct;
        else                banThresholdPct      = pct;
    }

    function setPlatformWallet(address newWallet) external onlyOwner {
        if (newWallet == address(0)) revert InvalidAddress();
        platformWallet = newWallet;
        emit PlatformWalletUpdated(newWallet);
    }

    function setCallbackGasLimit(uint32 gasLimit) external onlyOwner { callbackGasLimit = gasLimit; }
    function setVrfTimeout(uint256 newTimeout)    external onlyOwner { vrfTimeout = newTimeout; }
    function setPaused(bool paused)               external onlyOwner { paused ? _pause() : _unpause(); }

    receive() external payable {}
}
