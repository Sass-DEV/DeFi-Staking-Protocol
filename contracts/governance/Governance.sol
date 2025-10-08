// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "../interfaces/IStaking.sol";

/**
 * @title Governance
 * @dev DAO governance contract with voting, timelock, and delegation
 * @author Talent Protocol Builder
 */
contract Governance {
    // ============ Types ============
    
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
    
    struct Proposal {
        uint256 id;
        address proposer;
        uint256 startBlock;
        uint256 endBlock;
        uint256 forVotes;
        uint256 againstVotes;
        uint256 abstainVotes;
        bool canceled;
        bool executed;
        mapping(address => Receipt) receipts;
        bytes32 descriptionHash;
        address[] targets;
        uint256[] values;
        bytes[] calldatas;
        uint256 eta; // Execution time for timelock
    }
    
    struct Receipt {
        bool hasVoted;
        VoteType voteType;
        uint256 votes;
    }
    
    struct Checkpoint {
        uint32 fromBlock;
        uint224 votes;
    }
    
    // ============ State Variables ============
    
    // Governance parameters
    uint256 public constant VOTING_PERIOD = 17280; // ~3 days in blocks
    uint256 public constant VOTING_DELAY = 1; // 1 block
    uint256 public constant PROPOSAL_THRESHOLD = 100000 * 10**18; // 100k tokens to propose
    uint256 public constant QUORUM_VOTES = 4000000 * 10**18; // 4M tokens quorum
    uint256 public constant TIMELOCK_DELAY = 2 days;
    uint256 public constant GRACE_PERIOD = 14 days;
    uint256 public constant MAX_OPERATIONS = 10;
    
    // Core state
    mapping(uint256 => Proposal) public proposals;
    mapping(address => mapping(uint32 => Checkpoint)) public checkpoints;
    mapping(address => uint32) public numCheckpoints;
    mapping(address => address) public delegates;
    mapping(address => uint256) public votingPower;
    mapping(bytes32 => bool) public queuedTransactions;
    
    uint256 public proposalCount;
    address public guardian;
    address public stakingVault;
    address public rewardToken;
    uint256 public totalVotingPower;
    
    // Delegation
    mapping(address => mapping(address => uint256)) public delegatedPower;
    
    // ============ Events ============
    
    event ProposalCreated(
        uint256 id,
        address proposer,
        address[] targets,
        uint256[] values,
        string[] signatures,
        bytes[] calldatas,
        uint256 startBlock,
        uint256 endBlock,
        string description
    );
    
    event VoteCast(
        address indexed voter,
        uint256 proposalId,
        VoteType voteType,
        uint256 votes,
        string reason
    );
    
    event ProposalCanceled(uint256 id);
    event ProposalQueued(uint256 id, uint256 eta);
    event ProposalExecuted(uint256 id);
    event DelegateChanged(address indexed delegator, address indexed fromDelegate, address indexed toDelegate);
    event DelegateVotesChanged(address indexed delegate, uint256 previousBalance, uint256 newBalance);
    event ExecuteTransaction(bytes32 indexed txHash, address indexed target, uint256 value, bytes data, uint256 eta);
    event QueueTransaction(bytes32 indexed txHash, address indexed target, uint256 value, bytes data, uint256 eta);
    event CancelTransaction(bytes32 indexed txHash);
    
    // ============ Modifiers ============
    
    modifier onlyGuardian() {
        require(msg.sender == guardian, "Not guardian");
        _;
    }
    
    modifier onlyStakingVault() {
        require(msg.sender == stakingVault, "Not staking vault");
        _;
    }
    
    // ============ Constructor ============
    
    constructor(address _rewardToken, address _stakingVault) {
        guardian = msg.sender;
        rewardToken = _rewardToken;
        stakingVault = _stakingVault;
    }
    
    // ============ Proposal Functions ============
    
    function propose(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description
    ) external returns (uint256) {
        require(
            getPriorVotes(msg.sender, block.number - 1) >= PROPOSAL_THRESHOLD,
            "Below proposal threshold"
        );
        require(
            targets.length == values.length && 
            targets.length == calldatas.length,
            "Invalid proposal length"
        );
        require(targets.length > 0 && targets.length <= MAX_OPERATIONS, "Invalid operations count");
        
        uint256 proposalId = proposalCount++;
        Proposal storage newProposal = proposals[proposalId];
        
        newProposal.id = proposalId;
        newProposal.proposer = msg.sender;
        newProposal.startBlock = block.number + VOTING_DELAY;
        newProposal.endBlock = newProposal.startBlock + VOTING_PERIOD;
        newProposal.targets = targets;
        newProposal.values = values;
        newProposal.calldatas = calldatas;
        newProposal.descriptionHash = keccak256(bytes(description));
        
        emit ProposalCreated(
            proposalId,
            msg.sender,
            targets,
            values,
            new string[](targets.length), // Empty signatures for simplicity
            calldatas,
            newProposal.startBlock,
            newProposal.endBlock,
            description
        );
        
        return proposalId;
    }
    
    function queue(uint256 proposalId) external {
        require(state(proposalId) == ProposalState.Succeeded, "Proposal not succeeded");
        
        Proposal storage proposal = proposals[proposalId];
        uint256 eta = block.timestamp + TIMELOCK_DELAY;
        proposal.eta = eta;
        
        for (uint256 i = 0; i < proposal.targets.length; i++) {
            bytes32 txHash = keccak256(
                abi.encode(
                    proposal.targets[i],
                    proposal.values[i],
                    proposal.calldatas[i],
                    eta
                )
            );
            queuedTransactions[txHash] = true;
            emit QueueTransaction(
                txHash,
                proposal.targets[i],
                proposal.values[i],
                proposal.calldatas[i],
                eta
            );
        }
        
        emit ProposalQueued(proposalId, eta);
    }
    
    function execute(uint256 proposalId) external payable {
        require(state(proposalId) == ProposalState.Queued, "Proposal not queued");
        
        Proposal storage proposal = proposals[proposalId];
        require(block.timestamp >= proposal.eta, "Timelock not met");
        require(block.timestamp <= proposal.eta + GRACE_PERIOD, "Transaction stale");
        
        proposal.executed = true;
        
        for (uint256 i = 0; i < proposal.targets.length; i++) {
            bytes32 txHash = keccak256(
                abi.encode(
                    proposal.targets[i],
                    proposal.values[i],
                    proposal.calldatas[i],
                    proposal.eta
                )
            );
            
            require(queuedTransactions[txHash], "Transaction not queued");
            queuedTransactions[txHash] = false;
            
            (bool success, ) = proposal.targets[i].call{value: proposal.values[i]}(
                proposal.calldatas[i]
            );
            require(success, "Transaction execution failed");
            
            emit ExecuteTransaction(
                txHash,
                proposal.targets[i],
                proposal.values[i],
                proposal.calldatas[i],
                proposal.eta
            );
        }
        
        emit ProposalExecuted(proposalId);
    }
    
    function cancel(uint256 proposalId) external {
        ProposalState currentState = state(proposalId);
        require(
            currentState != ProposalState.Executed &&
            currentState != ProposalState.Canceled &&
            currentState != ProposalState.Expired,
            "Cannot cancel"
        );
        
        Proposal storage proposal = proposals[proposalId];
        require(
            msg.sender == proposal.proposer ||
            msg.sender == guardian ||
            getPriorVotes(proposal.proposer, block.number - 1) < PROPOSAL_THRESHOLD,
            "Cannot cancel"
        );
        
        proposal.canceled = true;
        
        // Cancel queued transactions if any
        if (proposal.eta != 0) {
            for (uint256 i = 0; i < proposal.targets.length; i++) {
                bytes32 txHash = keccak256(
                    abi.encode(
                        proposal.targets[i],
                        proposal.values[i],
                        proposal.calldatas[i],
                        proposal.eta
                    )
                );
                queuedTransactions[txHash] = false;
                emit CancelTransaction(txHash);
            }
        }
        
        emit ProposalCanceled(proposalId);
    }
    
    // ============ Voting Functions ============
    
    function castVote(uint256 proposalId, VoteType voteType) external {
        return _castVote(msg.sender, proposalId, voteType, "");
    }
    
    function castVoteWithReason(
        uint256 proposalId,
        VoteType voteType,
        string calldata reason
    ) external {
        return _castVote(msg.sender, proposalId, voteType, reason);
    }
    
    function castVoteBySig(
        uint256 proposalId,
        VoteType voteType,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,uint256 chainId,address verifyingContract)"),
                keccak256("DeFi Staking Governance"),
                block.chainid,
                address(this)
            )
        );
        
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Vote(uint256 proposalId,uint8 voteType)"),
                proposalId,
                voteType
            )
        );
        
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        address voter = ecrecover(digest, v, r, s);
        
        require(voter != address(0), "Invalid signature");
        return _castVote(voter, proposalId, voteType, "");
    }
    
    function _castVote(
        address voter,
        uint256 proposalId,
        VoteType voteType,
        string memory reason
    ) internal {
        require(state(proposalId) == ProposalState.Active, "Voting closed");
        
        Proposal storage proposal = proposals[proposalId];
        Receipt storage receipt = proposal.receipts[voter];
        
        require(!receipt.hasVoted, "Already voted");
        
        uint256 votes = getPriorVotes(voter, proposal.startBlock);
        require(votes > 0, "No voting power");
        
        if (voteType == VoteType.For) {
            proposal.forVotes += votes;
        } else if (voteType == VoteType.Against) {
            proposal.againstVotes += votes;
        } else {
            proposal.abstainVotes += votes;
        }
        
        receipt.hasVoted = true;
        receipt.voteType = voteType;
        receipt.votes = votes;
        
        emit VoteCast(voter, proposalId, voteType, votes, reason);
    }
    
    // ============ Delegation Functions ============
    
    function delegate(address delegatee) external {
        return _delegate(msg.sender, delegatee);
    }
    
    function delegateBySig(
        address delegatee,
        uint256 nonce,
        uint256 expiry,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,uint256 chainId,address verifyingContract)"),
                keccak256("DeFi Staking Governance"),
                block.chainid,
                address(this)
            )
        );
        
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Delegation(address delegatee,uint256 nonce,uint256 expiry)"),
                delegatee,
                nonce,
                expiry
            )
        );
        
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        address delegator = ecrecover(digest, v, r, s);
        
        require(delegator != address(0), "Invalid signature");
        require(block.timestamp <= expiry, "Signature expired");
        
        return _delegate(delegator, delegatee);
    }
    
    function _delegate(address delegator, address delegatee) internal {
        address currentDelegate = delegates[delegator];
        uint256 delegatorBalance = votingPower[delegator];
        delegates[delegator] = delegatee;
        
        emit DelegateChanged(delegator, currentDelegate, delegatee);
        
        _moveDelegates(currentDelegate, delegatee, delegatorBalance);
    }
    
    function _moveDelegates(address from, address to, uint256 amount) internal {
        if (from != address(0) && amount > 0) {
            uint32 fromNum = numCheckpoints[from];
            uint256 fromOld = fromNum > 0 ? checkpoints[from][fromNum - 1].votes : 0;
            uint256 fromNew = fromOld - amount;
            _writeCheckpoint(from, fromNum, fromOld, fromNew);
        }
        
        if (to != address(0) && amount > 0) {
            uint32 toNum = numCheckpoints[to];
            uint256 toOld = toNum > 0 ? checkpoints[to][toNum - 1].votes : 0;
            uint256 toNew = toOld + amount;
            _writeCheckpoint(to, toNum, toOld, toNew);
        }
    }
    
    function _writeCheckpoint(
        address delegatee,
        uint32 nCheckpoints,
        uint256 oldVotes,
        uint256 newVotes
    ) internal {
        if (nCheckpoints > 0 && checkpoints[delegatee][nCheckpoints - 1].fromBlock == block.number) {
            checkpoints[delegatee][nCheckpoints - 1].votes = _safe224(newVotes);
        } else {
            checkpoints[delegatee][nCheckpoints] = Checkpoint(
                _safe32(block.number),
                _safe224(newVotes)
            );
            numCheckpoints[delegatee] = nCheckpoints + 1;
        }
        
        emit DelegateVotesChanged(delegatee, oldVotes, newVotes);
    }
    
    // ============ Voting Power Functions ============
    
    function updateVotingPower(address account, uint256 newPower) external onlyStakingVault {
        uint256 oldPower = votingPower[account];
        votingPower[account] = newPower;
        
        totalVotingPower = totalVotingPower - oldPower + newPower;
        
        address delegatee = delegates[account];
        if (delegatee == address(0)) {
            delegatee = account;
        }
        
        _moveDelegates(address(0), delegatee, newPower - oldPower);
    }
    
    // ============ View Functions ============
    
    function state(uint256 proposalId) public view returns (ProposalState) {
        Proposal storage proposal = proposals[proposalId];
        
        if (proposal.canceled) return ProposalState.Canceled;
        if (proposal.executed) return ProposalState.Executed;
        
        if (block.number <= proposal.startBlock) return ProposalState.Pending;
        if (block.number <= proposal.endBlock) return ProposalState.Active;
        
        if (proposal.forVotes <= proposal.againstVotes || proposal.forVotes < QUORUM_VOTES) {
            return ProposalState.Defeated;
        }
        
        if (proposal.eta == 0) return ProposalState.Succeeded;
        if (block.timestamp >= proposal.eta + GRACE_PERIOD) return ProposalState.Expired;
        
        return ProposalState.Queued;
    }
    
    function getProposal(uint256 proposalId) external view returns (
        address proposer,
        uint256 startBlock,
        uint256 endBlock,
        uint256 forVotes,
        uint256 againstVotes,
        uint256 abstainVotes,
        bool canceled,
        bool executed
    ) {
        Proposal storage proposal = proposals[proposalId];
        return (
            proposal.proposer,
            proposal.startBlock,
            proposal.endBlock,
            proposal.forVotes,
            proposal.againstVotes,
            proposal.abstainVotes,
            proposal.canceled,
            proposal.executed
        );
    }
    
    function getActions(uint256 proposalId) external view returns (
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas
    ) {
        Proposal storage proposal = proposals[proposalId];
        return (proposal.targets, proposal.values, proposal.calldatas);
    }
    
    function getReceipt(uint256 proposalId, address voter) external view returns (Receipt memory) {
        return proposals[proposalId].receipts[voter];
    }
    
    function getPriorVotes(address account, uint256 blockNumber) public view returns (uint256) {
        require(blockNumber < block.number, "Not yet determined");
        
        uint32 nCheckpoints = numCheckpoints[account];
        if (nCheckpoints == 0) return 0;
        
        // First check most recent balance
        if (checkpoints[account][nCheckpoints - 1].fromBlock <= blockNumber) {
            return checkpoints[account][nCheckpoints - 1].votes;
        }
        
        // Next check implicit zero balance
        if (checkpoints[account][0].fromBlock > blockNumber) {
            return 0;
        }
        
        // Binary search
        uint32 lower = 0;
        uint32 upper = nCheckpoints - 1;
        while (upper > lower) {
            uint32 center = upper - (upper - lower) / 2;
            Checkpoint memory cp = checkpoints[account][center];
            if (cp.fromBlock == blockNumber) {
                return cp.votes;
            } else if (cp.fromBlock < blockNumber) {
                lower = center;
            } else {
                upper = center - 1;
            }
        }
        
        return checkpoints[account][lower].votes;
    }
    
    function getCurrentVotes(address account) external view returns (uint256) {
        uint32 nCheckpoints = numCheckpoints[account];
        return nCheckpoints > 0 ? checkpoints[account][nCheckpoints - 1].votes : 0;
    }
    
    // ============ Helper Functions ============
    
    function _safe32(uint256 n) internal pure returns (uint32) {
        require(n < 2**32, "Number exceeds 32 bits");
        return uint32(n);
    }
    
    function _safe224(uint256 n) internal pure returns (uint224) {
        require(n < 2**224, "Number exceeds 224 bits");
        return uint224(n);
    }
    
    // ============ Admin Functions ============
    
    function setGuardian(address _guardian) external onlyGuardian {
        guardian = _guardian;
    }
    
    function setStakingVault(address _stakingVault) external onlyGuardian {
        stakingVault = _stakingVault;
    }
}
