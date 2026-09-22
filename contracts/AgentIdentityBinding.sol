// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title AgentIdentityBinding
 * @notice On-chain declaration linking a caller EOA to an ERC-8004
 *         agent identity that lives on another chain.
 *
 * ERC-8004 (draft) standardises AI-agent identity across chains via
 * three registries — Identity, Reputation, Validation. Kajota's Coach
 * v2 agent already runs against the ERC-8004 IdentityRegistry deployed
 * on Mantle Sepolia at `0x8004A818BFB912233c491871b3d84c89A494BD9e`.
 *
 * Mesh's happy path settles on Arbitrum. Without a binding, a judge
 * reading an Arbitrum tx has no way to correlate the caller's EOA to
 * its ERC-8004 identity on Mantle. This contract records that link.
 *
 * Model:
 *   - The operator (msg.sender) publishes their own binding — nobody
 *     else can register on their behalf.
 *   - The binding names the ERC-8004 agent id, the home registry
 *     address, and the home chain id. The `attestationHash` is a
 *     commitment produced off-chain by the operator's ERC-8004
 *     tooling — verifiers cross-check it against the home registry.
 *   - Binding is mutable via `updateBinding` (the same operator can
 *     rotate their identity as their ERC-8004 state changes) and can
 *     be revoked with `revokeBinding`.
 *
 * This contract does not verify anything on chain. Cross-chain lookup
 * against the home registry is the reader's job — a Chainlink Functions
 * call, an off-chain indexer, or a light client. Mesh treats the
 * binding as attested metadata, not proof.
 */
contract AgentIdentityBinding {
    struct Binding {
        uint256 agentId;
        address homeRegistry;
        uint64 homeChainId;
        bytes32 attestationHash;
        uint64 boundAt;
        bool active;
    }

    /// @notice operator EOA → their current binding.
    mapping(address => Binding) private _bindings;

    // ----- events -----

    event AgentBound(
        address indexed operator,
        uint256 indexed agentId,
        address indexed homeRegistry,
        uint64 homeChainId,
        bytes32 attestationHash
    );

    event AgentBindingUpdated(
        address indexed operator,
        uint256 indexed previousAgentId,
        uint256 indexed nextAgentId
    );

    event AgentBindingRevoked(address indexed operator);

    // ----- errors -----

    error ZeroAgentId();
    error ZeroHomeRegistry();
    error ZeroHomeChainId();
    error NoBindingForOperator(address operator);
    error BindingAlreadyExists(address operator);

    // ----- core -----

    /**
     * @notice Bind an ERC-8004 agent identity to `msg.sender`.
     * @dev First binding only. Use {updateBinding} to rotate.
     */
    function bindAgent(
        uint256 agentId,
        address homeRegistry,
        uint64 homeChainId,
        bytes32 attestationHash
    ) external {
        if (agentId == 0) revert ZeroAgentId();
        if (homeRegistry == address(0)) revert ZeroHomeRegistry();
        if (homeChainId == 0) revert ZeroHomeChainId();

        Binding storage b = _bindings[msg.sender];
        if (b.boundAt != 0 && b.active) {
            revert BindingAlreadyExists(msg.sender);
        }

        _bindings[msg.sender] = Binding({
            agentId: agentId,
            homeRegistry: homeRegistry,
            homeChainId: homeChainId,
            attestationHash: attestationHash,
            boundAt: uint64(block.timestamp),
            active: true
        });

        emit AgentBound(msg.sender, agentId, homeRegistry, homeChainId, attestationHash);
    }

    /**
     * @notice Rotate the binding to a fresh agent id / attestation.
     *         Same operator, new identity — e.g. after a Coach
     *         key-rotation on the home ERC-8004 registry.
     */
    function updateBinding(
        uint256 nextAgentId,
        address homeRegistry,
        uint64 homeChainId,
        bytes32 attestationHash
    ) external {
        if (nextAgentId == 0) revert ZeroAgentId();
        if (homeRegistry == address(0)) revert ZeroHomeRegistry();
        if (homeChainId == 0) revert ZeroHomeChainId();

        Binding storage b = _bindings[msg.sender];
        if (b.boundAt == 0 || !b.active) {
            revert NoBindingForOperator(msg.sender);
        }
        uint256 previousAgentId = b.agentId;

        b.agentId = nextAgentId;
        b.homeRegistry = homeRegistry;
        b.homeChainId = homeChainId;
        b.attestationHash = attestationHash;
        b.boundAt = uint64(block.timestamp);

        emit AgentBindingUpdated(msg.sender, previousAgentId, nextAgentId);
    }

    /**
     * @notice Revoke the current binding. History is preserved via the
     *         `active=false` flag; callers can re-bind later.
     */
    function revokeBinding() external {
        Binding storage b = _bindings[msg.sender];
        if (b.boundAt == 0 || !b.active) {
            revert NoBindingForOperator(msg.sender);
        }
        b.active = false;
        emit AgentBindingRevoked(msg.sender);
    }

    // ----- view -----

    function bindingOf(address operator)
        external
        view
        returns (Binding memory)
    {
        Binding memory b = _bindings[operator];
        if (b.boundAt == 0) revert NoBindingForOperator(operator);
        return b;
    }

    function hasActiveBinding(address operator) external view returns (bool) {
        Binding memory b = _bindings[operator];
        return b.boundAt != 0 && b.active;
    }
}
