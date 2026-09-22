// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title CosellRegistryV2
 * @notice N-party version of the co-sell agreement primitive.
 *
 * v1 (see {CosellRegistry}) hard-codes the pattern to two parties — a
 * wholesaler and a coseller — with a single commission percentage. That
 * fits Kajota's launch case (one micro-distributor per listing) but is a
 * strict subset of the primitive commerce agents actually need.
 *
 * v2 opens the recipient set to N parties (2..{@dev MAX_RECIPIENTS}) with an
 * arbitrary share table that must sum to exactly {@dev BPS_DENOMINATOR}.
 * The 2-party case is still expressible verbatim — recipients=[coseller,
 * wholesaler], shares=[bps, 10000-bps] — so agents can migrate incrementally.
 *
 * v1 is not deprecated. It stays live and verified for existing deposits;
 * v2 is an additive primitive, deployed alongside.
 *
 * Immutability + deactivate-only semantics are preserved from v1: a listing
 * cannot be edited after `register()`. To change the split, deactivate and
 * re-register.
 */
contract CosellRegistryV2 {
    /// @notice One basis point = 0.01%. 10000 bps = 100%.
    uint16 public constant BPS_DENOMINATOR = 10000;

    /// @notice Upper bound on recipients per listing. Bounds release-loop
    /// gas + the payload size a Chainlink Functions callback carries.
    uint256 public constant MAX_RECIPIENTS = 16;

    struct Listing {
        string productId;
        address registrant;
        address[] recipients;
        uint16[] shares;
        string currency;
        uint64 registeredAt;
        bool active;
    }

    /// @notice listingId → Listing.
    mapping(bytes32 => Listing) private _listings;

    /// @notice Listings a given productId has ever produced.
    mapping(string => bytes32[]) private _listingsByProduct;

    /// @notice Listings a given recipient appears in.
    mapping(address => bytes32[]) private _listingsByRecipient;

    // ----- events -----

    event ListingRegistered(
        bytes32 indexed listingId,
        string indexed productId,
        address indexed registrant,
        address[] recipients,
        uint16[] shares,
        string currency
    );

    event ListingDeactivated(bytes32 indexed listingId, address indexed by);

    // ----- errors -----

    error InvalidRegistrant();
    error EmptyProductId();
    error EmptyCurrency();
    error RecipientCountOutOfRange(uint256 supplied, uint256 min, uint256 max);
    error ShareLengthMismatch(uint256 recipientsLength, uint256 sharesLength);
    error ZeroRecipient(uint256 index);
    error ZeroShare(uint256 index);
    error DuplicateRecipient(address recipient, uint256 index);
    error SharesDoNotSumToDenominator(uint256 supplied, uint256 denominator);
    error ListingAlreadyExists(bytes32 listingId);
    error ListingNotFound(bytes32 listingId);
    error ListingNotActive(bytes32 listingId);
    error NotRegistrant(address caller);

    // ----- core -----

    /**
     * @notice Register an N-party co-sell agreement on-chain.
     *
     * @param productId       Off-chain product identifier (unchanged from v1).
     * @param recipients      2..MAX_RECIPIENTS unique non-zero addresses.
     * @param shares          Basis-point share for each recipient; must sum to 10000.
     * @param currency        ISO currency code, e.g. "USDC".
     * @return listingId      Deterministic id derived from all inputs + registrant.
     */
    function register(
        string calldata productId,
        address[] calldata recipients,
        uint16[] calldata shares,
        string calldata currency
    ) external returns (bytes32 listingId) {
        if (msg.sender == address(0)) revert InvalidRegistrant();
        if (bytes(productId).length == 0) revert EmptyProductId();
        if (bytes(currency).length == 0) revert EmptyCurrency();

        uint256 n = recipients.length;
        if (n < 2 || n > MAX_RECIPIENTS) {
            revert RecipientCountOutOfRange(n, 2, MAX_RECIPIENTS);
        }
        if (shares.length != n) {
            revert ShareLengthMismatch(n, shares.length);
        }

        // Uniqueness + non-zero + non-zero-share + sum check in one pass.
        uint256 totalBps = 0;
        for (uint256 i = 0; i < n; i++) {
            address r = recipients[i];
            if (r == address(0)) revert ZeroRecipient(i);
            if (shares[i] == 0) revert ZeroShare(i);
            for (uint256 j = 0; j < i; j++) {
                if (recipients[j] == r) revert DuplicateRecipient(r, i);
            }
            totalBps += shares[i];
        }
        if (totalBps != BPS_DENOMINATOR) {
            revert SharesDoNotSumToDenominator(totalBps, BPS_DENOMINATOR);
        }

        listingId = computeListingId(productId, msg.sender, recipients, shares);
        if (_listings[listingId].registeredAt != 0) {
            revert ListingAlreadyExists(listingId);
        }

        _listings[listingId] = Listing({
            productId: productId,
            registrant: msg.sender,
            recipients: recipients,
            shares: shares,
            currency: currency,
            registeredAt: uint64(block.timestamp),
            active: true
        });
        _listingsByProduct[productId].push(listingId);
        for (uint256 i = 0; i < n; i++) {
            _listingsByRecipient[recipients[i]].push(listingId);
        }

        emit ListingRegistered(
            listingId,
            productId,
            msg.sender,
            recipients,
            shares,
            currency
        );
    }

    /**
     * @notice Deactivate a listing. Only the original registrant can call this.
     * @dev Does not delete the listing — history is preserved for auditability.
     */
    function deactivate(bytes32 listingId) external {
        Listing storage l = _listings[listingId];
        if (l.registeredAt == 0) revert ListingNotFound(listingId);
        if (!l.active) revert ListingNotActive(listingId);
        if (msg.sender != l.registrant) revert NotRegistrant(msg.sender);
        l.active = false;
        emit ListingDeactivated(listingId, msg.sender);
    }

    // ----- view -----

    function getListing(bytes32 listingId)
        external
        view
        returns (Listing memory)
    {
        Listing memory l = _listings[listingId];
        if (l.registeredAt == 0) revert ListingNotFound(listingId);
        return l;
    }

    function listingsForProduct(string calldata productId)
        external
        view
        returns (bytes32[] memory)
    {
        return _listingsByProduct[productId];
    }

    function listingsForRecipient(address recipient)
        external
        view
        returns (bytes32[] memory)
    {
        return _listingsByRecipient[recipient];
    }

    /**
     * @notice Deterministic listing id — same registrant + productId +
     *         recipients + shares always yields the same id. Same triple
     *         cannot be re-registered.
     */
    function computeListingId(
        string calldata productId,
        address registrant,
        address[] calldata recipients,
        uint16[] calldata shares
    ) public pure returns (bytes32) {
        return keccak256(
            abi.encode(productId, registrant, recipients, shares)
        );
    }

    /**
     * @notice Compute the split of `grossAmount` across a listing.
     * @dev Pure math against the stored shares — same rounding rule as
     *      v1 (integer division per recipient; last recipient absorbs the
     *      rounding-remainder so the sum always equals `grossAmount`).
     */
    function computeSplit(uint256 grossAmount, bytes32 listingId)
        external
        view
        returns (uint256[] memory perRecipient)
    {
        Listing memory l = _listings[listingId];
        if (l.registeredAt == 0) revert ListingNotFound(listingId);

        uint256 n = l.recipients.length;
        perRecipient = new uint256[](n);

        uint256 running = 0;
        for (uint256 i = 0; i < n - 1; i++) {
            uint256 share = (grossAmount * l.shares[i]) / BPS_DENOMINATOR;
            perRecipient[i] = share;
            running += share;
        }
        // Last recipient sweeps the dust so sum(perRecipient) == grossAmount.
        perRecipient[n - 1] = grossAmount - running;
    }
}
