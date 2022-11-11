// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IGovernorBravo} from "./interfaces/IGovernorBravo.sol";
import {INounsDAOV2} from "./interfaces/INounsDAOV2.sol";
import {IRule} from "./interfaces/IRule.sol";

// Batch vote from different aligators
// How will the frontend know which aligators are available?
// How Prop House works: signatures EIP-1271

struct Delegation {
    address to;
    uint256 until;
    uint256 redelegations;
}

/*

Seneca uses Aligator
Seneca appoints Alex
Seneca appoints Bob
Alex appoints Yitong
Seneca unappoints Alex
Yitong can't vote
Bob can vote

Or maybe we compute whenever someone can vote during 
the delegation process

Or maybe we don't let appoint more than 1 person?

Seneca uses Aligator
Seneca appoints Alex
Alex appoints Yitong

Can Yitong vote? Need to either supply the voting authority chain
or the voting authority chain needs to be stored in the contract
*/

// Rules
// - Sub-delegate up to X times
// - Sub-delegate for X amount of time
// - Allow voting only in the last X hours (backup)
// - Allow voting on prop house (signatures)
// - Props that don't upgrade the code
// - Props that only distribute eth up to X
// - Custom rules (call a contract)
// - Can receive refunds

// - Pull all proposal targets

enum Clearance {
    None,
    Propose,
    Vote,
    Sign,
    Subdelegate,
    Refund
}

struct Rules {
    uint8 permissions;
    uint8 maxRedelegations;
    uint32 notValidBefore;
    uint32 notValidAfter;
    uint16 blocksBeforeVoteCloses;
    address customRule;
}

contract AligatorWithRules {
    address public immutable owner;
    INounsDAOV2 public immutable governor;
    mapping(address => mapping(address => Rules)) public subDelegations;

    uint8 internal constant PERMISSION_VOTE = 0x01;
    uint8 internal constant PERMISSION_SIGN = 0x02;
    uint8 internal constant PERMISSION_PROPOSE = 0x04;

    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,uint256 chainId,address verifyingContract)");

    bytes32 internal constant BALLOT_TYPEHASH = keccak256("Ballot(uint256 proposalId,uint8 support)");

    event SubDelegation(address indexed from, address indexed to, Rules rules);
    // Emit event when casting vote

    error BadSignature();

    error NotDelegated(address from, address to, uint8 requiredPermissions);
    error NotValidYet(address from, address to, uint32 willBeValidFrom);
    error NotValidAnymore(address from, address to, uint32 wasValidUntil);
    error TooEarly(address from, address to, uint32 blocksBeforeVoteCloses);

    error ChainTooLong();
    error InvalidCustomRule(address customRule);

    constructor(address _owner, INounsDAOV2 _governor) {
        owner = _owner;
        governor = _governor;
    }

    function propose(
        address[] calldata authority,
        address[] calldata targets,
        uint256[] calldata values,
        string[] calldata signatures,
        bytes[] calldata calldatas,
        string calldata description
    ) external returns (uint256 proposalId) {
        proposalId = governor.propose(targets, values, signatures, calldatas, description);
        validate(msg.sender, authority, PERMISSION_PROPOSE, proposalId, 0xFF);
    }

    function castVote(address[] calldata authority, uint256 proposalId, uint8 support) external {
        validate(msg.sender, authority, PERMISSION_VOTE, proposalId, support);
        governor.castVote(proposalId, support);
    }

    function castVoteWithReason(address[] calldata authority, uint256 proposalId, uint8 support, string calldata reason)
        external
    {
        validate(msg.sender, authority, PERMISSION_VOTE, proposalId, support);
        governor.castVoteWithReason(proposalId, support, reason);
    }

    function castVoteBySig(
        address[] calldata authority,
        uint256 proposalId,
        uint8 support,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        bytes32 domainSeparator =
            keccak256(abi.encode(DOMAIN_TYPEHASH, keccak256("Aligator"), block.chainid, address(this)));
        bytes32 structHash = keccak256(abi.encode(BALLOT_TYPEHASH, proposalId, support));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        address signatory = ecrecover(digest, v, r, s);

        if (signatory != address(0)) {
            revert BadSignature();
        }

        validate(signatory, authority, PERMISSION_VOTE, proposalId, support);
        governor.castVote(proposalId, support);
    }

    function subDelegate(address to, Rules calldata rules) external {
        subDelegations[msg.sender][to] = rules;
        emit SubDelegation(msg.sender, to, rules);
    }

    function validate(
        address sender,
        address[] calldata authority,
        uint8 permissions,
        uint256 proposalId,
        uint8 support
    ) internal view {
        address account = owner;

        if (account == sender) {
            return;
        }

        INounsDAOV2.ProposalCondensed memory proposal = governor.proposals(proposalId);

        for (uint256 i = 0; i < authority.length; i++) {
            address to = authority[i];
            Rules memory rules = subDelegations[account][to];

            if (rules.permissions & permissions != permissions) {
                revert NotDelegated(account, to, permissions);
            }
            // TODO: check redelegations limit
            if (block.timestamp < rules.notValidBefore) {
                revert NotValidYet(account, to, rules.notValidBefore);
            }
            if (rules.notValidAfter != 0 && block.timestamp > rules.notValidAfter) {
                revert NotValidAnymore(account, to, rules.notValidAfter);
            }
            if (rules.blocksBeforeVoteCloses != 0 && proposal.endBlock - block.number > rules.blocksBeforeVoteCloses) {
                revert TooEarly(account, to, rules.blocksBeforeVoteCloses);
            }
            if (rules.customRule != address(0)) {
                bytes4 selector = IRule(rules.customRule).validate(address(governor), sender, proposalId, support);
                if (selector != IRule.validate.selector) {
                    revert InvalidCustomRule(rules.customRule);
                }
            }

            account = to;
        }

        if (account == sender) {
            return;
        }

        revert NotDelegated(account, sender, permissions);
    }
}

contract AligatorFactory {
    INounsDAOV2 public immutable governor;

    event AligatorDeployed(address indexed owner, address aligator);

    constructor(INounsDAOV2 _governor) {
        governor = _governor;
    }

    function create(address owner) external returns (AligatorWithRules aligator) {
        bytes32 salt = bytes32(uint256(uint160(owner)));
        aligator = new AligatorWithRules{salt: salt}(owner, governor);
        emit AligatorDeployed(owner, address(aligator));
    }
}
