// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/**
 * @title MockUSDC
 * @notice 6-decimal mock of Circle's USDC for CosellEscrow tests.
 *
 * `decimals()` is overridden to 6 to match real USDC — important
 * because the escrow's split math is in token base units and would
 * read differently against an 18-decimal token.
 *
 * Since Sep 22 this mock also implements EIP-3009
 * (`transferWithAuthorization`) with the same domain-separator +
 * type-hash Circle's canonical USDC uses. This lets us test the x402
 * facilitator path against a mock that behaves like the real thing.
 * Same auth semantics: replay-protected via a per-signer nonce map,
 * bounded by `validAfter` / `validBefore`, EIP-712 signature verified
 * against `from`.
 *
 * Lives under `contracts/test/` — the deploy script auto-deploys it
 * on chains without a canonical USDC (Robinhood testnet at launch)
 * so E2E flows work end-to-end there too.
 */
contract MockUSDC is ERC20, EIP712 {
    /// @notice EIP-3009 TransferWithAuthorization type hash. Matches
    /// Circle's on-chain USDC verbatim (same field names, same order).
    bytes32 public constant TRANSFER_WITH_AUTHORIZATION_TYPEHASH =
        keccak256(
            "TransferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
        );

    /// @notice authorizer => nonce => used?
    mapping(address => mapping(bytes32 => bool)) private _authorizationStates;

    error AuthorizationUsed(address authorizer, bytes32 nonce);
    error AuthorizationNotYetValid(uint256 validAfter);
    error AuthorizationExpired(uint256 validBefore);
    error InvalidSignature(address expected, address recovered);

    event AuthorizationUsedEvent(address indexed authorizer, bytes32 indexed nonce);

    constructor() ERC20("Mock USDC", "mUSDC") EIP712("USD Coin", "2") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /**
     * @notice Execute a signed transfer from `from` to `to`.
     * @dev Anyone can submit; the signature is checked against `from`.
     *      This mirrors Circle's EIP-3009 exactly so the same test
     *      harness works against real USDC on Arbitrum Sepolia.
     */
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
    ) external {
        if (block.timestamp <= validAfter) revert AuthorizationNotYetValid(validAfter);
        if (block.timestamp >= validBefore) revert AuthorizationExpired(validBefore);
        if (_authorizationStates[from][nonce]) revert AuthorizationUsed(from, nonce);

        bytes32 structHash = keccak256(
            abi.encode(
                TRANSFER_WITH_AUTHORIZATION_TYPEHASH,
                from,
                to,
                value,
                validAfter,
                validBefore,
                nonce
            )
        );
        bytes32 digest = _hashTypedDataV4(structHash);
        address recovered = ECDSA.recover(digest, v, r, s);
        if (recovered != from) revert InvalidSignature(from, recovered);

        _authorizationStates[from][nonce] = true;
        emit AuthorizationUsedEvent(from, nonce);

        _transfer(from, to, value);
    }

    function authorizationState(address authorizer, bytes32 nonce) external view returns (bool) {
        return _authorizationStates[authorizer][nonce];
    }

    /// @notice EIP-712 domain separator for constructing signatures off-chain.
    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }
}
