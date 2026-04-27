// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IVeHemi} from "../interfaces/IVeHemi.sol";

/// @title PositionFactory
/// @notice Idempotent creator for pre-authorized veHEMI lock positions.
/// @dev Used during protocol distributions where the owner (a trusted funder / multisig)
///      pre-authorizes a set of (user, amount, duration) tuples and any third party —
///      typically a keeper — can then submit the HEMI and mint the corresponding
///      veHEMI NFT on the user's behalf. Two-phase flow:
///
///        1. Owner calls `updateStatus(users, amounts, durations, PENDING, ...)` to
///           whitelist a batch of positions.
///        2. Anyone calls `create(user, amount, duration, transferable, forfeitable)`;
///           the factory transfers HEMI in, forwards to `VeHemi.createLockFor`, and
///           flips the entry to CREATED. Re-submitting the same tuple reverts with
///           `PositionCreatedAlready`.
///
///      Idempotency key: `keccak256(abi.encodePacked(user, amount, duration))`. Because
///      `transferable` and `forfeitable` are NOT included in the hash, a single
///      whitelisted tuple locks in the owner-chosen values at `create` time — the caller
///      does not choose them independently. Two whitelist entries with the same
///      (user, amount, duration) but different transferability / forfeitability flags
///      would collide and are unsupported.
///
///      The `created` mapping uses three-valued logic: `NONE` (default, not whitelisted
///      — `create` reverts), `PENDING` (whitelisted, `create` will proceed), `CREATED`
///      (already minted, `create` reverts). `updateStatus(..., revertIfCreated = true)`
///      protects the owner from accidentally re-opening an already-minted slot.
contract PositionFactory is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice The veHEMI contract this factory mints positions into (immutable).
    IVeHemi public immutable veHemi;

    /// @notice The HEMI ERC20 token read from `veHemi.HEMI()` at deploy time (immutable).
    IERC20 public immutable hemi;

    /// @notice Lifecycle state for a whitelisted (user, amount, duration) tuple.
    /// @dev `NONE` (0, default) — not whitelisted; `create` reverts.
    ///      `PENDING` (1) — whitelisted and unclaimed; `create` proceeds.
    ///      `CREATED` (2) — already minted; `create` reverts with `PositionCreatedAlready`.
    enum Status {
        NONE,
        PENDING,
        CREATED
    }

    /// @notice Maps `keccak256(abi.encodePacked(user, amount, duration))` to lifecycle status.
    /// @dev The key is `abi.encodePacked` — caller must use identical encoding to avoid
    ///      collisions. `user` is `address` (20 bytes), `amount` and `duration` are
    ///      `uint256` (32 bytes each), giving a fixed 84-byte preimage with no
    ///      dynamic-length ambiguity.
    mapping(bytes32 => Status) public created;

    event StatusUpdated(
        bytes32 indexed hash,
        address indexed user_,
        uint256 amount_,
        uint256 duration_,
        Status status
    );
    event PositionCreated(
        bytes32 indexed hash,
        address indexed user_,
        uint256 amount_,
        uint256 duration_,
        bool transferable_,
        bool forfeitable_
    );

    error PositionCreatedAlready(address user_, uint256 amount_, uint256 duration_);
    error InvalidArrays();
    error InvalidVeHemi();

    /// @notice Deploys the factory bound to a specific veHEMI contract and initial owner.
    /// @dev The HEMI token address is read from `IVeHemi(veHemi_).HEMI()` and cached as
    ///      an immutable; the factory is therefore permanently tied to whatever HEMI
    ///      token veHemi was deployed against.
    /// @param veHemi_ Address of the veHEMI contract (reverts with `InvalidVeHemi` if zero).
    /// @param owner_ Initial owner for `Ownable2Step`; only this address can whitelist
    ///        positions via `updateStatus`. Ownership transfer requires a two-step handoff.
    constructor(address veHemi_, address owner_) Ownable(owner_) {
        if (veHemi_ == address(0)) revert InvalidVeHemi();
        veHemi = IVeHemi(veHemi_);
        hemi = IERC20(IVeHemi(veHemi_).HEMI());
    }

    /// @notice Mints a pre-authorized veHEMI position. Permissionless — anyone can pay
    ///         the HEMI and gas to claim a PENDING entry on behalf of its beneficiary.
    /// @dev Flow: looks up the `(user, amount, duration)` hash in `created`; reverts if
    ///      not PENDING. Flips to CREATED BEFORE any external calls (strict
    ///      checks-effects-interactions), then pulls HEMI from `msg.sender`, approves
    ///      veHEMI via `forceApprove`, and calls `veHemi.createLockFor(...)`. The
    ///      recipient of the minted NFT is `user_`, not `msg.sender`.
    ///      `transferable_` and `forfeitable_` are NOT part of the whitelist hash — the
    ///      owner must coordinate these flag values out-of-band with the caller; see
    ///      contract-level NatSpec for the rationale.
    /// @param user_ Beneficiary of the minted veHEMI NFT.
    /// @param amount_ HEMI amount to lock (must match the whitelisted value byte-for-byte).
    /// @param duration_ Lock duration in seconds (must match the whitelisted value).
    /// @param transferable_ Forwarded to `createLockFor`; false produces a non-transferable position
    ///        with `transferableAfter = unlockTime`.
    /// @param forfeitable_ Forwarded to `createLockFor`; true allows the forfeit admin to
    ///        claw the position back during its non-transferability window.
    function create(
        address user_,
        uint256 amount_,
        uint256 duration_,
        bool transferable_,
        bool forfeitable_
    ) external nonReentrant {
        bytes32 _hash = keccak256(abi.encodePacked(user_, amount_, duration_));

        Status _status = created[_hash];

        if (_status != Status.PENDING) revert PositionCreatedAlready(user_, amount_, duration_);

        // Mark as created BEFORE external calls (checks-effects-interactions)
        created[_hash] = Status.CREATED;

        hemi.safeTransferFrom(msg.sender, address(this), amount_);
        hemi.forceApprove(address(veHemi), amount_);
        veHemi.createLockFor(amount_, duration_, user_, transferable_, forfeitable_);

        emit PositionCreated(_hash, user_, amount_, duration_, transferable_, forfeitable_);
    }

    /// @notice Owner-only batch whitelist / de-whitelist for (user, amount, duration) tuples.
    /// @dev Typical usage: `status_ = PENDING` to open a batch of slots; `status_ = NONE`
    ///      to close them before any caller claims. Setting `status_ = CREATED` directly
    ///      is supported but unusual — it marks a slot as already-claimed without pulling
    ///      HEMI (useful for accounting migrations where positions were minted via a
    ///      different path).
    ///
    ///      `revertIfCreated_` gates the loop against accidentally re-opening a slot that
    ///      has already been minted: when true, any hash currently at CREATED aborts the
    ///      entire transaction. Set false to deliberately flip a CREATED entry back to
    ///      PENDING (rare — only appropriate if the corresponding NFT was forfeited or
    ///      withdrawn and the owner wants to re-issue under the same key).
    /// @param users_ Beneficiaries; parallel array with `amounts_` and `durations_`.
    /// @param amounts_ HEMI amounts, one per entry.
    /// @param durations_ Lock durations in seconds, one per entry.
    /// @param status_ Target status to write for every entry in the batch.
    /// @param revertIfCreated_ If true, any already-CREATED hash in the batch reverts
    ///        the whole call — a defensive check against accidental double-issuance.
    function updateStatus(
        address[] calldata users_,
        uint256[] calldata amounts_,
        uint256[] calldata durations_,
        Status status_,
        bool revertIfCreated_
    ) external onlyOwner {
        uint256 _length = users_.length;

        if (_length != amounts_.length || _length != durations_.length) revert InvalidArrays();

        for (uint256 i; i < _length; ++i) {
            uint256 _amount = amounts_[i];
            uint256 _duration = durations_[i];
            address _user = users_[i];

            bytes32 _hash = keccak256(abi.encodePacked(_user, _amount, _duration));
            if (revertIfCreated_ && created[_hash] == Status.CREATED)
                revert PositionCreatedAlready(_user, _amount, _duration);
            created[_hash] = status_;

            emit StatusUpdated(_hash, _user, _amount, _duration, status_);
        }
    }
}
