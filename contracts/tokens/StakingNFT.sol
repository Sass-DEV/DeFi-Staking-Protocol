// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "../interfaces/IStaking.sol";
import "../libraries/StakingMath.sol";

/**
 * @title StakingNFT
 * @dev Dynamic NFTs that evolve based on staking behavior
 * @author Talent Protocol Builder
 */
contract StakingNFT {
    using StakingMath for uint256;
    
    // ============ Types ============
    
    enum NFTTier {
        Bronze,
        Silver,
        Gold,
        Platinum,
        Diamond,
        Legendary
    }
    
    struct NFTMetadata {
        uint256 tokenId;
        address owner;
        NFTTier tier;
        uint256 stakedAmount;
        uint256 totalRewardsEarned;
        uint256 stakingDuration;
        uint256 multiplier;
        uint256 mintedAt;
        uint256 lastUpdated;
        string imageURI;
        bool isTransferable;
        uint256 power; // Voting power boost
    }
    
    struct TierConfig {
        uint256 minStake;
        uint256 minDuration;
        uint256 multiplierBoost;
        uint256 votingPowerBoost;
        string baseURI;
        bool transferable;
    }
    
    // ============ State Variables ============
    
    // NFT tracking
    mapping(uint256 => NFTMetadata) public nftMetadata;
    mapping(address => uint256[]) public userNFTs;
    mapping(address => mapping(NFTTier => uint256)) public userTierCounts;
    
    // Tier configurations
    mapping(NFTTier => TierConfig) public tierConfigs;
    
    // Core state
    uint256 public tokenIdCounter;
    uint256 public totalSupply;
    address public owner;
    address public stakingVault;
    
    // NFT properties
    string public name = "DeFi Staking NFT";
    string public symbol = "DSNFT";
    string public baseTokenURI;
    
    // Transfer and approval mappings (ERC721-like)
    mapping(address => mapping(address => bool)) private operatorApprovals;
    mapping(uint256 => address) private tokenApprovals;
    
    // Special NFTs
    mapping(uint256 => bool) public isSpecialEdition;
    mapping(address => bool) public hasFounderNFT;
    uint256 public founderNFTCount;
    uint256 public constant MAX_FOUNDER_NFTS = 100;
    
    // ============ Events ============
    
    event NFTMinted(address indexed to, uint256 indexed tokenId, NFTTier tier);
    event NFTUpgraded(uint256 indexed tokenId, NFTTier oldTier, NFTTier newTier);
    event NFTBurned(uint256 indexed tokenId, address indexed owner);
    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event Approval(address indexed owner, address indexed approved, uint256 indexed tokenId);
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);
    event MetadataUpdated(uint256 indexed tokenId);
    
    // ============ Modifiers ============
    
    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }
    
    modifier onlyStakingVault() {
        require(msg.sender == stakingVault, "Not staking vault");
        _;
    }
    
    modifier tokenExists(uint256 _tokenId) {
        require(_exists(_tokenId), "Token does not exist");
        _;
    }
    
    // ============ Constructor ============
    
    constructor(address _stakingVault, string memory _baseTokenURI) {
        owner = msg.sender;
        stakingVault = _stakingVault;
        baseTokenURI = _baseTokenURI;
        
        // Initialize tier configurations
        _initializeTierConfigs();
    }
    
    // ============ NFT Minting Functions ============
    
    function mintTierNFT(
        address _to,
        uint256 _tier,
        uint256 _stakedAmount
    ) external onlyStakingVault returns (uint256) {
        require(_tier <= uint256(NFTTier.Legendary), "Invalid tier");
        
        NFTTier nftTier = NFTTier(_tier);
        TierConfig memory config = tierConfigs[nftTier];
        
        require(_stakedAmount >= config.minStake, "Insufficient stake for tier");
        
        uint256 tokenId = ++tokenIdCounter;
        
        // Create NFT metadata
        nftMetadata[tokenId] = NFTMetadata({
            tokenId: tokenId,
            owner: _to,
            tier: nftTier,
            stakedAmount: _stakedAmount,
            totalRewardsEarned: 0,
            stakingDuration: 0,
            multiplier: config.multiplierBoost,
            mintedAt: block.timestamp,
            lastUpdated: block.timestamp,
            imageURI: _generateImageURI(nftTier, tokenId),
            isTransferable: config.transferable,
            power: config.votingPowerBoost
        });
        
        // Update mappings
        userNFTs[_to].push(tokenId);
        userTierCounts[_to][nftTier]++;
        totalSupply++;
        
        emit NFTMinted(_to, tokenId, nftTier);
        emit Transfer(address(0), _to, tokenId);
        
        return tokenId;
    }
    
    function mintFounderNFT(address _to) external onlyOwner returns (uint256) {
        require(founderNFTCount < MAX_FOUNDER_NFTS, "Max founder NFTs minted");
        require(!hasFounderNFT[_to], "Already has founder NFT");
        
        uint256 tokenId = ++tokenIdCounter;
        founderNFTCount++;
        
        // Create special founder NFT
        nftMetadata[tokenId] = NFTMetadata({
            tokenId: tokenId,
            owner: _to,
            tier: NFTTier.Legendary,
            stakedAmount: 0,
            totalRewardsEarned: 0,
            stakingDuration: 0,
            multiplier: 30000, // 300% multiplier
            mintedAt: block.timestamp,
            lastUpdated: block.timestamp,
            imageURI: _generateFounderURI(tokenId),
            isTransferable: true,
            power: 50000 // 500% voting power
        });
        
        userNFTs[_to].push(tokenId);
        hasFounderNFT[_to] = true;
        isSpecialEdition[tokenId] = true;
        totalSupply++;
        
        emit NFTMinted(_to, tokenId, NFTTier.Legendary);
        emit Transfer(address(0), _to, tokenId);
        
        return tokenId;
    }
    
    // ============ NFT Update Functions ============
    
    function updateNFT(
        uint256 _tokenId,
        uint256 _newTier,
        uint256 _newAmount
    ) external onlyStakingVault tokenExists(_tokenId) {
        NFTMetadata storage nft = nftMetadata[_tokenId];
        NFTTier oldTier = nft.tier;
        NFTTier newTier = NFTTier(_newTier);
        
        // Update tier if changed
        if (oldTier != newTier) {
            userTierCounts[nft.owner][oldTier]--;
            userTierCounts[nft.owner][newTier]++;
            
            nft.tier = newTier;
            TierConfig memory config = tierConfigs[newTier];
            nft.multiplier = config.multiplierBoost;
            nft.power = config.votingPowerBoost;
            nft.isTransferable = config.transferable;
            
            emit NFTUpgraded(_tokenId, oldTier, newTier);
        }
        
        // Update staked amount and duration
        nft.stakedAmount = _newAmount;
        nft.stakingDuration = block.timestamp - nft.mintedAt;
        nft.lastUpdated = block.timestamp;
        
        // Update image URI based on new tier
        nft.imageURI = _generateImageURI(newTier, _tokenId);
        
        emit MetadataUpdated(_tokenId);
    }
    
    function updateRewardsEarned(uint256 _tokenId, uint256 _rewardsEarned) 
        external 
        onlyStakingVault 
        tokenExists(_tokenId) 
    {
        NFTMetadata storage nft = nftMetadata[_tokenId];
        nft.totalRewardsEarned += _rewardsEarned;
        nft.lastUpdated = block.timestamp;
        
        // Check if eligible for automatic tier upgrade
        _checkAutoUpgrade(_tokenId);
        
        emit MetadataUpdated(_tokenId);
    }
    
    function burnNFT(uint256 _tokenId) 
        external 
        onlyStakingVault 
        tokenExists(_tokenId) 
    {
        NFTMetadata storage nft = nftMetadata[_tokenId];
        address nftOwner = nft.owner;
        
        // Update user mappings
        _removeFromUserNFTs(nftOwner, _tokenId);
        userTierCounts[nftOwner][nft.tier]--;
        
        // Clear approvals
        delete tokenApprovals[_tokenId];
        
        // Delete NFT metadata
        delete nftMetadata[_tokenId];
        totalSupply--;
        
        emit NFTBurned(_tokenId, nftOwner);
        emit Transfer(nftOwner, address(0), _tokenId);
    }
    
    // ============ ERC721 Functions ============
    
    function transferFrom(address _from, address _to, uint256 _tokenId) 
        external 
        tokenExists(_tokenId) 
    {
        require(_isApprovedOrOwner(msg.sender, _tokenId), "Not authorized");
        require(_from == nftMetadata[_tokenId].owner, "Not owner");
        require(_to != address(0), "Invalid recipient");
        require(nftMetadata[_tokenId].isTransferable, "NFT not transferable");
        
        _transfer(_from, _to, _tokenId);
    }
    
    function approve(address _to, uint256 _tokenId) 
        external 
        tokenExists(_tokenId) 
    {
        address nftOwner = nftMetadata[_tokenId].owner;
        require(msg.sender == nftOwner || operatorApprovals[nftOwner][msg.sender], "Not authorized");
        
        tokenApprovals[_tokenId] = _to;
        emit Approval(nftOwner, _to, _tokenId);
    }
    
    function setApprovalForAll(address _operator, bool _approved) external {
        require(_operator != msg.sender, "Cannot approve self");
        
        operatorApprovals[msg.sender][_operator] = _approved;
        emit ApprovalForAll(msg.sender, _operator, _approved);
    }
    
    // ============ View Functions ============
    
    function getNFTDetails(uint256 _tokenId) 
        external 
        view 
        tokenExists(_tokenId) 
        returns (
            uint256 tier,
            uint256 stakedAmount,
            uint256 multiplier,
            uint256 mintedAt
        ) 
    {
        NFTMetadata memory nft = nftMetadata[_tokenId];
        return (
            uint256(nft.tier),
            nft.stakedAmount,
            nft.multiplier,
            nft.mintedAt
        );
    }
    
    function getUserNFTs(address _user) external view returns (uint256[] memory) {
        return userNFTs[_user];
    }
    
    function getTotalMultiplier(address _user) external view returns (uint256) {
        uint256[] memory nfts = userNFTs[_user];
        uint256 totalMultiplier = 10000; // Base 100%
        
        for (uint256 i = 0; i < nfts.length; i++) {
            NFTMetadata memory nft = nftMetadata[nfts[i]];
            totalMultiplier += (nft.multiplier - 10000);
        }
        
        return totalMultiplier;
    }
    
    function getTotalVotingPower(address _user) external view returns (uint256) {
        uint256[] memory nfts = userNFTs[_user];
        uint256 totalPower = 0;
        
        for (uint256 i = 0; i < nfts.length; i++) {
            NFTMetadata memory nft = nftMetadata[nfts[i]];
            totalPower += nft.power;
        }
        
        return totalPower;
    }
    
    function tokenURI(uint256 _tokenId) 
        external 
        view 
        tokenExists(_tokenId) 
        returns (string memory) 
    {
        NFTMetadata memory nft = nftMetadata[_tokenId];
        return string(abi.encodePacked(baseTokenURI, nft.imageURI));
    }
    
    function balanceOf(address _owner) external view returns (uint256) {
        return userNFTs[_owner].length;
    }
    
    function ownerOf(uint256 _tokenId) external view tokenExists(_tokenId) returns (address) {
        return nftMetadata[_tokenId].owner;
    }
    
    function getApproved(uint256 _tokenId) external view tokenExists(_tokenId) returns (address) {
        return tokenApprovals[_tokenId];
    }
    
    function isApprovedForAll(address _owner, address _operator) external view returns (bool) {
        return operatorApprovals[_owner][_operator];
    }
    
    // ============ Internal Functions ============
    
    function _initializeTierConfigs() internal {
        tierConfigs[NFTTier.Bronze] = TierConfig({
            minStake: 100 * 10**18,
            minDuration: 0,
            multiplierBoost: 10500, // 105%
            votingPowerBoost: 10500,
            baseURI: "bronze/",
            transferable: false
        });
        
        tierConfigs[NFTTier.Silver] = TierConfig({
            minStake: 1000 * 10**18,
            minDuration: 7 days,
            multiplierBoost: 11000, // 110%
            votingPowerBoost: 11000,
            baseURI: "silver/",
            transferable: false
        });
        
        tierConfigs[NFTTier.Gold] = TierConfig({
            minStake: 10000 * 10**18,
            minDuration: 30 days,
            multiplierBoost: 12000, // 120%
            votingPowerBoost: 12500,
            baseURI: "gold/",
            transferable: true
        });
        
        tierConfigs[NFTTier.Platinum] = TierConfig({
            minStake: 50000 * 10**18,
            minDuration: 90 days,
            multiplierBoost: 13500, // 135%
            votingPowerBoost: 15000,
            baseURI: "platinum/",
            transferable: true
        });
        
        tierConfigs[NFTTier.Diamond] = TierConfig({
            minStake: 100000 * 10**18,
            minDuration: 180 days,
            multiplierBoost: 15000, // 150%
            votingPowerBoost: 20000,
            baseURI: "diamond/",
            transferable: true
        });
        
        tierConfigs[NFTTier.Legendary] = TierConfig({
            minStake: 500000 * 10**18,
            minDuration: 365 days,
            multiplierBoost: 20000, // 200%
            votingPowerBoost: 30000,
            baseURI: "legendary/",
            transferable: true
        });
    }
    
    function _checkAutoUpgrade(uint256 _tokenId) internal {
        NFTMetadata storage nft = nftMetadata[_tokenId];
        
        // Skip special editions
        if (isSpecialEdition[_tokenId]) {
            return;
        }
        
        // Check each tier requirement
        for (uint256 i = uint256(NFTTier.Legendary); i > uint256(nft.tier); i--) {
            NFTTier checkTier = NFTTier(i);
            TierConfig memory config = tierConfigs[checkTier];
            
            if (nft.stakedAmount >= config.minStake && 
                nft.stakingDuration >= config.minDuration) {
                
                // Upgrade tier
                NFTTier oldTier = nft.tier;
                userTierCounts[nft.owner][oldTier]--;
                userTierCounts[nft.owner][checkTier]++;
                
                nft.tier = checkTier;
                nft.multiplier = config.multiplierBoost;
                nft.power = config.votingPowerBoost;
                nft.isTransferable = config.transferable;
                nft.imageURI = _generateImageURI(checkTier, _tokenId);
                
                emit NFTUpgraded(_tokenId, oldTier, checkTier);
                break;
            }
        }
    }
    
    function _transfer(address _from, address _to, uint256 _tokenId) internal {
        NFTMetadata storage nft = nftMetadata[_tokenId];
        
        // Update user NFT arrays
        _removeFromUserNFTs(_from, _tokenId);
        userNFTs[_to].push(_tokenId);
        
        // Update tier counts
        userTierCounts[_from][nft.tier]--;
        userTierCounts[_to][nft.tier]++;
        
        // Update ownership
        nft.owner = _to;
        
        // Clear approvals
        delete tokenApprovals[_tokenId];
        
        // Update special status if needed
        if (isSpecialEdition[_tokenId] && hasFounderNFT[_from]) {
            hasFounderNFT[_from] = false;
            hasFounderNFT[_to] = true;
        }
        
        emit Transfer(_from, _to, _tokenId);
    }
    
    function _removeFromUserNFTs(address _user, uint256 _tokenId) internal {
        uint256[] storage nfts = userNFTs[_user];
        for (uint256 i = 0; i < nfts.length; i++) {
            if (nfts[i] == _tokenId) {
                nfts[i] = nfts[nfts.length - 1];
                nfts.pop();
                break;
            }
        }
    }
    
    function _exists(uint256 _tokenId) internal view returns (bool) {
        return nftMetadata[_tokenId].owner != address(0);
    }
    
    function _isApprovedOrOwner(address _spender, uint256 _tokenId) 
        internal 
        view 
        returns (bool) 
    {
        address nftOwner = nftMetadata[_tokenId].owner;
        return (_spender == nftOwner || 
                tokenApprovals[_tokenId] == _spender ||
                operatorApprovals[nftOwner][_spender]);
    }
    
    function _generateImageURI(NFTTier _tier, uint256 _tokenId) 
        internal 
        view 
        returns (string memory) 
    {
        return string(abi.encodePacked(
            tierConfigs[_tier].baseURI,
            _toString(_tokenId),
            ".json"
        ));
    }
    
    function _generateFounderURI(uint256 _tokenId) 
        internal 
        pure 
        returns (string memory) 
    {
        return string(abi.encodePacked(
            "founder/",
            _toString(_tokenId),
            ".json"
        ));
    }
    
    function _toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) {
            return "0";
        }
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }
    
    // ============ Admin Functions ============
    
    function setBaseURI(string memory _newBaseURI) external onlyOwner {
        baseTokenURI = _newBaseURI;
    }
    
    function setStakingVault(address _stakingVault) external onlyOwner {
        stakingVault = _stakingVault;
    }
    
    function updateTierConfig(
        NFTTier _tier,
        uint256 _minStake,
        uint256 _minDuration,
        uint256 _multiplierBoost,
        uint256 _votingPowerBoost,
        string memory _baseURI,
        bool _transferable
    ) external onlyOwner {
        tierConfigs[_tier] = TierConfig({
            minStake: _minStake,
            minDuration: _minDuration,
            multiplierBoost: _multiplierBoost,
            votingPowerBoost: _votingPowerBoost,
            baseURI: _baseURI,
            transferable: _transferable
        });
    }
}
