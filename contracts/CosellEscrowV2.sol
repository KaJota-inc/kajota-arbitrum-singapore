// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {CosellRegistryV2} from "./CosellRegistryV2.sol";

/**
 * @title CosellEscrowV2
 * @notice N-party USDC escrow paired with {CosellRegistryV2}.
 *
 * Same lifecycle as v1: deposit → (release | refund).
 * The `release()` path fans a single stored balance out across every
 * recipient in the listing's share table in one atomic transaction.
 *
 * Loop bound: {CosellRegistryV2.MAX_RECIPIENTS}. That caps worst-case
 * release gas at a predictable ceiling — a Chainlink Functions callback
 * or an arbitration multisig can budget for it without dynamic sizing.
 */
contract CosellEscrowV2 is ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum State { Pending, Released, Refunded }

    struct Escrowed {
        bytes32 listingId;
        address buyer;
        uint256 grossAmount;
        uint64 depositedAt;
        State state;
    }

    IERC20 public immutable usdc;
    CosellRegistryV2 public immutable registry;

    address public releaseAuth;
    uint64 public constant REFUND_DELAY = 14 days;

    mapping(bytes32 => Escrowed) private _deposits;
    uint256 private _depositNonce;

    // ----- events -----

    event Deposited(
        bytes32 indexed depositId,
        bytes32 indexed listingId,
        address indexed buyer,
        uint256 grossAmount
    );

    event Released(
        bytes32 indexed depositId,
        bytes32 indexed listingId,
        address[] recipients,
        uint256[] shares
    );

    event Refunded(
        bytes32 indexed depositId,
        address indexed buyer,
        uint256 grossAmount
    );

    event ReleaseAuthUpdated(address indexed previous, address indexed next);

    // ----- errors -----

    error InvalidUsdc();
    error InvalidRegistry();
    error InvalidReleaseAuth();
    error ZeroAmount();
    error ListingNotActive(bytes32 listingId);
    error DepositNotFound(bytes32 depositId);
    error DepositNotPending(bytes32 depositId);
    error NotReleaseAuth(address caller);
    error NotBuyer(address caller, address expected);
    error RefundTooEarly(uint64 depositedAt, uint64 refundUnlockAt);

    // ----- constructor -----

    constructor(
        IERC20 _usdc,
        CosellRegistryV2 _registry,
        address _releaseAuth
    ) {
        if (address(_usdc) == address(0)) revert InvalidUsdc();
        if (address(_registry) == address(0)) revert InvalidRegistry();
        if (_releaseAuth == address(0)) revert InvalidReleaseAuth();
        usdc = _usdc;
        registry = _registry;
        releaseAuth = _releaseAuth;
    }

    // ----- core -----

    function deposit(bytes32 listingId, uint256 grossAmount)
        external
        nonReentrant
        returns (bytes32 depositId)
    {
        if (grossAmount == 0) revert ZeroAmount();

        CosellRegistryV2.Listing memory l = registry.getListing(listingId);
        if (!l.active) revert ListingNotActive(listingId);

        unchecked {
            _depositNonce++;
        }
        depositId = keccak256(
            abi.encodePacked(
                listingId,
                msg.sender,
                grossAmount,
                block.timestamp,
                _depositNonce
            )
        );

        _deposits[depositId] = Escrowed({
            listingId: listingId,
            buyer: msg.sender,
            grossAmount: grossAmount,
            depositedAt: uint64(block.timestamp),
            state: State.Pending
        });

        usdc.safeTransferFrom(msg.sender, address(this), grossAmount);

        emit Deposited(depositId, listingId, msg.sender, grossAmount);
    }

    /**
     * @notice Release a deposit's funds across all recipients atomically.
     *         Rounding-remainder falls to the last recipient by convention;
     *         registrants order that slot when they matter about it.
     */
    function release(bytes32 depositId) external nonReentrant {
        if (msg.sender != releaseAuth) revert NotReleaseAuth(msg.sender);

        Escrowed storage d = _deposits[depositId];
        if (d.depositedAt == 0) revert DepositNotFound(depositId);
        if (d.state != State.Pending) revert DepositNotPending(depositId);

        CosellRegistryV2.Listing memory l = registry.getListing(d.listingId);
        uint256[] memory shares = registry.computeSplit(d.grossAmount, d.listingId);

        d.state = State.Released;

        uint256 n = l.recipients.length;
        for (uint256 i = 0; i < n; i++) {
            uint256 share = shares[i];
            if (share > 0) {
                usdc.safeTransfer(l.recipients[i], share);
            }
        }

        emit Released(depositId, d.listingId, l.recipients, shares);
    }

    function refund(bytes32 depositId) external nonReentrant {
        Escrowed storage d = _deposits[depositId];
        if (d.depositedAt == 0) revert DepositNotFound(depositId);
        if (d.state != State.Pending) revert DepositNotPending(depositId);
        if (msg.sender != d.buyer) revert NotBuyer(msg.sender, d.buyer);

        uint64 unlockAt = d.depositedAt + REFUND_DELAY;
        if (block.timestamp < unlockAt) {
            revert RefundTooEarly(d.depositedAt, unlockAt);
        }

        d.state = State.Refunded;
        uint256 amount = d.grossAmount;

        usdc.safeTransfer(d.buyer, amount);
        emit Refunded(depositId, d.buyer, amount);
    }

    // ----- admin -----

    function setReleaseAuth(address next) external {
        if (msg.sender != releaseAuth) revert NotReleaseAuth(msg.sender);
        if (next == address(0)) revert InvalidReleaseAuth();
        address prev = releaseAuth;
        releaseAuth = next;
        emit ReleaseAuthUpdated(prev, next);
    }

    // ----- view -----

    function getDeposit(bytes32 depositId)
        external
        view
        returns (Escrowed memory)
    {
        Escrowed memory d = _deposits[depositId];
        if (d.depositedAt == 0) revert DepositNotFound(depositId);
        return d;
    }
}
