// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../contracts/TokenFactory.sol";
import "../../contracts/CreatorFeeRouter.sol";
import "../../contracts/LaunchToken.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

// ============ Mock Contracts ============

contract MockWETH {
    string public name = "Wrapped Ether";
    string public symbol = "WETH";
    uint8 public decimals = 18;
    
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    
    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
    }
    
    function withdraw(uint256 amount) external {
        require(balanceOf[msg.sender] >= amount, "Insufficient balance");
        balanceOf[msg.sender] -= amount;
        payable(msg.sender).transfer(amount);
    }
    
    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
    
    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
    
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
    
    receive() external payable {
        balanceOf[msg.sender] += msg.value;
    }
}

contract MockV2Pair {
    address public token0;
    address public token1;
    uint112 public reserve0;
    uint112 public reserve1;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    
    constructor(address _token0, address _token1) {
        token0 = _token0;
        token1 = _token1;
    }
    
    function setReserves(uint112 _reserve0, uint112 _reserve1) external {
        reserve0 = _reserve0;
        reserve1 = _reserve1;
    }
    
    function getReserves() external view returns (uint112, uint112, uint32) {
        return (reserve0, reserve1, uint32(block.timestamp));
    }
    
    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }
    
    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
    
    function approve(address, uint256) external pure returns (bool) {
        return true;
    }
    
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract MockV2Factory {
    mapping(address => mapping(address => address)) public getPair;
    address[] public allPairs;
    
    function createPair(address tokenA, address tokenB) external returns (address pair) {
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        pair = address(new MockV2Pair(token0, token1));
        getPair[tokenA][tokenB] = pair;
        getPair[tokenB][tokenA] = pair;
        allPairs.push(pair);
        return pair;
    }
    
    function setPair(address tokenA, address tokenB, address pair) external {
        getPair[tokenA][tokenB] = pair;
        getPair[tokenB][tokenA] = pair;
    }
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
        address to,
        uint
    ) external payable returns (uint amountToken, uint amountETH, uint liquidity) {
        IERC20(token).transferFrom(msg.sender, address(this), amountTokenDesired);
        
        // Get or create pair
        address pair = MockV2Factory(factory).getPair(token, WETH);
        if (pair == address(0)) {
            pair = MockV2Factory(factory).createPair(token, WETH);
        }
        
        // Mint LP tokens to recipient
        liquidity = msg.value;
        MockV2Pair(pair).mint(to, liquidity);
        
        // Set reserves
        MockV2Pair(pair).setReserves(uint112(amountTokenDesired), uint112(msg.value));
        
        amountToken = amountTokenDesired;
        amountETH = msg.value;
        return (amountToken, amountETH, liquidity);
    }
    
    function removeLiquidityETH(
        address token,
        uint liquidity,
        uint,
        uint,
        address to,
        uint
    ) external returns (uint amountToken, uint amountETH) {
        address pair = MockV2Factory(factory).getPair(token, WETH);
        require(pair != address(0), "Pair doesn't exist");
        
        // Transfer LP tokens from sender
        MockV2Pair(pair).transferFrom(msg.sender, address(this), liquidity);
        
        // Return tokens and ETH proportionally (simplified)
        amountToken = liquidity * 100; // Simplified ratio
        amountETH = liquidity;
        
        IERC20(token).transfer(to, amountToken);
        payable(to).transfer(amountETH);
        
        return (amountToken, amountETH);
    }
    
    function swapExactETHForTokens(
        uint,
        address[] calldata path,
        address to,
        uint
    ) external payable returns (uint[] memory amounts) {
        amounts = new uint[](2);
        amounts[0] = msg.value;
        amounts[1] = msg.value * 100;
        
        // Mock: mint tokens to recipient (in real scenario, pair would transfer)
        // This is simplified - actual implementation would interact with pair
        return amounts;
    }
    
    function getAmountsOut(uint amountIn, address[] calldata) external pure returns (uint[] memory amounts) {
        amounts = new uint[](2);
        amounts[0] = amountIn;
        amounts[1] = amountIn * 100;
        return amounts;
    }
    
    receive() external payable {}
}

contract TokenFactoryTest is Test {
    TokenFactory public factory;
    CreatorFeeRouter public feeRouter;
    MockWETH public weth;
    MockV2Factory public v2Factory;
    MockV2Router public v2Router;
    
    address public deployer = address(1);
    address public attacker = address(2);
    address public user1 = address(3);
    address public user2 = address(4);
    
    event TokenLaunched(
        address indexed token,
        string name,
        string symbol,
        address indexed creator,
        uint256 timestamp
    );
    
    event TradeFeeHookUpdated(address indexed oldHook, address indexed newHook);
    event V2RouterUpdated(address indexed oldRouter, address indexed newRouter);
    event FeeRouterUpdated(address indexed oldRouter, address indexed newRouter);
    event GraduationFundsReceived(address indexed token, uint256 amount);
    event GraduationFundsWithdrawn(address indexed token, address indexed recipient, uint256 amount);
    event EmergencyGraduationWithdraw(address indexed token, address indexed creator, uint256 amount);
    
    function setUp() public {
        vm.startPrank(deployer);
        
        // Deploy mock Uniswap contracts
        weth = new MockWETH();
        v2Factory = new MockV2Factory();
        v2Router = new MockV2Router(address(weth), address(v2Factory));
        
        // Deploy our contracts
        factory = new TokenFactory(address(0)); // No trade fee hook
        feeRouter = new CreatorFeeRouter(address(v2Router), address(v2Factory));
        
        // Link contracts
        feeRouter.setAuthorizedFactory(address(factory));
        factory.setV2Router(address(v2Router));
        factory.setFeeRouter(address(feeRouter));
        
        vm.stopPrank();
        
        // Fund test accounts
        vm.deal(deployer, 100 ether);
        vm.deal(user1, 100 ether);
        vm.deal(user2, 100 ether);
        vm.deal(attacker, 100 ether);
    }
    
    // ============ Token Creation Tests ============
    
    function test_createToken_success() public {
        vm.prank(user1);
        address token = factory.createToken("Test Token", "TEST");
        
        assertTrue(token != address(0), "Token should be created");
        assertEq(LaunchToken(payable(token)).name(), "Test Token");
        assertEq(LaunchToken(payable(token)).symbol(), "TEST");
        assertEq(LaunchToken(payable(token)).creator(), user1);
        assertEq(LaunchToken(payable(token)).factory(), address(factory));
    }
    
    function test_createToken_emptyName_reverts() public {
        vm.prank(user1);
        vm.expectRevert(TokenFactory.EmptyName.selector);
        factory.createToken("", "TEST");
    }
    
    function test_createToken_emptySymbol_reverts() public {
        vm.prank(user1);
        vm.expectRevert(TokenFactory.EmptySymbol.selector);
        factory.createToken("Test Token", "");
    }
    
    function test_createToken_noV2Router_reverts() public {
        vm.prank(deployer);
        TokenFactory newFactory = new TokenFactory(address(0));
        // Don't set V2Router
        
        vm.prank(user1);
        vm.expectRevert(TokenFactory.V2RouterNotSet.selector);
        newFactory.createToken("Test", "TST");
    }
    
    function test_createToken_emitsEvent() public {
        vm.prank(user1);
        vm.expectEmit(false, true, true, true);
        emit TokenLaunched(address(0), "Test Token", "TEST", user1, block.timestamp);
        factory.createToken("Test Token", "TEST");
    }
    
    function test_createTokenDeterministic_success() public {
        bytes32 salt = keccak256("test_salt");
        
        address predicted = factory.predictTokenAddress(salt);
        
        vm.prank(user1);
        address actual = factory.createTokenDeterministic("Deterministic", "DET", salt);
        
        assertEq(predicted, actual, "Predicted address should match actual");
    }
    
    function test_createTokenDeterministic_sameSalt_reverts() public {
        bytes32 salt = keccak256("duplicate_salt");
        
        vm.prank(user1);
        factory.createTokenDeterministic("First", "FRST", salt);
        
        vm.prank(user2);
        vm.expectRevert(); // CREATE2 collision
        factory.createTokenDeterministic("Second", "SCND", salt);
    }
    
    function test_predictTokenAddress_accuracy() public {
        bytes32 salt = keccak256("predict_test");
        address predicted = factory.predictTokenAddress(salt);
        
        // Verify it's a valid address
        assertTrue(predicted != address(0));
        
        // Create and verify
        vm.prank(user1);
        address actual = factory.createTokenDeterministic("Predict", "PRED", salt);
        assertEq(predicted, actual);
    }
    
    // ============ State Tracking Tests ============
    
    function test_isLaunchedToken_true() public {
        vm.prank(user1);
        address token = factory.createToken("Test", "TST");
        
        assertTrue(factory.isLaunchedToken(token));
    }
    
    function test_isLaunchedToken_false() public {
        assertFalse(factory.isLaunchedToken(address(0x123)));
        assertFalse(factory.isLaunchedToken(user1));
    }
    
    function test_tokensByCreator_tracked() public {
        vm.startPrank(user1);
        address token1 = factory.createToken("Token1", "TK1");
        address token2 = factory.createToken("Token2", "TK2");
        vm.stopPrank();
        
        address[] memory tokens = factory.getTokensByCreator(user1);
        assertEq(tokens.length, 2);
        assertEq(tokens[0], token1);
        assertEq(tokens[1], token2);
    }
    
    function test_launchedTokens_array_grows() public {
        assertEq(factory.totalTokens(), 0);
        
        vm.prank(user1);
        address token1 = factory.createToken("Token1", "TK1");
        assertEq(factory.launchedTokens(0), token1);
        
        vm.prank(user2);
        address token2 = factory.createToken("Token2", "TK2");
        assertEq(factory.launchedTokens(1), token2);
    }
    
    function test_totalTokens_increments() public {
        assertEq(factory.totalTokens(), 0);
        
        vm.prank(user1);
        factory.createToken("Token1", "TK1");
        assertEq(factory.totalTokens(), 1);
        
        vm.prank(user1);
        factory.createToken("Token2", "TK2");
        assertEq(factory.totalTokens(), 2);
        
        vm.prank(user2);
        factory.createToken("Token3", "TK3");
        assertEq(factory.totalTokens(), 3);
    }
    
    // ============ View Functions Tests ============
    
    function test_getTokensPaginated_fullList() public {
        // Create 5 tokens
        vm.startPrank(user1);
        for (uint i = 0; i < 5; i++) {
            factory.createToken(string(abi.encodePacked("Token", vm.toString(i))), string(abi.encodePacked("TK", vm.toString(i))));
        }
        vm.stopPrank();
        
        address[] memory tokens = factory.getTokensPaginated(0, 5);
        assertEq(tokens.length, 5);
    }
    
    function test_getTokensPaginated_offsetBeyondLength() public {
        vm.prank(user1);
        factory.createToken("Token", "TK");
        
        address[] memory tokens = factory.getTokensPaginated(10, 5);
        assertEq(tokens.length, 0);
    }
    
    function test_getTokensPaginated_limitExceedsRemaining() public {
        vm.startPrank(user1);
        factory.createToken("Token1", "TK1");
        factory.createToken("Token2", "TK2");
        factory.createToken("Token3", "TK3");
        vm.stopPrank();
        
        address[] memory tokens = factory.getTokensPaginated(1, 10);
        assertEq(tokens.length, 2); // Only 2 remaining after offset
    }
    
    function test_getTokensInfo_multipleTokens() public {
        vm.prank(user1);
        address token1 = factory.createToken("Token One", "TK1");
        vm.prank(user2);
        address token2 = factory.createToken("Token Two", "TK2");
        
        address[] memory tokenAddresses = new address[](2);
        tokenAddresses[0] = token1;
        tokenAddresses[1] = token2;
        
        (
            string[] memory names,
            string[] memory symbols,
            uint256[] memory supplies,
            uint256[] memory treasuries,
            bool[] memory graduatedFlags
        ) = factory.getTokensInfo(tokenAddresses);
        
        assertEq(names[0], "Token One");
        assertEq(names[1], "Token Two");
        assertEq(symbols[0], "TK1");
        assertEq(symbols[1], "TK2");
        assertEq(supplies[0], 0);
        assertEq(supplies[1], 0);
        assertFalse(graduatedFlags[0]);
        assertFalse(graduatedFlags[1]);
    }
    
    function test_getGraduationThreshold() public view {
        assertEq(factory.getGraduationThreshold(), 0.004 ether);
    }
    
    function test_getCooldownPeriod() public view {
        assertEq(factory.getCooldownPeriod(), 60);
    }
    
    function test_getBuyFeeBps() public view {
        assertEq(factory.getBuyFeeBps(), 100); // 1%
    }
    
    function test_getSellFeeBps() public view {
        assertEq(factory.getSellFeeBps(), 200); // 2%
    }
    
    function test_getBasePrice() public view {
        assertEq(factory.getBasePrice(), 0.00001 ether);
    }
    
    // ============ Admin Functions Tests ============
    
    function test_setTradeFeeHook_onlyOwner() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        factory.setTradeFeeHook(address(0x123));
    }
    
    function test_setTradeFeeHook_success() public {
        address newHook = address(0x999);
        
        vm.prank(deployer);
        vm.expectEmit(true, true, false, false);
        emit TradeFeeHookUpdated(address(0), newHook);
        factory.setTradeFeeHook(newHook);
        
        assertEq(factory.tradeFeeHook(), newHook);
    }
    
    function test_setV2Router_onlyOwner() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        factory.setV2Router(address(0x123));
    }
    
    function test_setV2Router_success() public {
        address newRouter = address(0x888);
        
        vm.prank(deployer);
        vm.expectEmit(true, true, false, false);
        emit V2RouterUpdated(address(v2Router), newRouter);
        factory.setV2Router(newRouter);
        
        assertEq(factory.v2Router(), newRouter);
    }
    
    function test_setFeeRouter_onlyOwner() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        factory.setFeeRouter(address(0x123));
    }
    
    function test_setFeeRouter_success() public {
        address newFeeRouter = address(0x777);
        
        vm.prank(deployer);
        vm.expectEmit(true, true, false, false);
        emit FeeRouterUpdated(address(feeRouter), newFeeRouter);
        factory.setFeeRouter(newFeeRouter);
        
        assertEq(factory.feeRouter(), newFeeRouter);
    }
    
    function test_withdrawGraduationFunds_onlyOwner() public {
        // First create and graduate a token
        vm.prank(user1);
        address token = factory.createToken("Test", "TST");
        
        vm.warp(block.timestamp + 61); // Past cooldown
        vm.prank(user1);
        LaunchToken(payable(token)).buy{value: 0.005 ether}();
        
        // Attacker tries to withdraw
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        factory.withdrawGraduationFunds(token, attacker);
    }
    
    function test_withdrawGraduationFunds_notLaunchedToken_reverts() public {
        vm.prank(deployer);
        vm.expectRevert(TokenFactory.NotLaunchedToken.selector);
        factory.withdrawGraduationFunds(address(0x123), deployer);
    }
    
    function test_withdrawGraduationFunds_zeroFunds_reverts() public {
        vm.prank(user1);
        address token = factory.createToken("Test", "TST");
        
        vm.prank(deployer);
        vm.expectRevert(TokenFactory.InsufficientFunds.selector);
        factory.withdrawGraduationFunds(token, deployer);
    }
    
    function test_withdrawGraduationFunds_success() public {
        vm.prank(user1);
        address token = factory.createToken("Test", "TST");
        
        vm.warp(block.timestamp + 61);
        vm.prank(user1);
        LaunchToken(payable(token)).buy{value: 0.005 ether}();
        
        assertTrue(LaunchToken(payable(token)).graduated());
        uint256 graduationFunds = factory.graduationFunds(token);
        assertTrue(graduationFunds > 0);
        
        uint256 recipientBalanceBefore = deployer.balance;
        
        vm.prank(deployer);
        factory.withdrawGraduationFunds(token, deployer);
        
        assertEq(factory.graduationFunds(token), 0);
        assertEq(deployer.balance, recipientBalanceBefore + graduationFunds);
    }
    
    // ============ Emergency Functions Tests ============
    
    function test_emergencyWithdrawGraduationFunds_onlyCreator() public {
        vm.prank(user1);
        address token = factory.createToken("Test", "TST");
        
        vm.warp(block.timestamp + 61);
        vm.prank(user1);
        LaunchToken(payable(token)).buy{value: 0.005 ether}();
        
        vm.prank(attacker);
        vm.expectRevert(TokenFactory.NotTokenCreator.selector);
        factory.emergencyWithdrawGraduationFunds(token);
    }
    
    function test_emergencyWithdrawGraduationFunds_success() public {
        vm.prank(user1);
        address token = factory.createToken("Test", "TST");
        
        vm.warp(block.timestamp + 61);
        vm.prank(user1);
        LaunchToken(payable(token)).buy{value: 0.005 ether}();
        
        uint256 graduationFunds = factory.graduationFunds(token);
        uint256 creatorBalanceBefore = user1.balance;
        
        vm.prank(user1);
        factory.emergencyWithdrawGraduationFunds(token);
        
        assertEq(factory.graduationFunds(token), 0);
        assertEq(user1.balance, creatorBalanceBefore + graduationFunds);
    }
    
    function test_rugPool_onlyCreator() public {
        // This test requires a pool to exist
        vm.prank(user1);
        address token = factory.createToken("Test", "TST");
        
        vm.prank(attacker);
        vm.expectRevert(TokenFactory.NotTokenCreator.selector);
        factory.rugPool(token);
    }
    
    function test_rugPool_noPool_reverts() public {
        vm.prank(user1);
        address token = factory.createToken("Test", "TST");
        
        vm.prank(user1);
        vm.expectRevert(TokenFactory.NoPoolExists.selector);
        factory.rugPool(token);
    }
    
    // ============ Receive ETH Tests ============
    
    function test_receive_fromLaunchedToken() public {
        vm.prank(user1);
        address token = factory.createToken("Test", "TST");
        
        // The token sends ETH during graduation
        vm.warp(block.timestamp + 61);
        vm.prank(user1);
        LaunchToken(payable(token)).buy{value: 0.005 ether}();
        
        // Graduation funds should be tracked
        assertTrue(factory.graduationFunds(token) > 0);
    }
    
    function test_receive_fromNonToken_reverts() public {
        vm.prank(attacker);
        vm.expectRevert(TokenFactory.NotLaunchedToken.selector);
        (bool success,) = address(factory).call{value: 1 ether}("");
        // The revert happens in receive(), so success would be false
    }
    
    function test_receive_fromV2Router_noTracking() public {
        // Send from V2 router - should not track as graduation funds
        uint256 factoryBalanceBefore = address(factory).balance;
        
        vm.deal(address(v2Router), 1 ether);
        vm.prank(address(v2Router));
        (bool success,) = address(factory).call{value: 0.5 ether}("");
        assertTrue(success);
        
        // Balance increased but not tracked in any specific token's graduation funds
        assertEq(address(factory).balance, factoryBalanceBefore + 0.5 ether);
    }
    
    // ============ Pool Functions Tests ============
    
    function test_getPair_nonExistent() public {
        vm.prank(user1);
        address token = factory.createToken("Test", "TST");
        
        assertEq(factory.getPair(token), address(0));
        assertFalse(factory.hasPair(token));
    }
    
    function test_totalGraduationFunds() public {
        vm.prank(user1);
        address token = factory.createToken("Test", "TST");
        
        vm.warp(block.timestamp + 61);
        vm.prank(user1);
        LaunchToken(payable(token)).buy{value: 0.005 ether}();
        
        assertTrue(factory.totalGraduationFunds() > 0);
    }
}
