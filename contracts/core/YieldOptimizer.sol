// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "../interfaces/IStaking.sol";
import "../libraries/StakingMath.sol";

/**
 * @title YieldOptimizer
 * @dev Auto-compounds and optimizes yields by integrating with external DeFi protocols
 * @author Talent Protocol Builder
 */
contract YieldOptimizer {
    using StakingMath for uint256;
    
    // ============ Types ============
    
    enum StrategyType {
        None,
        Aave,
        Compound,
        Curve,
        Yearn,
        Convex
    }
    
    struct Strategy {
        StrategyType strategyType;
        address targetProtocol;
        address targetAsset;
        uint256 allocatedAmount;
        uint256 lastHarvestTime;
        uint256 totalHarvested;
        uint256 performanceFee;
        bool isActive;
        bytes strategyData; // Protocol-specific configuration
    }
    
    struct OptimizationParams {
        uint256 minDepositAmount;
        uint256 maxSlippage; // In basis points
        uint256 compoundThreshold;
        uint256 harvestInterval;
        uint256 emergencyWithdrawPenalty;
    }
    
    struct UserOptimization {
        mapping(uint256 => uint256) strategyAllocations; // strategyId => amount
        uint256 totalOptimized;
        uint256 totalRewards;
        uint256 lastOptimizationTime;
        bool autoCompound;
        uint256 preferredStrategyId;
    }
    
    // ============ State Variables ============
    
    // Core contracts
    address public owner;
    address public stakingVault;
    address public governance;
    address public treasury;
    
    // Strategy management
    mapping(uint256 => Strategy) public strategies;
    mapping(address => UserOptimization) public userOptimizations;
    uint256 public strategyCounter;
    
    // Optimization parameters
    OptimizationParams public defaultParams;
    mapping(StrategyType => OptimizationParams) public strategyParams;
    
    // Tracking
    uint256 public totalValueLocked;
    uint256 public totalRewardsGenerated;
    mapping(address => bool) public authorized;
    
    // Security
    bool public paused;
    uint256 private locked;
    
    // Protocol integrations (mock addresses for example)
    mapping(StrategyType => address) public protocolAdapters;
    
    // ============ Events ============
    
    event StrategyAdded(uint256 indexed strategyId, StrategyType strategyType, address targetProtocol);
    event StrategyUpdated(uint256 indexed strategyId, bool isActive);
    event FundsDeposited(address indexed user, uint256 indexed strategyId, uint256 amount);
    event FundsWithdrawn(address indexed user, uint256 indexed strategyId, uint256 amount);
    event RewardsHarvested(uint256 indexed strategyId, uint256 rewards);
    event CompoundExecuted(address indexed user, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 amount, uint256 penalty);
    event StrategyMigrated(uint256 fromStrategy, uint256 toStrategy, uint256 amount);
    
    // ============ Modifiers ============
    
    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }
    
    modifier onlyAuthorized() {
        require(authorized[msg.sender] || msg.sender == owner, "Not authorized");
        _;
    }
    
    modifier whenNotPaused() {
        require(!paused, "Paused");
        _;
    }
    
    modifier nonReentrant() {
        require(locked == 0, "Reentrant");
        locked = 1;
        _;
        locked = 0;
    }
    
    modifier validStrategy(uint256 _strategyId) {
        require(_strategyId < strategyCounter && strategies[_strategyId].isActive, "Invalid strategy");
        _;
    }
    
    // ============ Constructor ============
    
    constructor(address _stakingVault, address _treasury) {
        owner = msg.sender;
        stakingVault = _stakingVault;
        treasury = _treasury;
        
        // Initialize default parameters
        defaultParams = OptimizationParams({
            minDepositAmount: 100 * 10**18, // 100 tokens minimum
            maxSlippage: 100, // 1% max slippage
            compoundThreshold: 10 * 10**18, // Compound when rewards > 10 tokens
            harvestInterval: 6 hours,
            emergencyWithdrawPenalty: 500 // 5% penalty
        });
    }
    
    // ============ Strategy Management ============
    
    function addStrategy(
        StrategyType _type,
        address _targetProtocol,
        address _targetAsset,
        uint256 _performanceFee,
        bytes calldata _strategyData
    ) external onlyOwner returns (uint256) {
        require(_targetProtocol != address(0), "Invalid protocol");
        require(_performanceFee <= 2000, "Fee too high"); // Max 20%
        
        uint256 strategyId = strategyCounter++;
        
        strategies[strategyId] = Strategy({
            strategyType: _type,
            targetProtocol: _targetProtocol,
            targetAsset: _targetAsset,
            allocatedAmount: 0,
            lastHarvestTime: block.timestamp,
            totalHarvested: 0,
            performanceFee: _performanceFee,
            isActive: true,
            strategyData: _strategyData
        });
        
        emit StrategyAdded(strategyId, _type, _targetProtocol);
        return strategyId;
    }
    
    function updateStrategy(uint256 _strategyId, bool _isActive) 
        external 
        onlyOwner 
        validStrategy(_strategyId) 
    {
        strategies[_strategyId].isActive = _isActive;
        emit StrategyUpdated(_strategyId, _isActive);
    }
    
    // ============ User Optimization Functions ============
    
    function optimizeFunds(uint256 _strategyId, uint256 _amount) 
        external 
        whenNotPaused 
        nonReentrant 
        validStrategy(_strategyId) 
    {
        require(_amount >= defaultParams.minDepositAmount, "Below minimum");
        
        Strategy storage strategy = strategies[_strategyId];
        UserOptimization storage userOpt = userOptimizations[msg.sender];
        
        // Transfer funds from user (assumes approval)
        IERC20(strategy.targetAsset).transferFrom(msg.sender, address(this), _amount);
        
        // Deploy funds to strategy
        _deployToStrategy(_strategyId, _amount);
        
        // Update user allocations
        userOpt.strategyAllocations[_strategyId] += _amount;
        userOpt.totalOptimized += _amount;
        userOpt.lastOptimizationTime = block.timestamp;
        
        // Update strategy totals
        strategy.allocatedAmount += _amount;
        totalValueLocked += _amount;
        
        emit FundsDeposited(msg.sender, _strategyId, _amount);
    }
    
    function withdrawOptimized(uint256 _strategyId, uint256 _amount) 
        external 
        nonReentrant 
        validStrategy(_strategyId) 
    {
        UserOptimization storage userOpt = userOptimizations[msg.sender];
        require(userOpt.strategyAllocations[_strategyId] >= _amount, "Insufficient balance");
        
        Strategy storage strategy = strategies[_strategyId];
        
        // Harvest any pending rewards first
        uint256 rewards = _harvestStrategy(_strategyId, msg.sender);
        
        // Withdraw from strategy
        uint256 withdrawn = _withdrawFromStrategy(_strategyId, _amount);
        
        // Update allocations
        userOpt.strategyAllocations[_strategyId] -= _amount;
        userOpt.totalOptimized -= _amount;
        strategy.allocatedAmount -= _amount;
        totalValueLocked -= _amount;
        
        // Transfer funds back to user
        IERC20(strategy.targetAsset).transfer(msg.sender, withdrawn + rewards);
        
        emit FundsWithdrawn(msg.sender, _strategyId, withdrawn);
    }
    
    function emergencyWithdrawAll() external nonReentrant {
        UserOptimization storage userOpt = userOptimizations[msg.sender];
        require(userOpt.totalOptimized > 0, "No funds to withdraw");
        
        uint256 totalWithdrawn = 0;
        uint256 totalPenalty = 0;
        
        // Withdraw from all strategies
        for (uint256 i = 0; i < strategyCounter; i++) {
            uint256 allocation = userOpt.strategyAllocations[i];
            if (allocation > 0) {
                Strategy storage strategy = strategies[i];
                
                // Force withdraw with penalty
                uint256 withdrawn = _emergencyWithdrawFromStrategy(i, allocation);
                uint256 penalty = (withdrawn * defaultParams.emergencyWithdrawPenalty) / 10000;
                
                totalWithdrawn += (withdrawn - penalty);
                totalPenalty += penalty;
                
                // Reset allocation
                userOpt.strategyAllocations[i] = 0;
                strategy.allocatedAmount -= allocation;
            }
        }
        
        // Reset user totals
        userOpt.totalOptimized = 0;
        totalValueLocked -= (totalWithdrawn + totalPenalty);
        
        // Transfer penalty to treasury
        if (totalPenalty > 0) {
            IERC20(strategies[0].targetAsset).transfer(treasury, totalPenalty);
        }
        
        // Transfer remaining to user
        IERC20(strategies[0].targetAsset).transfer(msg.sender, totalWithdrawn);
        
        emit EmergencyWithdraw(msg.sender, totalWithdrawn, totalPenalty);
    }
    
    // ============ Auto-Compound Functions ============
    
    function enableAutoCompound(uint256 _preferredStrategyId) 
        external 
        validStrategy(_preferredStrategyId) 
    {
        UserOptimization storage userOpt = userOptimizations[msg.sender];
        userOpt.autoCompound = true;
        userOpt.preferredStrategyId = _preferredStrategyId;
    }
    
    function disableAutoCompound() external {
        userOptimizations[msg.sender].autoCompound = false;
    }
    
    function executeAutoCompound(address[] calldata _users) external onlyAuthorized {
        for (uint256 i = 0; i < _users.length; i++) {
            _compoundUser(_users[i]);
        }
    }
    
    function _compoundUser(address _user) internal {
        UserOptimization storage userOpt = userOptimizations[_user];
        
        if (!userOpt.autoCompound || userOpt.totalOptimized == 0) {
            return;
        }
        
        uint256 totalRewards = 0;
        
        // Harvest from all user strategies
        for (uint256 i = 0; i < strategyCounter; i++) {
            if (userOpt.strategyAllocations[i] > 0) {
                totalRewards += _harvestStrategy(i, _user);
            }
        }
        
        // Compound if above threshold
        if (totalRewards >= defaultParams.compoundThreshold) {
            uint256 strategyId = userOpt.preferredStrategyId;
            
            // Deploy rewards back to preferred strategy
            _deployToStrategy(strategyId, totalRewards);
            
            // Update allocations
            userOpt.strategyAllocations[strategyId] += totalRewards;
            userOpt.totalOptimized += totalRewards;
            userOpt.totalRewards += totalRewards;
            
            strategies[strategyId].allocatedAmount += totalRewards;
            totalValueLocked += totalRewards;
            
            emit CompoundExecuted(_user, totalRewards);
        }
    }
    
    // ============ Harvest Functions ============
    
    function harvestStrategy(uint256 _strategyId) 
        external 
        onlyAuthorized 
        validStrategy(_strategyId) 
        returns (uint256) 
    {
        Strategy storage strategy = strategies[_strategyId];
        require(
            block.timestamp >= strategy.lastHarvestTime + defaultParams.harvestInterval,
            "Too soon to harvest"
        );
        
        uint256 rewards = _harvestFromProtocol(_strategyId);
        
        if (rewards > 0) {
            // Apply performance fee
            uint256 fee = (rewards * strategy.performanceFee) / 10000;
            if (fee > 0) {
                IERC20(strategy.targetAsset).transfer(treasury, fee);
            }
            
            uint256 netRewards = rewards - fee;
            strategy.totalHarvested += netRewards;
            totalRewardsGenerated += netRewards;
            
            emit RewardsHarvested(_strategyId, netRewards);
            return netRewards;
        }
        
        return 0;
    }
    
    function _harvestStrategy(uint256 _strategyId, address _user) 
        internal 
        returns (uint256) 
    {
        UserOptimization storage userOpt = userOptimizations[_user];
        uint256 userShare = userOpt.strategyAllocations[_strategyId];
        
        if (userShare == 0) return 0;
        
        Strategy storage strategy = strategies[_strategyId];
        uint256 totalAllocated = strategy.allocatedAmount;
        
        if (totalAllocated == 0) return 0;
        
        // Calculate user's share of rewards
        uint256 strategyRewards = _getPendingRewards(_strategyId);
        uint256 userRewards = (strategyRewards * userShare) / totalAllocated;
        
        return userRewards;
    }
    
    // ============ Strategy Migration ============
    
    function migrateStrategy(
        uint256 _fromStrategyId,
        uint256 _toStrategyId,
        uint256 _amount
    ) 
        external 
        onlyOwner 
        validStrategy(_fromStrategyId) 
        validStrategy(_toStrategyId) 
    {
        require(_amount > 0, "Invalid amount");
        
        Strategy storage fromStrategy = strategies[_fromStrategyId];
        Strategy storage toStrategy = strategies[_toStrategyId];
        
        require(fromStrategy.allocatedAmount >= _amount, "Insufficient funds in strategy");
        require(fromStrategy.targetAsset == toStrategy.targetAsset, "Asset mismatch");
        
        // Withdraw from old strategy
        uint256 withdrawn = _withdrawFromStrategy(_fromStrategyId, _amount);
        
        // Deploy to new strategy
        _deployToStrategy(_toStrategyId, withdrawn);
        
        // Update allocations
        fromStrategy.allocatedAmount -= _amount;
        toStrategy.allocatedAmount += withdrawn;
        
        emit StrategyMigrated(_fromStrategyId, _toStrategyId, withdrawn);
    }
    
    // ============ Internal Strategy Functions ============
    
    function _deployToStrategy(uint256 _strategyId, uint256 _amount) internal {
        Strategy memory strategy = strategies[_strategyId];
        
        if (strategy.strategyType == StrategyType.Aave) {
            _deployToAave(strategy, _amount);
        } else if (strategy.strategyType == StrategyType.Compound) {
            _deployToCompound(strategy, _amount);
        } else if (strategy.strategyType == StrategyType.Curve) {
            _deployToCurve(strategy, _amount);
        } else if (strategy.strategyType == StrategyType.Yearn) {
            _deployToYearn(strategy, _amount);
        } else if (strategy.strategyType == StrategyType.Convex) {
            _deployToConvex(strategy, _amount);
        }
    }
    
    function _withdrawFromStrategy(uint256 _strategyId, uint256 _amount) 
        internal 
        returns (uint256) 
    {
        Strategy memory strategy = strategies[_strategyId];
        
        if (strategy.strategyType == StrategyType.Aave) {
            return _withdrawFromAave(strategy, _amount);
        } else if (strategy.strategyType == StrategyType.Compound) {
            return _withdrawFromCompound(strategy, _amount);
        } else if (strategy.strategyType == StrategyType.Curve) {
            return _withdrawFromCurve(strategy, _amount);
        } else if (strategy.strategyType == StrategyType.Yearn) {
            return _withdrawFromYearn(strategy, _amount);
        } else if (strategy.strategyType == StrategyType.Convex) {
            return _withdrawFromConvex(strategy, _amount);
        }
        
        return _amount;
    }
    
    function _emergencyWithdrawFromStrategy(uint256 _strategyId, uint256 _amount) 
        internal 
        returns (uint256) 
    {
        // Simplified emergency withdraw - would integrate with actual protocols
        return _withdrawFromStrategy(_strategyId, _amount);
    }
    
    function _harvestFromProtocol(uint256 _strategyId) internal returns (uint256) {
        Strategy memory strategy = strategies[_strategyId];
        
        // Simplified harvest - in reality would call protocol-specific harvest functions
        // For example, claiming COMP rewards from Compound, or CRV from Curve
        
        // Mock implementation
        uint256 mockRewards = (strategy.allocatedAmount * 5) / 100; // 5% APY mock
        uint256 timePassed = block.timestamp - strategy.lastHarvestTime;
        uint256 rewards = (mockRewards * timePassed) / 365 days;
        
        strategies[_strategyId].lastHarvestTime = block.timestamp;
        
        return rewards;
    }
    
    function _getPendingRewards(uint256 _strategyId) internal view returns (uint256) {
        Strategy memory strategy = strategies[_strategyId];
        
        // Mock calculation
        uint256 mockRewards = (strategy.allocatedAmount * 5) / 100; // 5% APY mock
        uint256 timePassed = block.timestamp - strategy.lastHarvestTime;
        
        return (mockRewards * timePassed) / 365 days;
    }
    
    // ============ Protocol Integration Functions (Simplified) ============
    
    function _deployToAave(Strategy memory strategy, uint256 amount) internal {
        // In reality, would interact with Aave's LendingPool
        // lendingPool.deposit(asset, amount, address(this), 0);
        IERC20(strategy.targetAsset).approve(strategy.targetProtocol, amount);
    }
    
    function _withdrawFromAave(Strategy memory strategy, uint256 amount) 
        internal 
        returns (uint256) 
    {
        // In reality: lendingPool.withdraw(asset, amount, address(this));
        return amount;
    }
    
    function _deployToCompound(Strategy memory strategy, uint256 amount) internal {
        // In reality, would mint cTokens
        // cToken.mint(amount);
        IERC20(strategy.targetAsset).approve(strategy.targetProtocol, amount);
    }
    
    function _withdrawFromCompound(Strategy memory strategy, uint256 amount) 
        internal 
        returns (uint256) 
    {
        // In reality: cToken.redeemUnderlying(amount);
        return amount;
    }
    
    function _deployToCurve(Strategy memory strategy, uint256 amount) internal {
        // In reality, would add liquidity to Curve pool
        IERC20(strategy.targetAsset).approve(strategy.targetProtocol, amount);
    }
    
    function _withdrawFromCurve(Strategy memory strategy, uint256 amount) 
        internal 
        returns (uint256) 
    {
        // In reality: curvePool.remove_liquidity_one_coin(amount, coin_index, min_amount);
        return amount;
    }
    
    function _deployToYearn(Strategy memory strategy, uint256 amount) internal {
        // In reality, would deposit to Yearn vault
        // vault.deposit(amount);
        IERC20(strategy.targetAsset).approve(strategy.targetProtocol, amount);
    }
    
    function _withdrawFromYearn(Strategy memory strategy, uint256 amount) 
        internal 
        returns (uint256) 
    {
        // In reality: vault.withdraw(amount);
        return amount;
    }
    
    function _deployToConvex(Strategy memory strategy, uint256 amount) internal {
        // In reality, would stake LP tokens in Convex
        IERC20(strategy.targetAsset).approve(strategy.targetProtocol, amount);
    }
    
    function _withdrawFromConvex(Strategy memory strategy, uint256 amount) 
        internal 
        returns (uint256) 
    {
        // In reality: convexRewards.withdrawAndUnwrap(amount, false);
        return amount;
    }
    
    // ============ View Functions ============
    
    function getUserOptimizationDetails(address _user) 
        external 
        view 
        returns (
            uint256 totalOptimized,
            uint256 totalRewards,
            bool autoCompound,
            uint256 preferredStrategy
        ) 
    {
        UserOptimization storage userOpt = userOptimizations[_user];
        return (
            userOpt.totalOptimized,
            userOpt.totalRewards,
            userOpt.autoCompound,
            userOpt.preferredStrategyId
        );
    }
    
    function getUserStrategyAllocation(address _user, uint256 _strategyId) 
        external 
        view 
        returns (uint256) 
    {
        return userOptimizations[_user].strategyAllocations[_strategyId];
    }
    
    function getStrategyDetails(uint256 _strategyId) 
        external 
        view 
        returns (
            StrategyType strategyType,
            address targetProtocol,
            uint256 allocatedAmount,
            uint256 totalHarvested,
            bool isActive
        ) 
    {
        Strategy memory strategy = strategies[_strategyId];
        return (
            strategy.strategyType,
            strategy.targetProtocol,
            strategy.allocatedAmount,
            strategy.totalHarvested,
            strategy.isActive
        );
    }
    
    function calculateExpectedReturns(uint256 _strategyId, uint256 _amount, uint256 _duration) 
        external 
        view 
        returns (uint256) 
    {
        Strategy memory strategy = strategies[_strategyId];
        
        // Simplified calculation - would use actual protocol rates
        uint256 baseAPY = 500; // 5% base APY in basis points
        
        // Adjust based on strategy type
        if (strategy.strategyType == StrategyType.Yearn) {
            baseAPY = 800; // Higher for yield aggregators
        } else if (strategy.strategyType == StrategyType.Curve) {
            baseAPY = 600; // Stable for Curve
        }
        
        uint256 grossReturns = (_amount * baseAPY * _duration) / (10000 * 365 days);
        uint256 fees = (grossReturns * strategy.performanceFee) / 10000;
        
        return grossReturns - fees;
    }
    
    // ============ Admin Functions ============
    
    function setParameters(OptimizationParams calldata _params) external onlyOwner {
        defaultParams = _params;
    }
    
    function setStrategyParameters(
        StrategyType _type,
        OptimizationParams calldata _params
    ) external onlyOwner {
        strategyParams[_type] = _params;
    }
    
    function setProtocolAdapter(StrategyType _type, address _adapter) external onlyOwner {
        protocolAdapters[_type] = _adapter;
    }
    
    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
    }
    
    function setAuthorized(address _address, bool _authorized) external onlyOwner {
        authorized[_address] = _authorized;
    }
    
    function rescueTokens(address _token, uint256 _amount) external onlyOwner {
        IERC20(_token).transfer(owner, _amount);
    }
}

// Interface for ERC20
interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}
