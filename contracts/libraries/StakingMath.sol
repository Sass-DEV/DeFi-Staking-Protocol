// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title StakingMath
 * @dev Mathematical operations for staking calculations with safety checks
 * @author Talent Protocol Builder
 */
library StakingMath {
    uint256 constant PRECISION = 1e18;
    uint256 constant PERCENT_PRECISION = 10000;
    uint256 constant SECONDS_PER_YEAR = 365 days;
    
    /**
     * @dev Calculates compound interest
     * @param principal Initial amount
     * @param rate Interest rate (in basis points)
     * @param time Time period in seconds
     * @param compoundsPerYear Number of compounds per year
     * @return Compound interest amount
     */
    function calculateCompoundInterest(
        uint256 principal,
        uint256 rate,
        uint256 time,
        uint256 compoundsPerYear
    ) internal pure returns (uint256) {
        if (principal == 0 || rate == 0 || time == 0) {
            return principal;
        }
        
        // Convert rate from basis points to decimal
        uint256 ratePerCompound = (rate * PRECISION) / (PERCENT_PRECISION * compoundsPerYear);
        
        // Calculate number of compounds
        uint256 compounds = (time * compoundsPerYear) / SECONDS_PER_YEAR;
        
        // Calculate compound factor: (1 + r/n)^(nt)
        uint256 compoundFactor = PRECISION + ratePerCompound;
        uint256 result = principal;
        
        // Apply compound interest
        for (uint256 i = 0; i < compounds; i++) {
            result = (result * compoundFactor) / PRECISION;
        }
        
        return result;
    }
    
    /**
     * @dev Calculates APY from APR
     * @param apr Annual percentage rate (in basis points)
     * @param compoundsPerYear Number of compounds per year
     * @return apy Annual percentage yield (in basis points)
     */
    function aprToApy(uint256 apr, uint256 compoundsPerYear) 
        internal 
        pure 
        returns (uint256 apy) 
    {
        if (apr == 0 || compoundsPerYear == 0) {
            return apr;
        }
        
        // APY = (1 + APR/n)^n - 1
        uint256 ratePerCompound = (apr * PRECISION) / (PERCENT_PRECISION * compoundsPerYear);
        uint256 compoundFactor = PRECISION + ratePerCompound;
        
        uint256 result = PRECISION;
        for (uint256 i = 0; i < compoundsPerYear; i++) {
            result = (result * compoundFactor) / PRECISION;
        }
        
        // Convert back to basis points
        apy = ((result - PRECISION) * PERCENT_PRECISION) / PRECISION;
    }
    
    /**
     * @dev Calculates rewards based on stake amount and time
     * @param stakeAmount Amount staked
     * @param rewardRate Reward rate per second (in wei)
     * @param timeStaked Time staked in seconds
     * @return rewards Amount of rewards earned
     */
    function calculateRewards(
        uint256 stakeAmount,
        uint256 rewardRate,
        uint256 timeStaked
    ) internal pure returns (uint256 rewards) {
        if (stakeAmount == 0 || rewardRate == 0 || timeStaked == 0) {
            return 0;
        }
        
        rewards = (stakeAmount * rewardRate * timeStaked) / PRECISION;
    }
    
    /**
     * @dev Calculates tier multiplier based on staked amount
     * @param amount Staked amount
     * @return multiplier Tier multiplier (in basis points)
     */
    function getTierMultiplier(uint256 amount) internal pure returns (uint256 multiplier) {
        if (amount >= 1000000 * 10**18) {
            return 15000; // 150% for Whale tier
        } else if (amount >= 500000 * 10**18) {
            return 13000; // 130% for Diamond tier
        } else if (amount >= 100000 * 10**18) {
            return 12000; // 120% for Platinum tier
        } else if (amount >= 50000 * 10**18) {
            return 11000; // 110% for Gold tier
        } else if (amount >= 10000 * 10**18) {
            return 10500; // 105% for Silver tier
        } else {
            return 10000; // 100% for Bronze tier
        }
    }
    
    /**
     * @dev Calculates lock bonus based on lock duration
     * @param duration Lock duration in seconds
     * @return bonus Lock bonus multiplier (in basis points)
     */
    function getLockBonus(uint256 duration) internal pure returns (uint256 bonus) {
        if (duration >= 365 days) {
            return 20000; // 200% for 1 year
        } else if (duration >= 180 days) {
            return 15000; // 150% for 6 months
        } else if (duration >= 90 days) {
            return 12500; // 125% for 3 months
        } else if (duration >= 30 days) {
            return 11000; // 110% for 1 month
        } else if (duration >= 7 days) {
            return 10250; // 102.5% for 1 week
        } else {
            return 10000; // 100% for no lock
        }
    }
    
    /**
     * @dev Calculates impermanent loss for liquidity providers
     * @param initialPrice Initial price ratio
     * @param currentPrice Current price ratio
     * @return loss Impermanent loss percentage (in basis points)
     */
    function calculateImpermanentLoss(
        uint256 initialPrice,
        uint256 currentPrice
    ) internal pure returns (uint256 loss) {
        if (initialPrice == 0 || currentPrice == 0) {
            return 0;
        }
        
        // Calculate price ratio
        uint256 priceRatio = (currentPrice * PRECISION) / initialPrice;
        
        // IL = 2 * sqrt(priceRatio) / (1 + priceRatio) - 1
        uint256 sqrtRatio = sqrt(priceRatio * PRECISION);
        uint256 numerator = 2 * sqrtRatio;
        uint256 denominator = PRECISION + priceRatio;
        
        if (denominator == 0) {
            return 0;
        }
        
        uint256 ilFactor = (numerator * PRECISION) / denominator;
        
        if (ilFactor >= PRECISION) {
            return 0; // No loss
        }
        
        // Convert to basis points
        loss = ((PRECISION - ilFactor) * PERCENT_PRECISION) / PRECISION;
    }
    
    /**
     * @dev Calculates penalty for early withdrawal
     * @param amount Withdrawal amount
     * @param timeRemaining Time remaining in lock period
     * @param totalLockTime Total lock time
     * @return penalty Penalty amount
     */
    function calculateEarlyWithdrawPenalty(
        uint256 amount,
        uint256 timeRemaining,
        uint256 totalLockTime
    ) internal pure returns (uint256 penalty) {
        if (timeRemaining == 0 || totalLockTime == 0) {
            return 0;
        }
        
        // Maximum penalty is 30%
        uint256 maxPenalty = 3000; // 30% in basis points
        
        // Penalty decreases linearly with time
        uint256 penaltyRate = (maxPenalty * timeRemaining) / totalLockTime;
        
        penalty = (amount * penaltyRate) / PERCENT_PRECISION;
    }
    
    /**
     * @dev Safely adds two numbers, reverting on overflow
     */
    function safeAdd(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 c = a + b;
        require(c >= a, "SafeMath: addition overflow");
        return c;
    }
    
    /**
     * @dev Safely subtracts two numbers, reverting on underflow
     */
    function safeSub(uint256 a, uint256 b) internal pure returns (uint256) {
        require(b <= a, "SafeMath: subtraction underflow");
        uint256 c = a - b;
        return c;
    }
    
    /**
     * @dev Safely multiplies two numbers, reverting on overflow
     */
    function safeMul(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a == 0) {
            return 0;
        }
        uint256 c = a * b;
        require(c / a == b, "SafeMath: multiplication overflow");
        return c;
    }
    
    /**
     * @dev Safely divides two numbers, reverting on division by zero
     */
    function safeDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        require(b > 0, "SafeMath: division by zero");
        uint256 c = a / b;
        return c;
    }
    
    /**
     * @dev Returns the smaller of two numbers
     */
    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
    
    /**
     * @dev Returns the larger of two numbers
     */
    function max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }
    
    /**
     * @dev Calculates percentage of a value
     * @param value The value to calculate percentage of
     * @param percentage The percentage (in basis points)
     * @return The calculated percentage amount
     */
    function percentageOf(uint256 value, uint256 percentage) 
        internal 
        pure 
        returns (uint256) 
    {
        return (value * percentage) / PERCENT_PRECISION;
    }
    
    /**
     * @dev Calculates the square root of a number
     * @param x The number to calculate square root of
     * @return y The square root
     */
    function sqrt(uint256 x) internal pure returns (uint256 y) {
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }
    
    /**
     * @dev Calculates power of a number
     * @param base Base number
     * @param exponent Exponent
     * @return result Base raised to exponent
     */
    function pow(uint256 base, uint256 exponent) internal pure returns (uint256 result) {
        if (exponent == 0) {
            return 1;
        }
        
        result = base;
        for (uint256 i = 1; i < exponent; i++) {
            result = safeMul(result, base);
        }
    }
    
    /**
     * @dev Calculates weighted average
     * @param values Array of values
     * @param weights Array of weights
     * @return average Weighted average
     */
    function weightedAverage(
        uint256[] memory values,
        uint256[] memory weights
    ) internal pure returns (uint256 average) {
        require(values.length == weights.length, "Length mismatch");
        
        uint256 totalWeight = 0;
        uint256 weightedSum = 0;
        
        for (uint256 i = 0; i < values.length; i++) {
            weightedSum = safeAdd(weightedSum, safeMul(values[i], weights[i]));
            totalWeight = safeAdd(totalWeight, weights[i]);
        }
        
        if (totalWeight == 0) {
            return 0;
        }
        
        average = safeDiv(weightedSum, totalWeight);
    }
    
    /**
     * @dev Calculates share of rewards based on stake proportion
     * @param userStake User's stake amount
     * @param totalStake Total staked amount
     * @param totalRewards Total rewards to distribute
     * @return userRewards User's share of rewards
     */
    function calculateShareOfRewards(
        uint256 userStake,
        uint256 totalStake,
        uint256 totalRewards
    ) internal pure returns (uint256 userRewards) {
        if (userStake == 0 || totalStake == 0 || totalRewards == 0) {
            return 0;
        }
        
        userRewards = (userStake * totalRewards) / totalStake;
    }
    
    /**
     * @dev Calculates boost factor for voting power
     * @param stakeAmount Amount staked
     * @param lockDuration Lock duration in seconds
     * @return boostFactor Voting power boost factor (in basis points)
     */
    function calculateVotingBoost(
        uint256 stakeAmount,
        uint256 lockDuration
    ) internal pure returns (uint256 boostFactor) {
        uint256 tierMultiplier = getTierMultiplier(stakeAmount);
        uint256 lockBonus = getLockBonus(lockDuration);
        
        // Combine multipliers (both in basis points)
        // Result is also in basis points
        boostFactor = (tierMultiplier * lockBonus) / PERCENT_PRECISION;
    }
}
