// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../contracts/CreatorFeeRouter.sol";
import "../../contracts/TokenFactory.sol";
import "../../contracts/LaunchToken.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// ============ Mock Contracts ============

contract MockWETH {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    
    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
    }
    
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
    
    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
    
    receive() external payable {
        balanceOf[msg.sender] += msg.value;
    }
}

contract MockToken is IERC20 {
    string public name = "Mock Token";
    string public symbol = "MOCK";
    uint8 public decimals = 18;
    
    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;
    uint256 private _totalSupply;
    
    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }
    
    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }
    
    function transfer(address to, uint256 amount) external returns (bool) {
        _balances[msg.sender] -= amount;
        _balances[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }
    
    function allowance(address owner, address spender) external view returns (uint256) {
        return _allowances[owner][spender];
    }
    
    function approve(address spender, uint256 amount) external returns (bool) {
        _allowances[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }
    
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        _allowances[from][msg.sender] -= amount;
        _balances[from] -= amount;
        _balances[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
    
    function mint(address to, uint256 amount) external {
        _balances[to] += amount;
        _totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }
}

contract MockV2Pair {
    address public token0;
    address public token1;
    uint112 public reserve0 = 1000 ether;
    uint112 public reserve1 = 100 ether;
    
    constructor(address _token0, address _token1) {
        (token0, token1) = _token0 < _token1 ? (_token0, _token1) : (_token1, _token0);
    }
    
    function getReserves() external view returns (uint112, uint112, uint32) {
        return (reserve0, reserve1, uint32(block.timestamp));
    }
    
    function setReserves(uint112 _reserve0, uint112 _reserve1) external {
        reserve0 = _reserve0;
        reserve1 = _reserve1;
    }
}

contract MockV2Factory {
    mapping(address => mapping(address => address)) public getPair;
    
    function createPair(address tokenA, address tokenB) external returns (address pair) {
        (address t0, address t1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        pair = address(new MockV2Pair(t0, t1));
        getPair[tokenA][tokenB] = pair;
        getPair[tokenB][tokenA] = pair;
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
    
    mapping(address => uint256) public tokenBalances;
    
    constructor(address _weth, address _factory) {
        WETH = _weth;
        factory = _factory;
    }
    
    function swapExactETHForTokens(
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint
    ) external payable returns (uint[] memory amounts) {
        require(path[0] == WETH, "Invalid path");
        
        amounts = new uint[](2);
        amounts[0] = msg.value;
        amounts[1] = msg.value * 100; // 1 ETH = 100 tokens (simplified)
        
        require(amounts[1] >= amountOutMin, "Insufficient output");
        
        // Transfer tokens to recipient
        MockToken(path[1]).mint(to, amounts[1]);
        
        return amounts;
    }
    
    function swapExactTokensForETH(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint
    ) external returns (uint[] memory amounts) {
        require(path[1] == WETH, "Invalid path");
        
        // Transfer tokens from sender
        IERC20(path[0]).transferFrom(msg.sender, address(this), amountIn);
        
        amounts = new uint[](2);
        amounts[0] = amountIn;
        amounts[1] = amountIn / 100; // 100 tokens = 1 ETH (simplified)
        
        require(amounts[1] >= amountOutMin, "Insufficient output");
        
        // Send ETH to recipient
        payable(to).transfer(amounts[1]);
        
        return amounts;
    }
    
    function getAmountsOut(uint amountIn, address[] calldata path) external view returns (uint[] memory amounts) {
        amounts = new uint[](2);
        amounts[0] = amountIn;
        
        if (path[0] == WETH) {
            amounts[1] = amountIn * 100; // ETH -> Token
        } else {
            amounts[1] = amountIn / 100; // Token -> ETH
        }
        
        return amounts;
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

contract CreatorFeeRouterTest is Test {
    CreatorFeeRouter public feeRouter;
    MockWETH public weth;
    MockV2Factory public v2Factory;
    MockV2Router public v2Router;
    TokenFactory public tokenFactory;
    
    MockToken public mockToken;
    
    address public deployer = address(1);
    address public creator = address(2);
    address public user = address(3);
    address public attacker = address(4);
    
    event TokenRegistered(address indexed token, address indexed creator);
    event SwapWithFee(
        address indexed user,
        address indexed token,
        bool isBuy,
        uint256 amountIn,
        uint256 amountOut,
        uint256 fee
    );
    event FeesWithdrawn(address indexed token, address indexed creator, uint256 amount);
    event FeesDeposited(address indexed token, uint256 amount);
    
    function setUp() public {
        vm.startPrank(deployer);
        
        weth = new MockWETH();
        v2Factory = new MockV2Factory();
        v2Router = new MockV2Router(address(weth), address(v2Factory));
        
        feeRouter = new CreatorFeeRouter(address(v2Router), address(v2Factory));
        tokenFactory = new TokenFactory(address(0));
        
        // Setup factory linkage
        feeRouter.setAuthorizedFactory(address(tokenFactory));
        tokenFactory.setV2Router(address(v2Router));
        tokenFactory.setFeeRouter(address(feeRouter));
        
        // Create a mock token for testing
        mockToken = new MockToken();
        
        // Create a V2 pair for the mock token
        v2Factory.createPair(address(mockToken), address(weth));
        
        vm.stopPrank();
        
        // Fund accounts
        vm.deal(deployer, 100 ether);
        vm.deal(creator, 100 ether);
        vm.deal(user, 100 ether);
        vm.deal(attacker, 100 ether);
        vm.deal(address(v2Router), 100 ether);
    }
    
    // ============ Initialization Tests ============
    
    function test_constructor_setsImmutables() public view {
        assertEq(address(feeRouter.v2Router()), address(v2Router));
        assertEq(address(feeRouter.v2Factory()), address(v2Factory));
        assertEq(feeRouter.WETH(), address(weth));
        assertEq(feeRouter.deployer(), deployer);
    }
    
    function test_constructor_zeroRouter_reverts() public {
        vm.expectRevert(CreatorFeeRouter.InvalidAddress.selector);
        new CreatorFeeRouter(address(0), address(v2Factory));
    }
    
    function test_constructor_zeroFactory_reverts() public {
        vm.expectRevert(CreatorFeeRouter.InvalidAddress.selector);
        new CreatorFeeRouter(address(v2Router), address(0));
    }
    
    function test_FEE_BPS_is200() public view {
        assertEq(feeRouter.FEE_BPS(), 200); // 2%
    }
    
    function test_BPS_DENOMINATOR_is10000() public view {
        assertEq(feeRouter.BPS_DENOMINATOR(), 10000);
    }
    
    // ============ Factory Registration Tests ============
    
    function test_setAuthorizedFactory_onlyDeployer() public {
        vm.prank(deployer);
        CreatorFeeRouter newRouter = new CreatorFeeRouter(address(v2Router), address(v2Factory));
        
        vm.prank(attacker);
        vm.expectRevert(CreatorFeeRouter.NotDeployer.selector);
        newRouter.setAuthorizedFactory(attacker);
    }
    
    function test_setAuthorizedFactory_success() public {
        vm.prank(deployer);
        CreatorFeeRouter newRouter = new CreatorFeeRouter(address(v2Router), address(v2Factory));
        
        vm.prank(deployer);
        newRouter.setAuthorizedFactory(address(tokenFactory));
        
        assertEq(newRouter.authorizedFactory(), address(tokenFactory));
    }
    
    function test_setAuthorizedFactory_twice_reverts() public {
        vm.prank(deployer);
        CreatorFeeRouter newRouter = new CreatorFeeRouter(address(v2Router), address(v2Factory));
        
        vm.prank(deployer);
        newRouter.setAuthorizedFactory(address(tokenFactory));
        
        vm.prank(deployer);
        vm.expectRevert(CreatorFeeRouter.AlreadyRegistered.selector);
        newRouter.setAuthorizedFactory(address(0x123));
    }
    
    function test_setAuthorizedFactory_zeroAddress_reverts() public {
        vm.prank(deployer);
        CreatorFeeRouter newRouter = new CreatorFeeRouter(address(v2Router), address(v2Factory));
        
        vm.prank(deployer);
        vm.expectRevert(CreatorFeeRouter.InvalidAddress.selector);
        newRouter.setAuthorizedFactory(address(0));
    }
    
    // ============ Token Registration Tests ============
    
    function test_registerToken_onlyFactory() public {
        vm.prank(attacker);
        vm.expectRevert(CreatorFeeRouter.NotAuthorizedFactory.selector);
        feeRouter.registerToken(address(mockToken), creator);
    }
    
    function test_registerToken_success() public {
        vm.prank(address(tokenFactory));
        vm.expectEmit(true, true, false, false);
        emit TokenRegistered(address(mockToken), creator);
        feeRouter.registerToken(address(mockToken), creator);
        
        assertEq(feeRouter.tokenCreators(address(mockToken)), creator);
        assertTrue(feeRouter.isRegistered(address(mockToken)));
    }
    
    function test_registerToken_twice_reverts() public {
        vm.startPrank(address(tokenFactory));
        feeRouter.registerToken(address(mockToken), creator);
        
        vm.expectRevert(CreatorFeeRouter.AlreadyRegistered.selector);
        feeRouter.registerToken(address(mockToken), attacker);
        vm.stopPrank();
    }
    
    function test_registerToken_zeroToken_reverts() public {
        vm.prank(address(tokenFactory));
        vm.expectRevert(CreatorFeeRouter.InvalidAddress.selector);
        feeRouter.registerToken(address(0), creator);
    }
    
    function test_registerToken_zeroCreator_reverts() public {
        vm.prank(address(tokenFactory));
        vm.expectRevert(CreatorFeeRouter.InvalidAddress.selector);
        feeRouter.registerToken(address(mockToken), address(0));
    }
    
    // ============ Fee Deposit Tests ============
    
    function test_depositFees_success() public {
        // First register the token
        vm.prank(address(tokenFactory));
        feeRouter.registerToken(address(mockToken), creator);
        
        uint256 feeAmount = 0.01 ether;
        
        vm.prank(user);
        vm.expectEmit(true, false, false, true);
        emit FeesDeposited(address(mockToken), feeAmount);
        feeRouter.depositFees{value: feeAmount}(address(mockToken));
        
        assertEq(feeRouter.accumulatedFees(address(mockToken)), feeAmount);
    }
    
    function test_depositFees_unregisteredToken_reverts() public {
        vm.prank(user);
        vm.expectRevert(CreatorFeeRouter.TokenNotRegistered.selector);
        feeRouter.depositFees{value: 0.01 ether}(address(mockToken));
    }
    
    function test_depositFees_zeroValue_reverts() public {
        vm.prank(address(tokenFactory));
        feeRouter.registerToken(address(mockToken), creator);
        
        vm.prank(user);
        vm.expectRevert(CreatorFeeRouter.InvalidAddress.selector);
        feeRouter.depositFees{value: 0}(address(mockToken));
    }
    
    function test_depositFees_accumulates() public {
        vm.prank(address(tokenFactory));
        feeRouter.registerToken(address(mockToken), creator);
        
        vm.prank(user);
        feeRouter.depositFees{value: 0.01 ether}(address(mockToken));
        
        vm.prank(user);
        feeRouter.depositFees{value: 0.02 ether}(address(mockToken));
        
        assertEq(feeRouter.accumulatedFees(address(mockToken)), 0.03 ether);
    }
    
    // ============ Buy With Fee Tests ============
    
    function test_buyTokensWithFee_success() public {
        vm.prank(address(tokenFactory));
        feeRouter.registerToken(address(mockToken), creator);
        
        uint256 buyAmount = 1 ether;
        uint256 expectedFee = (buyAmount * 200) / 10000; // 2%
        
        vm.prank(user);
        uint256 tokensOut = feeRouter.buyTokensWithFee{value: buyAmount}(
            address(mockToken),
            0, // No minimum
            block.timestamp + 300
        );
        
        assertTrue(tokensOut > 0, "Should receive tokens");
        assertEq(feeRouter.accumulatedFees(address(mockToken)), expectedFee);
    }
    
    function test_buyTokensWithFee_unregistered_reverts() public {
        vm.prank(user);
        vm.expectRevert(CreatorFeeRouter.TokenNotRegistered.selector);
        feeRouter.buyTokensWithFee{value: 1 ether}(address(mockToken), 0, block.timestamp + 300);
    }
    
    function test_buyTokensWithFee_zeroValue_reverts() public {
        vm.prank(address(tokenFactory));
        feeRouter.registerToken(address(mockToken), creator);
        
        vm.prank(user);
        vm.expectRevert(CreatorFeeRouter.InvalidAddress.selector);
        feeRouter.buyTokensWithFee{value: 0}(address(mockToken), 0, block.timestamp + 300);
    }
    
    function test_buyTokensWithFee_emitsEvent() public {
        vm.prank(address(tokenFactory));
        feeRouter.registerToken(address(mockToken), creator);
        
        uint256 buyAmount = 1 ether;
        
        vm.prank(user);
        vm.expectEmit(true, true, false, false);
        emit SwapWithFee(user, address(mockToken), true, buyAmount, 0, 0);
        feeRouter.buyTokensWithFee{value: buyAmount}(address(mockToken), 0, block.timestamp + 300);
    }
    
    // ============ Sell With Fee Tests ============
    
    function test_sellTokensWithFee_success() public {
        vm.prank(address(tokenFactory));
        feeRouter.registerToken(address(mockToken), creator);
        
        // Mint tokens to user
        mockToken.mint(user, 100 ether);
        
        uint256 sellAmount = 100 ether;
        
        vm.startPrank(user);
        mockToken.approve(address(feeRouter), sellAmount);
        
        uint256 ethOut = feeRouter.sellTokensWithFee(
            address(mockToken),
            sellAmount,
            0, // No minimum
            block.timestamp + 300
        );
        vm.stopPrank();
        
        assertTrue(ethOut > 0, "Should receive ETH");
        assertTrue(feeRouter.accumulatedFees(address(mockToken)) > 0, "Should accumulate fees");
    }
    
    function test_sellTokensWithFee_unregistered_reverts() public {
        mockToken.mint(user, 100 ether);
        
        vm.startPrank(user);
        mockToken.approve(address(feeRouter), 100 ether);
        
        vm.expectRevert(CreatorFeeRouter.TokenNotRegistered.selector);
        feeRouter.sellTokensWithFee(address(mockToken), 100 ether, 0, block.timestamp + 300);
        vm.stopPrank();
    }
    
    function test_sellTokensWithFee_zeroAmount_reverts() public {
        vm.prank(address(tokenFactory));
        feeRouter.registerToken(address(mockToken), creator);
        
        vm.prank(user);
        vm.expectRevert(CreatorFeeRouter.InvalidAddress.selector);
        feeRouter.sellTokensWithFee(address(mockToken), 0, 0, block.timestamp + 300);
    }
    
    function test_sellTokensWithFee_emitsEvent() public {
        vm.prank(address(tokenFactory));
        feeRouter.registerToken(address(mockToken), creator);
        
        mockToken.mint(user, 100 ether);
        
        vm.startPrank(user);
        mockToken.approve(address(feeRouter), 100 ether);
        
        vm.expectEmit(true, true, false, false);
        emit SwapWithFee(user, address(mockToken), false, 100 ether, 0, 0);
        feeRouter.sellTokensWithFee(address(mockToken), 100 ether, 0, block.timestamp + 300);
        vm.stopPrank();
    }
    
    // ============ Fee Withdrawal Tests ============
    
    function test_withdrawFees_onlyCreator() public {
        vm.prank(address(tokenFactory));
        feeRouter.registerToken(address(mockToken), creator);
        
        // Deposit some fees
        vm.prank(user);
        feeRouter.depositFees{value: 0.1 ether}(address(mockToken));
        
        vm.prank(attacker);
        vm.expectRevert(CreatorFeeRouter.NotCreator.selector);
        feeRouter.withdrawFees(address(mockToken));
    }
    
    function test_withdrawFees_success() public {
        vm.prank(address(tokenFactory));
        feeRouter.registerToken(address(mockToken), creator);
        
        uint256 feeAmount = 0.1 ether;
        vm.prank(user);
        feeRouter.depositFees{value: feeAmount}(address(mockToken));
        
        uint256 creatorBalanceBefore = creator.balance;
        
        vm.prank(creator);
        vm.expectEmit(true, true, false, true);
        emit FeesWithdrawn(address(mockToken), creator, feeAmount);
        feeRouter.withdrawFees(address(mockToken));
        
        assertEq(creator.balance, creatorBalanceBefore + feeAmount);
        assertEq(feeRouter.accumulatedFees(address(mockToken)), 0);
    }
    
    function test_withdrawFees_noFees_reverts() public {
        vm.prank(address(tokenFactory));
        feeRouter.registerToken(address(mockToken), creator);
        
        vm.prank(creator);
        vm.expectRevert(CreatorFeeRouter.NoFeesToWithdraw.selector);
        feeRouter.withdrawFees(address(mockToken));
    }
    
    function test_withdrawFees_unregisteredToken_reverts() public {
        vm.prank(creator);
        vm.expectRevert(CreatorFeeRouter.TokenNotRegistered.selector);
        feeRouter.withdrawFees(address(mockToken));
    }
    
    // ============ View Functions Tests ============
    
    function test_getPair() public {
        address pair = v2Factory.getPair(address(mockToken), address(weth));
        assertEq(feeRouter.getPair(address(mockToken)), pair);
    }
    
    function test_hasPair_true() public view {
        assertTrue(feeRouter.hasPair(address(mockToken)));
    }
    
    function test_hasPair_false() public {
        MockToken unknownToken = new MockToken();
        assertFalse(feeRouter.hasPair(address(unknownToken)));
    }
    
    function test_getReserves() public view {
        (uint256 ethReserve, uint256 tokenReserve) = feeRouter.getReserves(address(mockToken));
        // Reserves depend on pair setup in MockV2Pair
        assertTrue(ethReserve > 0 || tokenReserve > 0, "Should have reserves");
    }
    
    function test_getReserves_noPair() public {
        MockToken unknownToken = new MockToken();
        (uint256 ethReserve, uint256 tokenReserve) = feeRouter.getReserves(address(unknownToken));
        assertEq(ethReserve, 0);
        assertEq(tokenReserve, 0);
    }
    
    function test_estimateBuyOutput() public {
        vm.prank(address(tokenFactory));
        feeRouter.registerToken(address(mockToken), creator);
        
        uint256 ethIn = 1 ether;
        uint256 estimate = feeRouter.estimateBuyOutput(address(mockToken), ethIn);
        
        // Should account for 2% fee
        assertTrue(estimate > 0, "Should have estimate");
    }
    
    function test_estimateBuyOutput_zeroInput() public view {
        uint256 estimate = feeRouter.estimateBuyOutput(address(mockToken), 0);
        assertEq(estimate, 0);
    }
    
    function test_estimateSellOutput() public {
        vm.prank(address(tokenFactory));
        feeRouter.registerToken(address(mockToken), creator);
        
        uint256 tokensIn = 100 ether;
        uint256 estimate = feeRouter.estimateSellOutput(address(mockToken), tokensIn);
        
        // Should account for 2% fee
        assertTrue(estimate > 0, "Should have estimate");
    }
    
    function test_estimateSellOutput_zeroInput() public view {
        uint256 estimate = feeRouter.estimateSellOutput(address(mockToken), 0);
        assertEq(estimate, 0);
    }
    
    function test_getCreator() public {
        vm.prank(address(tokenFactory));
        feeRouter.registerToken(address(mockToken), creator);
        
        assertEq(feeRouter.getCreator(address(mockToken)), creator);
    }
    
    function test_getCreator_unregistered() public view {
        assertEq(feeRouter.getCreator(address(mockToken)), address(0));
    }
    
    function test_isRegistered_true() public {
        vm.prank(address(tokenFactory));
        feeRouter.registerToken(address(mockToken), creator);
        
        assertTrue(feeRouter.isRegistered(address(mockToken)));
    }
    
    function test_isRegistered_false() public view {
        assertFalse(feeRouter.isRegistered(address(mockToken)));
    }
    
    // ============ Receive ETH Test ============
    
    function test_receive_acceptsETH() public {
        uint256 balanceBefore = address(feeRouter).balance;
        
        vm.prank(user);
        (bool success,) = address(feeRouter).call{value: 1 ether}("");
        assertTrue(success);
        
        assertEq(address(feeRouter).balance, balanceBefore + 1 ether);
    }
}
