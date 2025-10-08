// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "../interfaces/IStaking.sol";
import "../libraries/StakingMath.sol";

/**
 * @title StakingVault
 * @dev Multi-asset staking contract with dynamic APY and compound rewards
 * @author Talent Protocol Builder
 */
contract StakingVault {
    using StakingMath for uint256;
    
    // ============ State Variables ============
    
    struct StakeInfo {
        uint256 amount;
        uint256 rewardDebt;
        uint256 lockedUntil;
        uint256 lastStakeTime;
        uint8 tier; // 0: Bronze, 1: Silver, 2: Gold, 3: Platinum
        uint256 accumulatedRewards;
    }
    
    struct PoolInfo {
        address tokenAddress;
        uint256 totalStaked;
        uint256 rewardPerShare;
        uint256 lastRewardBlock;
        uint256 allocPoint; // How many allocation points assigned to this pool
        uint256 minStakeAmount;
        uint256 emergencyWithdrawFee; // In basis points (100 = 1%)
        bool isActive;
    }
    
    struct LockPeriod {
        uint256 duration;
        uint256 bonusMultiplier; // In basis points (10000 = 100%)
    }
    
    // Pool and staking mappings
    mapping(uint256 => PoolInfo) public pools;
    mapping(uint256 => mapping(address => StakeInfo)) public stakes;
    mapping(address => uint256[]) public userPools;
    
    // Lock period configurations
    LockPeriod[] public lockPeriods;
    
    // Governance and control
    address public owner;
    address public rewardDistributor;
    address public yieldOptimizer;
    bool public paused;
    
    // Reward configurations
    uint256 public totalAllocPoint;
    uint256 public rewardPerBlock;
    uint256 public constant PRECISION = 1e12;
    uint256 public poolIdCounter;
    
    // Fee configurations
    uint256 public performanceFee = 200; // 2%
    uint256 public treasuryFee = 100; // 1%
    address public treasury;
    
    // Security
    mapping(address => bool) public authorized;
    uint256 private locked;
    
    // ============ Events ============
    
    event Staked(address indexed user, uint256 indexed poolId, uint256 amount, uint256 lockPeriod);
    event Withdrawn(address indexed user, uint256 indexed poolId, uint256 amount);
    event RewardsClaimed(address indexed user, uint256 indexed poolId, uint256 reward);
    event EmergencyWithdraw(address indexed user, uint256 indexed poolId, uint256 amount, uint256 fee);
    event PoolAdded(uint256 indexed poolId, address token, uint256 allocPoint);
    event PoolUpdated(uint256 indexed poolId, uint256 allocPoint);
    event CompoundExecuted(address indexed user, uint256 indexed poolId, uint256 amount);
    
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
        require(!paused, "Contract paused");
        _;
    }
    
    modifier nonReentrant() {
        require(locked == 0, "Reentrant call");
        locked = 1;
        _;
        locked = 0;
    }
    
    modifier validPool(uint256 _poolId) {
        require(_poolId < poolIdCounter && pools[_poolId].isActive, "Invalid pool");
        _;
    }
    
    // ============ Constructor ============
    
    constructor(address _treasury, uint256 _rewardPerBlock) {
        owner = msg.sender;
        treasury = _treasury;
        rewardPerBlock = _rewardPerBlock;
        
        // Initialize lock periods
        lockPeriods.push(LockPeriod(0, 10000)); // No lock: 100% rewards
        lockPeriods.push(LockPeriod(30 days, 11000)); // 30 days: 110% rewards
        lockPeriods.push(LockPeriod(90 days, 12500)); // 90 days: 125% rewards
        lockPeriods.push(LockPeriod(180 days, 15000)); // 180 days: 150% rewards
        lockPeriods.push(LockPeriod(365 days, 20000)); // 365 days: 200% rewards
    }
    
    // ============ Pool Management ============
    
    function addPool(
        address _token,
        uint256 _allocPoint,
        uint256 _minStakeAmount,
        uint256 _emergencyWithdrawFee
    ) external onlyOwner {
        require(_token != address(0), "Invalid token");
        require(_emergencyWithdrawFee <= 2000, "Fee too high"); // Max 20%
        
        totalAllocPoint += _allocPoint;
        
        pools[poolIdCounter] = PoolInfo({
            tokenAddress: _token,
            totalStaked: 0,
            rewardPerShare: 0,
            lastRewardBlock: block.number,
            allocPoint: _allocPoint,
            minStakeAmount: _minStakeAmount,
            emergencyWithdrawFee: _emergencyWithdrawFee,
            isActive: true
        });
        
        emit PoolAdded(poolIdCounter, _token, _allocPoint);
        poolIdCounter++;
    }
    
    function updatePool(uint256 _poolId, uint256 _allocPoint) 
        external 
        onlyOwner 
        validPool(_poolId) 
    {
        updateRewards(_poolId);
        
        totalAllocPoint = totalAllocPoint - pools[_poolId].allocPoint + _allocPoint;
        pools[_poolId].allocPoint = _allocPoint;
        
        emit PoolUpdated(_poolId, _allocPoint);
    }
    
    // ============ Staking Functions ============
    
    function stake(uint256 _poolId, uint256 _amount, uint256 _lockPeriodIndex) 
        external 
        whenNotPaused 
        nonReentrant 
        validPool(_poolId) 
    {
        require(_amount >= pools[_poolId].minStakeAmount, "Below minimum");
        require(_lockPeriodIndex < lockPeriods.length, "Invalid lock period");
        
        PoolInfo storage pool = pools[_poolId];
        StakeInfo storage userStake = stakes[_poolId][msg.sender];
        
        updateRewards(_poolId);
        
        // Claim pending rewards if any
        if (userStake.amount > 0) {
            uint256 pending = _calculatePendingRewards(_poolId, msg.sender);
            if (pending > 0) {
                userStake.accumulatedRewards += pending;
            }
        }
        
        // Transfer tokens from user
        IERC20(pool.tokenAddress).transferFrom(msg.sender, address(this), _amount);
        
        // Update stake info
        userStake.amount += _amount;
        userStake.rewardDebt = (userStake.amount * pool.rewardPerShare) / PRECISION;
        userStake.lastStakeTime = block.timestamp;
        
        // Set lock period
        if (_lockPeriodIndex > 0) {
            uint256 lockDuration = lockPeriods[_lockPeriodIndex].duration;
            userStake.lockedUntil = block.timestamp + lockDuration;
        }
        
        // Update tier based on total staked
        _updateUserTier(_poolId, msg.sender);
        
        // Update pool total
        pool.totalStaked += _amount;
        
        // Add pool to user's active pools
        _addUserPool(msg.sender, _poolId);
        
        emit Staked(msg.sender, _poolId, _amount, _lockPeriodIndex);
    }
    
    function withdraw(uint256 _poolId, uint256 _amount) 
        external 
        nonReentrant 
        validPool(_poolId) 
    {
        StakeInfo storage userStake = stakes[_poolId][msg.sender];
        require(userStake.amount >= _amount, "Insufficient balance");
        require(block.timestamp >= userStake.lockedUntil, "Still locked");
        
        PoolInfo storage pool = pools[_poolId];
        
        updateRewards(_poolId);
        
        // Calculate and transfer pending rewards
        uint256 pending = _calculatePendingRewards(_poolId, msg.sender);
        uint256 totalRewards = pending + userStake.accumulatedRewards;
        
        if (totalRewards > 0) {
            _transferRewards(msg.sender, totalRewards);
            userStake.accumulatedRewards = 0;
        }
        
        // Update stake
        userStake.amount -= _amount;
        userStake.rewardDebt = (userStake.amount * pool.rewardPerShare) / PRECISION;
        
        // Update pool total
        pool.totalStaked -= _amount;
        
        // Update tier
        _updateUserTier(_poolId, msg.sender);
        
        // Transfer tokens back to user
        IERC20(pool.tokenAddress).transfer(msg.sender, _amount);
        
        emit Withdrawn(msg.sender, _poolId, _amount);
    }
    
    function emergencyWithdraw(uint256 _poolId) 
        external 
        nonReentrant 
        validPool(_poolId) 
    {
        StakeInfo storage userStake = stakes[_poolId][msg.sender];
        require(userStake.amount > 0, "No stake");
        
        PoolInfo storage pool = pools[_poolId];
        uint256 amount = userStake.amount;
        
        // Calculate fee
        uint256 fee = 0;
        if (block.timestamp < userStake.lockedUntil) {
            fee = (amount * pool.emergencyWithdrawFee) / 10000;
        }
        
        // Reset user stake
        userStake.amount = 0;
        userStake.rewardDebt = 0;
        userStake.accumulatedRewards = 0;
        userStake.lockedUntil = 0;
        
        // Update pool total
        pool.totalStaked -= amount;
        
        // Transfer fee to treasury
        if (fee > 0) {
            IERC20(pool.tokenAddress).transfer(treasury, fee);
        }
        
        // Transfer remaining to user
        IERC20(pool.tokenAddress).transfer(msg.sender, amount - fee);
        
        emit EmergencyWithdraw(msg.sender, _poolId, amount, fee);
    }
    
    function claimRewards(uint256 _poolId) 
        external 
        nonReentrant 
        validPool(_poolId) 
    {
        updateRewards(_poolId);
        
        StakeInfo storage userStake = stakes[_poolId][msg.sender];
        require(userStake.amount > 0, "No stake");
        
        uint256 pending = _calculatePendingRewards(_poolId, msg.sender);
        uint256 totalRewards = pending + userStake.accumulatedRewards;
        
        require(totalRewards > 0, "No rewards");
        
        userStake.accumulatedRewards = 0;
        userStake.rewardDebt = (userStake.amount * pools[_poolId].rewardPerShare) / PRECISION;
        
        _transferRewards(msg.sender, totalRewards);
        
        emit RewardsClaimed(msg.sender, _poolId, totalRewards);
    }
    
    function compound(uint256 _poolId) 
        external 
        nonReentrant 
        validPool(_poolId) 
    {
        updateRewards(_poolId);
        
        StakeInfo storage userStake = stakes[_poolId][msg.sender];
        require(userStake.amount > 0, "No stake");
        
        uint256 pending = _calculatePendingRewards(_poolId, msg.sender);
        uint256 totalRewards = pending + userStake.accumulatedRewards;
        
        require(totalRewards > 0, "No rewards to compound");
        
        // Reset accumulated rewards
        userStake.accumulatedRewards = 0;
        
        // Add rewards to stake
        userStake.amount += totalRewards;
        userStake.rewardDebt = (userStake.amount * pools[_poolId].rewardPerShare) / PRECISION;
        
        // Update pool total
        pools[_poolId].totalStaked += totalRewards;
        
        // Update tier
        _updateUserTier(_poolId, msg.sender);
        
        emit CompoundExecuted(msg.sender, _poolId, totalRewards);
    }
    
    // ============ View Functions ============
    
    function pendingRewards(uint256 _poolId, address _user) 
        external 
        view 
        returns (uint256) 
    {
        PoolInfo memory pool = pools[_poolId];
        StakeInfo memory userStake = stakes[_poolId][_user];
        
        uint256 rewardPerShare = pool.rewardPerShare;
        
        if (block.number > pool.lastRewardBlock && pool.totalStaked > 0) {
            uint256 blocks = block.number - pool.lastRewardBlock;
            uint256 poolReward = (blocks * rewardPerBlock * pool.allocPoint) / totalAllocPoint;
            rewardPerShare += (poolReward * PRECISION) / pool.totalStaked;
        }
        
        uint256 pending = ((userStake.amount * rewardPerShare) / PRECISION) - userStake.rewardDebt;
        
        // Apply lock period multiplier
        uint256 multiplier = _getLockMultiplier(_poolId, _user);
        pending = (pending * multiplier) / 10000;
        
        // Apply tier bonus
        uint256 tierBonus = _getTierBonus(userStake.tier);
        pending = (pending * tierBonus) / 10000;
        
        return pending + userStake.accumulatedRewards;
    }
    
    function getUserPools(address _user) external view returns (uint256[] memory) {
        return userPools[_user];
    }
    
    function getPoolInfo(uint256 _poolId) external view returns (PoolInfo memory) {
        return pools[_poolId];
    }
    
    function getStakeInfo(uint256 _poolId, address _user) external view returns (StakeInfo memory) {
        return stakes[_poolId][_user];
    }
    
    // ============ Internal Functions ============
    
    function updateRewards(uint256 _poolId) internal {
        PoolInfo storage pool = pools[_poolId];
        
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        
        if (pool.totalStaked == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        
        uint256 blocks = block.number - pool.lastRewardBlock;
        uint256 poolReward = (blocks * rewardPerBlock * pool.allocPoint) / totalAllocPoint;
        
        pool.rewardPerShare += (poolReward * PRECISION) / pool.totalStaked;
        pool.lastRewardBlock = block.number;
    }
    
    function _calculatePendingRewards(uint256 _poolId, address _user) 
        internal 
        view 
        returns (uint256) 
    {
        PoolInfo memory pool = pools[_poolId];
        StakeInfo memory userStake = stakes[_poolId][_user];
        
        uint256 pending = ((userStake.amount * pool.rewardPerShare) / PRECISION) - userStake.rewardDebt;
        
        // Apply multipliers
        uint256 multiplier = _getLockMultiplier(_poolId, _user);
        pending = (pending * multiplier) / 10000;
        
        uint256 tierBonus = _getTierBonus(userStake.tier);
        pending = (pending * tierBonus) / 10000;
        
        return pending;
    }
    
    function _getLockMultiplier(uint256 _poolId, address _user) 
        internal 
        view 
        returns (uint256) 
    {
        StakeInfo memory userStake = stakes[_poolId][_user];
        
        if (userStake.lockedUntil == 0) {
            return 10000; // 100%
        }
        
        // Find the appropriate multiplier based on lock duration
        uint256 lockDuration = userStake.lockedUntil - userStake.lastStakeTime;
        
        for (uint256 i = lockPeriods.length - 1; i > 0; i--) {
            if (lockDuration >= lockPeriods[i].duration) {
                return lockPeriods[i].bonusMultiplier;
            }
        }
        
        return 10000; // Default 100%
    }
    
    function _getTierBonus(uint8 _tier) internal pure returns (uint256) {
        if (_tier == 0) return 10000; // Bronze: 100%
        if (_tier == 1) return 10500; // Silver: 105%
        if (_tier == 2) return 11000; // Gold: 110%
        if (_tier == 3) return 12000; // Platinum: 120%
        return 10000;
    }
    
    function _updateUserTier(uint256 _poolId, address _user) internal {
        StakeInfo storage userStake = stakes[_poolId][_user];
        uint256 amount = userStake.amount;
        
        if (amount >= 100000 * 10**18) {
            userStake.tier = 3; // Platinum
        } else if (amount >= 50000 * 10**18) {
            userStake.tier = 2; // Gold
        } else if (amount >= 10000 * 10**18) {
            userStake.tier = 1; // Silver
        } else {
            userStake.tier = 0; // Bronze
        }
    }
    
    function _addUserPool(address _user, uint256 _poolId) internal {
        uint256[] storage pools = userPools[_user];
        for (uint256 i = 0; i < pools.length; i++) {
            if (pools[i] == _poolId) {
                return; // Already exists
            }
        }
        pools.push(_poolId);
    }
    
    function _transferRewards(address _to, uint256 _amount) internal {
        // Apply performance fee
        uint256 perfFee = (_amount * performanceFee) / 10000;
        uint256 treasFee = (_amount * treasuryFee) / 10000;
        
        uint256 netAmount = _amount - perfFee - treasFee;
        
        // Transfer fees
        if (perfFee > 0) {
            IERC20(pools[0].tokenAddress).transfer(owner, perfFee);
        }
        if (treasFee > 0) {
            IERC20(pools[0].tokenAddress).transfer(treasury, treasFee);
        }
        
        // Transfer net rewards to user
        IERC20(pools[0].tokenAddress).transfer(_to, netAmount);
    }
    
    // ============ Admin Functions ============
    
    function setRewardPerBlock(uint256 _rewardPerBlock) external onlyOwner {
        rewardPerBlock = _rewardPerBlock;
    }
    
    function setFees(uint256 _performanceFee, uint256 _treasuryFee) external onlyOwner {
        require(_performanceFee <= 500, "Performance fee too high"); // Max 5%
        require(_treasuryFee <= 300, "Treasury fee too high"); // Max 3%
        performanceFee = _performanceFee;
        treasuryFee = _treasuryFee;
    }
    
    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
    }
    
    function setAuthorized(address _address, bool _authorized) external onlyOwner {
        authorized[_address] = _authorized;
    }
    
    function setContracts(address _rewardDistributor, address _yieldOptimizer) external onlyOwner {
        rewardDistributor = _rewardDistributor;
        yieldOptimizer = _yieldOptimizer;
        authorized[_rewardDistributor] = true;
        authorized[_yieldOptimizer] = true;
    }
}

// Interface for ERC20 tokens
interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}
