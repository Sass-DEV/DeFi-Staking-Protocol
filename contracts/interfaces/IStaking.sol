// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title IStaking
 * @dev Interface for staking contract interactions
 */
interface IStaking {
    // Structs
    struct StakeInfo {
        uint256 amount;
        uint256 rewardDebt;
        uint256 lockedUntil;
        uint256 lastStakeTime;
        uint8 tier;
        uint256 accumulatedRewards;
    }
    
    struct PoolInfo {
        address tokenAddress;
        uint256 totalStaked;
        uint256 rewardPerShare;
        uint256 lastRewardBlock;
        uint256 allocPoint;
        uint256 minStakeAmount;
        uint256 emergencyWithdrawFee;
        bool isActive;
    }
    
    // Events
    event Staked(address indexed user, uint256 indexed poolId, uint256 amount, uint256 lockPeriod);
    event Withdrawn(address indexed user, uint256 indexed poolId, uint256 amount);
    event RewardsClaimed(address indexed user, uint256 indexed poolId, uint256 reward);
    event CompoundExecuted(address indexed user, uint256 indexed poolId, uint256 amount);
    
    // Core functions
    function stake(uint256 poolId, uint256 amount, uint256 lockPeriodIndex) external;
    function withdraw(uint256 poolId, uint256 amount) external;
    function claimRewards(uint256 poolId) external;
    function compound(uint256 poolId) external;
    function emergencyWithdraw(uint256 poolId) external;
    
    // View functions
    function pendingRewards(uint256 poolId, address user) external view returns (uint256);
    function getStakeInfo(uint256 poolId, address user) external view returns (StakeInfo memory);
    function getPoolInfo(uint256 poolId) external view returns (PoolInfo memory);
}

/**
 * @title IGovernance
 * @dev Interface for governance contract
 */
interface IGovernance {
    enum ProposalState {
        Pending,
        Active,
        Canceled,
        Defeated,
        Succeeded,
        Queued,
        Expired,
        Executed
    }
    
    enum VoteType {
        Against,
        For,
        Abstain
    }
    
    function propose(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description
    ) external returns (uint256);
    
    function castVote(uint256 proposalId, VoteType voteType) external;
    function delegate(address delegatee) external;
    function state(uint256 proposalId) external view returns (ProposalState);
    function getPriorVotes(address account, uint256 blockNumber) external view returns (uint256);
}

/**
 * @title IYieldOptimizer
 * @dev Interface for yield optimizer contract
 */
interface IYieldOptimizer {
    enum StrategyType {
        None,
        Aave,
        Compound,
        Curve,
        Yearn,
        Convex
    }
    
    function optimizeFunds(uint256 strategyId, uint256 amount) external;
    function withdrawOptimized(uint256 strategyId, uint256 amount) external;
    function enableAutoCompound(uint256 preferredStrategyId) external;
    function disableAutoCompound() external;
    function getUserOptimizationDetails(address user) external view returns (
        uint256 totalOptimized,
        uint256 totalRewards,
        bool autoCompound,
        uint256 preferredStrategy
    );
}

/**
 * @title IStakingNFT
 * @dev Interface for NFT rewards contract
 */
interface IStakingNFT {
    function mintTierNFT(address to, uint256 tier, uint256 stakedAmount) external returns (uint256);
    function updateNFT(uint256 tokenId, uint256 newTier, uint256 newAmount) external;
    function burnNFT(uint256 tokenId) external;
    function getNFTDetails(uint256 tokenId) external view returns (
        uint256 tier,
        uint256 stakedAmount,
        uint256 multiplier,
        uint256 mintedAt
    );
}
