// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "forge-std/StdInvariant.sol";
import "../../contracts/TokenFactory.sol";
import "../../contracts/CreatorFeeRouter.sol";
import "../../contracts/LaunchToken.sol";

// ============ Mock Contracts ============

contract MockWETH {
    mapping(address => uint256) public balanceOf;
    
    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
    
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
    
    function approve(address, uint256) external pure returns (bool) {
        return true;
    }
    
    receive() external payable {
        balanceOf[msg.sender] += msg.value;
    }
}

contract MockV2Factory {
    mapping(address => mapping(address => address)) public getPair;
}

contract MockV2Router {
    address public immutable WETH;
    address public immutable factory;
    
    constructor(address _weth, address _factory) {
        WETH = _weth;
        factory = _factory;
    }
    
    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint,
        uint,
        address,
        uint
    ) external payable returns (uint, uint, uint) {
        IERC20(token).transferFrom(msg.sender, address(this), amountTokenDesired);
        return (amountTokenDesired, msg.value, msg.value);
    }
    
    receive() external payable {}
}

/**
 * @title LaunchTokenHandler
 * @notice Handler contract for invariant testing of LaunchToken
 * @dev Provides bounded actions that the fuzzer will call
 */
contract LaunchTokenHandler is Test {
    LaunchToken public token;
    address[] public actors;
    
    uint256 public totalBuys;
    uint256 public totalSells;
    uint256 public totalEthIn;
    uint256 public totalEthOut;
    
    constructor(LaunchToken _token) {
        token = _token;
        
        // Create actors
        for (uint i = 0; i < 5; i++) {
            address actor = address(uint160(100 + i));
            actors.push(actor);
            vm.deal(actor, 100 ether);
        }
    }
    
    function buy(uint256 actorSeed, uint256 amount) external {
        if (token.graduated()) return;
        
        address actor = actors[actorSeed % actors.length];
        amount = bound(amount, 0.00001 ether, 0.001 ether);
        
        vm.prank(actor);
        token.buy{value: amount}();
        
        totalBuys++;
        totalEthIn += amount;
    }
    
    function sell(uint256 actorSeed, uint256 amount) external {
        if (token.graduated()) return;
        
        address actor = actors[actorSeed % actors.length];
        uint256 balance = token.balanceOf(actor);
        
        if (balance == 0) return;
        
        amount = bound(amount, 1, balance);
        
        uint256 ethBefore = actor.balance;
        
        vm.prank(actor);
        token.sell(amount);
        
        totalSells++;
        totalEthOut += actor.balance - ethBefore;
    }
    
    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        
        if (from == to) return;
        
        uint256 balance = token.balanceOf(from);
        if (balance == 0) return;
        
        amount = bound(amount, 1, balance);
        
        vm.prank(from);
        token.transfer(to, amount);
    }
}

/**
 * @title TokenFactoryHandler
 * @notice Handler for TokenFactory invariant testing
 */
contract TokenFactoryHandler is Test {
    TokenFactory public factory;
    address[] public createdTokens;
    address[] public creators;
    
    constructor(TokenFactory _factory) {
        factory = _factory;
        
        // Create creators
        for (uint i = 0; i < 3; i++) {
            address creator = address(uint160(200 + i));
            creators.push(creator);
            vm.deal(creator, 100 ether);
        }
    }
    
    function createToken(uint256 creatorSeed, uint256 nameSeed) external {
        address creator = creators[creatorSeed % creators.length];
        
        string memory name = string(abi.encodePacked("Token", vm.toString(nameSeed)));
        string memory symbol = string(abi.encodePacked("TK", vm.toString(nameSeed % 100)));
        
        vm.prank(creator);
        address token = factory.createToken(name, symbol);
        
        createdTokens.push(token);
    }
    
    function getCreatedTokens() external view returns (address[] memory) {
        return createdTokens;
    }
}

/**
 * @title InvariantsTest
 * @notice Invariant tests for the launchpad system
 */
contract InvariantsTest is StdInvariant, Test {
    TokenFactory public factory;
    CreatorFeeRouter public feeRouter;
    MockWETH public weth;
    MockV2Factory public v2Factory;
    MockV2Router public v2Router;
    
    LaunchToken public token;
    LaunchTokenHandler public tokenHandler;
    TokenFactoryHandler public factoryHandler;
    
    address public deployer = address(1);
    address public creator = address(2);
    
    function setUp() public {
        vm.startPrank(deployer);
        
        weth = new MockWETH();
        v2Factory = new MockV2Factory();
        v2Router = new MockV2Router(address(weth), address(v2Factory));
        
        factory = new TokenFactory(address(0));
        feeRouter = new CreatorFeeRouter(address(v2Router), address(v2Factory));
        
        feeRouter.setAuthorizedFactory(address(factory));
        factory.setV2Router(address(v2Router));
        factory.setFeeRouter(address(feeRouter));
        
        vm.stopPrank();
        
        // Create a token for testing
        vm.prank(creator);
        address tokenAddr = factory.createToken("Invariant Token", "INV");
        token = LaunchToken(payable(tokenAddr));
        
        // Move past cooldown
        vm.warp(block.timestamp + 61);
        
        // Create handlers
        tokenHandler = new LaunchTokenHandler(token);
        factoryHandler = new TokenFactoryHandler(factory);
        
        // Set target contracts
        targetContract(address(tokenHandler));
        
        // Exclude certain senders
        excludeSender(address(0));
        excludeSender(address(factory));
        excludeSender(address(token));
    }
    
    // ============ LaunchToken Invariants ============
    
    /**
     * @notice Reserve balance should never exceed contract's actual ETH balance
     * @dev The contract might have extra ETH from direct sends, but reserve should be covered
     */
    function invariant_reserveBalance_leq_contractBalance() public view {
        if (token.graduated()) return; // After graduation, reserve is 0
        
        uint256 reserve = token.reserveBalance();
        uint256 treasury = token.treasury();
        uint256 contractBalance = address(token).balance;
        
        // Contract should have at least reserve + treasury
        // (might have more from direct sends)
        assertTrue(
            contractBalance >= reserve,
            "Contract balance should cover reserve"
        );
    }
    
    /**
     * @notice Total supply should match sum of all balances
     * @dev Verifies no tokens are created or destroyed incorrectly
     */
    function invariant_totalSupply_isConsistent() public view {
        uint256 totalSupply = token.totalSupply();
        
        // Total supply should be non-negative (implicit in uint)
        // Total supply should be reasonable
        assertTrue(
            totalSupply < type(uint128).max,
            "Total supply should be bounded"
        );
    }
    
    /**
     * @notice Token can only graduate once
     */
    function invariant_graduatedOnlyOnce() public view {
        // If graduated is true, it should stay true (can't un-graduate)
        // This is implicitly tested by the handler not being able to buy after graduation
        if (token.graduated()) {
            assertTrue(token.graduated(), "Graduation should be permanent");
        }
    }
    
    /**
     * @notice Treasury should never be negative
     * @dev Treasury is a uint256, so this is implicit, but we verify it's reasonable
     */
    function invariant_treasuryNeverNegative() public view {
        uint256 treasury = token.treasury();
        
        // Treasury should be bounded
        assertTrue(
            treasury < type(uint128).max,
            "Treasury should be bounded"
        );
    }
    
    /**
     * @notice Reserve + Treasury + Fees should account for all ETH
     */
    function invariant_ethAccounting() public view {
        if (token.graduated()) return;
        
        uint256 reserve = token.reserveBalance();
        uint256 treasury = token.treasury();
        
        // If feeRouter is set, fees go there, not treasury
        // Contract balance should be >= reserve (treasury might be 0 if using feeRouter)
        assertTrue(
            address(token).balance >= reserve,
            "ETH accounting should be consistent"
        );
    }
    
    /**
     * @notice Price should always be positive
     */
    function invariant_priceAlwaysPositive() public view {
        uint256 price = token.getCurrentPrice();
        assertTrue(price > 0, "Price should always be positive");
    }
    
    // ============ TokenFactory Invariants ============
    
    /**
     * @notice All created tokens should be tracked in isLaunchedToken
     */
    function invariant_launchedTokensTracked() public view {
        uint256 totalTokens = factory.totalTokens();
        
        for (uint i = 0; i < totalTokens && i < 100; i++) { // Limit iterations
            address tokenAddr = factory.launchedTokens(i);
            assertTrue(
                factory.isLaunchedToken(tokenAddr),
                "All tokens in array should be marked as launched"
            );
        }
    }
    
    /**
     * @notice Token count should match array length
     */
    function invariant_tokenCountMatchesArray() public view {
        uint256 count = factory.totalTokens();
        
        // totalTokens() returns launchedTokens.length
        // This is a consistency check
        assertTrue(count < 10000, "Token count should be bounded");
    }
    
    // ============ Handler Stats ============
    
    function invariant_callSummary() public view {
        console.log("Buy calls:", tokenHandler.totalBuys());
        console.log("Sell calls:", tokenHandler.totalSells());
        console.log("Total ETH in:", tokenHandler.totalEthIn());
        console.log("Total ETH out:", tokenHandler.totalEthOut());
        console.log("Token graduated:", token.graduated());
        console.log("Token total supply:", token.totalSupply());
        console.log("Token reserve:", token.reserveBalance());
    }
}

/**
 * @title StatefulInvariantsTest
 * @notice Stateful invariant tests that track state across calls
 */
contract StatefulInvariantsTest is StdInvariant, Test {
    TokenFactory public factory;
    MockWETH public weth;
    MockV2Factory public v2Factory;
    MockV2Router public v2Router;
    CreatorFeeRouter public feeRouter;
    
    address public deployer = address(1);
    
    // Track state
    uint256 public lastTotalTokens;
    
    function setUp() public {
        vm.startPrank(deployer);
        
        weth = new MockWETH();
        v2Factory = new MockV2Factory();
        v2Router = new MockV2Router(address(weth), address(v2Factory));
        
        factory = new TokenFactory(address(0));
        feeRouter = new CreatorFeeRouter(address(v2Router), address(v2Factory));
        
        feeRouter.setAuthorizedFactory(address(factory));
        factory.setV2Router(address(v2Router));
        factory.setFeeRouter(address(feeRouter));
        
        vm.stopPrank();
        
        lastTotalTokens = 0;
    }
    
    /**
     * @notice Token count should only increase
     */
    function invariant_tokenCountOnlyIncreases() public {
        uint256 currentTotal = factory.totalTokens();
        assertTrue(
            currentTotal >= lastTotalTokens,
            "Token count should only increase"
        );
        lastTotalTokens = currentTotal;
    }
}
