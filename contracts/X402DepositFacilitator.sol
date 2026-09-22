// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {CosellEscrowV2} from "./CosellEscrowV2.sol";

/**
 * @notice Minimal slice of Circle USDC's EIP-3009 surface that this
 *         facilitator relies on. Real USDC exposes it; MockUSDC in
 *         this repo mirrors it.
 */
interface IUsdc3009 {
    function transferWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;
}

/**
 * @title X402DepositFacilitator
 * @notice Server-side settlement contract for the Mesh x402 flow.
 *
 * The x402 protocol runs over HTTP 402 Payment Required. A Kajota
 * server responding to an agent's request declares the required
 * payment in the challenge headers; the agent generates an EIP-3009
 * TransferWithAuthorization signature over USDC and resubmits the
 * request with the signature in `X-PAYMENT`. The server verifies +
 * submits the settlement on-chain.
 *
 * This facilitator is the on-chain piece of that server flow:
 *   1. It pulls USDC from the buyer via `transferWithAuthorization`
 *      (no separate approve tx — the signature IS the authorization).
 *   2. It approves and calls `CosellEscrowV2.deposit(listingId, amount)`.
 *   3. It records the original buyer against the returned depositId so
 *      a permissionless refund path can push funds back if the escrow
 *      times out.
 *
 * The facilitator never keeps USDC. Every path (relay + refund) is
 * pass-through — funds either flow into the escrow or straight back
 * to the original buyer.
 *
 * Agent-side ergonomics:
 *   - Buyers do not hold ETH; the facilitator submits the tx and pays
 *     gas from its own balance.
 *   - Buyers sign once (EIP-712 over the EIP-3009 struct) and the
 *     server takes care of the two on-chain hops.
 *
 * @dev Compatible with any EIP-3009 token (real USDC on Arbitrum
 *      Sepolia; MockUSDC in this repo). Uses SafeERC20's forceApprove
 *      to handle tokens (Circle USDC included) whose `approve`
 *      requires the allowance to be zeroed before setting a new value.
 */
contract X402DepositFacilitator is ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable usdc;
    CosellEscrowV2 public immutable escrow;

    /// @notice depositId => original buyer that signed the EIP-3009
    /// authorization. Zero after refund or when the deposit was not
    /// relayed through this facilitator.
    mapping(bytes32 => address) private _originalBuyerOf;

    // ----- events -----

    event DepositRelayed(
        bytes32 indexed depositId,
        bytes32 indexed listingId,
        address indexed originalBuyer,
        address facilitator,
        uint256 amount
    );

    event RefundForwarded(
        bytes32 indexed depositId,
        address indexed originalBuyer,
        uint256 amount
    );

    // ----- errors -----

    error InvalidUsdc();
    error InvalidEscrow();
    error DepositNotRelayed(bytes32 depositId);
    error PostRelayAssertionFailed();

    // ----- constructor -----

    constructor(IERC20 _usdc, CosellEscrowV2 _escrow) {
        if (address(_usdc) == address(0)) revert InvalidUsdc();
        if (address(_escrow) == address(0)) revert InvalidEscrow();
        usdc = _usdc;
        escrow = _escrow;
    }

    // ----- core -----

    /**
     * @notice Consume a buyer's EIP-3009 authorization, pull USDC to
     *         this contract, then deposit into the escrow on the
     *         buyer's behalf. Anyone (a Kajota server, a public
     *         facilitator, or the buyer themselves) may call this;
     *         the deposited amount will always route to the buyer of
     *         the signature.
     */
    function relayDeposit(
        bytes32 listingId,
        uint256 amount,
        // EIP-3009 authorization
        address buyer,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant returns (bytes32 depositId) {
        uint256 balanceBefore = usdc.balanceOf(address(this));

        // 1. Pull USDC from the buyer. Reverts (via the token's own
        //    EIP-3009 impl) on: bad signature, expired auth, replay.
        IUsdc3009(address(usdc)).transferWithAuthorization(
            buyer,
            address(this),
            amount,
            validAfter,
            validBefore,
            nonce,
            v,
            r,
            s
        );

        // 2. Verify the pull actually landed the expected amount —
        //    guards against fee-on-transfer tokens if this contract
        //    is ever pointed at one. Reverts hard if the token cheated.
        uint256 balanceAfter = usdc.balanceOf(address(this));
        if (balanceAfter - balanceBefore != amount) {
            revert PostRelayAssertionFailed();
        }

        // 3. Approve + deposit into escrow.
        usdc.forceApprove(address(escrow), amount);
        depositId = escrow.deposit(listingId, amount);

        // 4. Record the original buyer.
        _originalBuyerOf[depositId] = buyer;

        emit DepositRelayed(depositId, listingId, buyer, msg.sender, amount);
    }

    /**
     * @notice Push a refund back to the original buyer. Permissionless:
     *         anyone (the facilitator itself, the buyer, or a
     *         third-party keeper) can call this. Funds always go to
     *         the buyer recorded on relay.
     * @dev The underlying `escrow.refund(depositId)` requires the
     *      escrow's stored buyer (this contract) to be `msg.sender`.
     *      We satisfy that as the depositor, then forward what came
     *      back to the recorded original buyer.
     */
    function refundToOriginalBuyer(bytes32 depositId) external nonReentrant {
        address buyer = _originalBuyerOf[depositId];
        if (buyer == address(0)) revert DepositNotRelayed(depositId);
        delete _originalBuyerOf[depositId];

        uint256 balanceBefore = usdc.balanceOf(address(this));
        escrow.refund(depositId);
        uint256 refunded = usdc.balanceOf(address(this)) - balanceBefore;

        usdc.safeTransfer(buyer, refunded);
        emit RefundForwarded(depositId, buyer, refunded);
    }

    // ----- view -----

    function originalBuyerOf(bytes32 depositId) external view returns (address) {
        return _originalBuyerOf[depositId];
    }
}
