// Web3 Connection and Contract Management
let provider = null;
let signer = null;
let connected = false;
let contracts = {};

// Contract addresses (would be deployed addresses)
const CONTRACT_ADDRESSES = {
    stakingVault: '0x1234567890123456789012345678901234567890',
    governance: '0x2345678901234567890123456789012345678901',
    yieldOptimizer: '0x3456789012345678901234567890123456789012',
    stakingNFT: '0x4567890123456789012345678901234567890123',
    rewardToken: '0x5678901234567890123456789012345678901234'
};

// Contract ABIs (simplified for demo)
const STAKING_VAULT_ABI = [
    'function stake(uint256 poolId, uint256 amount, uint256 lockPeriodIndex) external',
    'function withdraw(uint256 poolId, uint256 amount) external',
    'function claimRewards(uint256 poolId) external',
    'function compound(uint256 poolId) external',
    'function pendingRewards(uint256 poolId, address user) view returns (uint256)',
    'function getStakeInfo(uint256 poolId, address user) view returns (tuple(uint256 amount, uint256 rewardDebt, uint256 lockedUntil, uint256 lastStakeTime, uint8 tier, uint256 accumulatedRewards))',
];

// Initialize on page load
document.addEventListener('DOMContentLoaded', () => {
    initializeEventListeners();
    updateStats();
    setInterval(updateStats, 10000); // Update stats every 10 seconds
});

// Connect Wallet
async function connectWallet() {
    try {
        if (!window.ethereum) {
            alert('Please install MetaMask or another Web3 wallet!');
            return;
        }

        // Request account access
        provider = new ethers.providers.Web3Provider(window.ethereum);
        await provider.send('eth_requestAccounts', []);
        signer = provider.getSigner();
        
        const address = await signer.getAddress();
        const shortAddress = `${address.slice(0, 6)}...${address.slice(-4)}`;
        document.getElementById('walletAddress').textContent = shortAddress;
        
        connected = true;
        
        // Initialize contracts
        await initializeContracts();
        
        // Load user data
        await loadUserData();
        
        showNotification('Wallet connected successfully!', 'success');
        
    } catch (error) {
        console.error('Error connecting wallet:', error);
        showNotification('Failed to connect wallet', 'error');
    }
}

// Initialize smart contracts
async function initializeContracts() {
    if (!signer) return;
    
    try {
        contracts.stakingVault = new ethers.Contract(
            CONTRACT_ADDRESSES.stakingVault,
            STAKING_VAULT_ABI,
            signer
        );
        
        // Initialize other contracts...
    } catch (error) {
        console.error('Error initializing contracts:', error);
    }
}

// Load user data
async function loadUserData() {
    if (!connected || !contracts.stakingVault) return;
    
    try {
        const address = await signer.getAddress();
        
        // Load staking positions
        // This would fetch real data from the smart contracts
        updateUserPositions();
        
        // Load balances
        const balance = await provider.getBalance(address);
        document.getElementById('balance').textContent = ethers.utils.formatEther(balance);
        
    } catch (error) {
        console.error('Error loading user data:', error);
    }
}

// Stake tokens
async function stakeTokens() {
    if (!connected) {
        showNotification('Please connect your wallet first', 'warning');
        return;
    }
    
    try {
        const poolId = document.getElementById('poolSelect').value;
        const amount = document.getElementById('stakeAmount').value;
        const lockPeriod = document.querySelector('.lock-btn.active')?.dataset.days || 0;
        
        if (!amount || amount <= 0) {
            showNotification('Please enter a valid amount', 'warning');
            return;
        }
        
        // Convert amount to wei
        const amountWei = ethers.utils.parseEther(amount);
        
        // Get lock period index based on days
        const lockPeriodIndex = getLockPeriodIndex(lockPeriod);
        
        showNotification('Confirming transaction...', 'info');
        
        // Call smart contract
        const tx = await contracts.stakingVault.stake(poolId, amountWei, lockPeriodIndex);
        await tx.wait();
        
        showNotification('Staking successful!', 'success');
        
        // Reload user data
        await loadUserData();
        
        // Clear form
        document.getElementById('stakeAmount').value = '';
        
    } catch (error) {
        console.error('Error staking:', error);
        showNotification('Staking failed: ' + error.message, 'error');
    }
}

// Approve tokens
async function approveTokens() {
    if (!connected) {
        showNotification('Please connect your wallet first', 'warning');
        return;
    }
    
    try {
        const amount = document.getElementById('stakeAmount').value;
        if (!amount || amount <= 0) {
            showNotification('Please enter a valid amount', 'warning');
            return;
        }
        
        showNotification('Approving tokens...', 'info');
        
        // In real implementation, would approve ERC20 tokens
        // const token = new ethers.Contract(tokenAddress, ERC20_ABI, signer);
        // const tx = await token.approve(CONTRACT_ADDRESSES.stakingVault, amountWei);
        // await tx.wait();
        
        showNotification('Approval successful!', 'success');
        
    } catch (error) {
        console.error('Error approving:', error);
        showNotification('Approval failed: ' + error.message, 'error');
    }
}

// Helper function to get lock period index
function getLockPeriodIndex(days) {
    const periods = [0, 30, 90, 180, 365];
    return periods.indexOf(parseInt(days));
}

// Update user positions
function updateUserPositions() {
    // In real implementation, would fetch from smart contracts
    // This is mock data for demonstration
    const positions = [
        {
            pool: 'ETH Pool',
            amount: '10.5 ETH',
            rewards: '+0.842 ETH',
            apy: '23.75%',
            locked: true,
            daysRemaining: 87
        },
        {
            pool: 'USDC Pool',
            amount: '5,000 USDC',
            rewards: '+125 USDC',
            apy: '12.0%',
            locked: false
        }
    ];
    
    // Update UI with positions
    // Implementation would update the positions display
}

// Show different sections
function showSection(section) {
    // Hide all sections
    document.querySelectorAll('.section').forEach(s => {
        s.classList.add('hidden');
    });
    
    // Show selected section
    const sectionElement = document.getElementById(`${section}-section`);
    if (sectionElement) {
        sectionElement.classList.remove('hidden');
    }
    
    // Update nav buttons
    document.querySelectorAll('.nav-btn').forEach(btn => {
        btn.classList.remove('text-purple-400', 'font-semibold');
        btn.classList.add('hover:text-purple-400');
    });
    
    event.target.classList.add('text-purple-400', 'font-semibold');
    event.target.classList.remove('hover:text-purple-400');
}

// Show notification
function showNotification(message, type = 'info') {
    const notification = document.getElementById('notification');
    const icon = notification.querySelector('i');
    const text = notification.querySelector('p:last-child');
    
    // Update icon and colors based on type
    icon.className = 'fas text-xl';
    switch(type) {
        case 'success':
            icon.classList.add('fa-check-circle', 'text-green-400');
            break;
        case 'error':
            icon.classList.add('fa-exclamation-circle', 'text-red-400');
            break;
        case 'warning':
            icon.classList.add('fa-exclamation-triangle', 'text-yellow-400');
            break;
        default:
            icon.classList.add('fa-info-circle', 'text-blue-400');
    }
    
    text.textContent = message;
    
    // Show notification
    notification.classList.remove('hidden', 'translate-x-full');
    
    // Hide after 5 seconds
    setTimeout(() => {
        notification.classList.add('translate-x-full');
        setTimeout(() => {
            notification.classList.add('hidden');
        }, 300);
    }, 5000);
}

// Update stats
function updateStats() {
    // Animate counter updates
    animateValue('tvl', 45678912, 46234567, 2000);
    animateValue('stakers', 12456, 12467, 2000);
    animateValue('apy', 125.6, 126.2, 2000);
    animateValue('rewards', 8234567, 8245678, 2000);
}

// Animate value changes
function animateValue(id, start, end, duration) {
    const element = document.getElementById(id);
    if (!element) return;
    
    const range = end - start;
    const increment = range / (duration / 10);
    let current = start;
    
    const timer = setInterval(() => {
        current += increment;
        if ((increment > 0 && current >= end) || (increment < 0 && current <= end)) {
            current = end;
            clearInterval(timer);
        }
        
        if (id === 'apy') {
            element.textContent = current.toFixed(1);
        } else {
            element.textContent = Math.floor(current).toLocaleString();
        }
    }, 10);
}

// Initialize event listeners
function initializeEventListeners() {
    // Lock period buttons
    document.querySelectorAll('.lock-btn').forEach(btn => {
        btn.addEventListener('click', (e) => {
            document.querySelectorAll('.lock-btn').forEach(b => {
                b.classList.remove('bg-purple-500/20', 'border-purple-400');
                b.classList.add('bg-black/50', 'border-purple-500/30');
            });
            btn.classList.remove('bg-black/50', 'border-purple-500/30');
            btn.classList.add('bg-purple-500/20', 'border-purple-400');
            
            // Update estimated returns based on lock period
            updateEstimatedReturns();
        });
    });
    
    // Amount input listener
    const amountInput = document.getElementById('stakeAmount');
    if (amountInput) {
        amountInput.addEventListener('input', updateEstimatedReturns);
    }
    
    // Pool select listener
    const poolSelect = document.getElementById('poolSelect');
    if (poolSelect) {
        poolSelect.addEventListener('change', updateEstimatedReturns);
    }
    
    // MAX button
    document.querySelector('button:contains("MAX")')?.addEventListener('click', () => {
        const balance = document.getElementById('balance').textContent;
        document.getElementById('stakeAmount').value = balance;
        updateEstimatedReturns();
    });
}

// Update estimated returns
function updateEstimatedReturns() {
    const amount = parseFloat(document.getElementById('stakeAmount').value) || 0;
    const lockDays = parseInt(document.querySelector('.lock-btn.active')?.dataset.days) || 0;
    
    // Calculate multipliers
    let lockMultiplier = 1;
    if (lockDays >= 365) lockMultiplier = 2;
    else if (lockDays >= 180) lockMultiplier = 1.5;
    else if (lockDays >= 90) lockMultiplier = 1.25;
    else if (lockDays >= 30) lockMultiplier = 1.1;
    
    // Base APY (would come from smart contract)
    const baseAPY = 15;
    const tierBonus = 5; // Based on user tier
    const nftBoost = 10; // Based on NFT holdings
    
    const totalAPY = baseAPY * lockMultiplier + tierBonus + nftBoost;
    const dailyRewards = (amount * totalAPY / 100 / 365).toFixed(4);
    
    // Update UI
    // Would update the estimated returns display
}

// Check for wallet changes
if (window.ethereum) {
    window.ethereum.on('accountsChanged', (accounts) => {
        if (accounts.length === 0) {
            connected = false;
            document.getElementById('walletAddress').textContent = 'Connect Wallet';
        } else {
            connectWallet();
        }
    });
    
    window.ethereum.on('chainChanged', () => {
        window.location.reload();
    });
}

// Export functions for HTML onclick handlers
window.connectWallet = connectWallet;
window.stakeTokens = stakeTokens;
window.approveTokens = approveTokens;
window.showSection = showSection;
