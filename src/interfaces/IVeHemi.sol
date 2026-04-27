// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721Enumerable} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Enumerable.sol";
import {IVeHemiVoteDelegation} from "./IVeHemiVoteDelegation.sol";
import {IRewardDistributor} from "./IRewardDistributor.sol";

interface IVeHemi is IERC721Enumerable {
    // --- Structs ---
    struct Point {
        int128 bias;
        int128 slope;
        uint64 timestamp;
        uint64 blockNumber;
        uint128 amount;
        uint256 fixedBias; // for v2+ use
    }

    struct UserPoint {
        Point point;
        address owner;
    }

    struct LockedBalance {
        int128 amount;
        uint64 end;
    }

    // --- Events ---
    event Deposit(
        address indexed provider,
        uint256 indexed tokenId,
        uint256 amount,
        uint256 lockTime,
        uint256 timestamp
    );

    event Withdraw(
        address indexed provider,
        uint256 indexed tokenId,
        uint256 amount,
        uint256 timestamp
    );
    event Lock(
        address indexed provider,
        address indexed account,
        uint256 indexed tokenId,
        uint256 amount,
        uint256 start,
        uint256 lockTime,
        uint256 extraData,
        bool transferable,
        bool forfeitable
    );
    event Checkpoint(uint256 epoch, uint256 tokenId, LockedBalance oldLock, LockedBalance newLock);

    event VoteDelegationUpdated(
        IVeHemiVoteDelegation indexed oldVoteDelegation,
        IVeHemiVoteDelegation indexed newVoteDelegation
    );

    event RewardDistributorUpdated(
        IRewardDistributor indexed oldRewardDistributor,
        IRewardDistributor indexed newRewardDistributor
    );

    event ForfeitAdminUpdated(address indexed oldForfeitAdmin, address indexed newForfeitAdmin);

    // --- V2 Events ---
    event NonTransferableSeedingFinalized(uint256 epoch);
    event RewardUpdateFailed(uint256 indexed tokenId);
    event DelegationUpdateFailed(uint256 indexed delegator);

    // --- Errors ---
    // Declared in VeHemi.sol (not here) to avoid Solidity duplicate-identifier
    // conflicts when both IVeHemi and VeHemi are imported in the same compilation unit.
    // Errors are included in VeHemi's ABI and can be decoded from revert data.
    //
    // AddressIsNull, AmountIsZero, AmountTooSmall, EmptyArray, ForfeitWindowExpired,
    // InvalidConfiguration, LockDurationTooLong, LockDurationTooShort, LockExpired,
    // LockNotExpired, NewLockDurationNotGreater, NoExistingLock, NotForfeitAdmin,
    // NotForfeitable, NotNonTransferrable, NotOwner, NotTransferable, OwnerIsZero,
    // SeedingAlreadyFinalized, TokenDoesNotExist, UnsortedOrDuplicateTokenIds

    // --- External/Public Functions ---
    function HEMI() external view returns (IERC20);
    function initialize(address owner) external;
    function checkpoint() external;
    function createLock(uint256 amount, uint256 lockDuration) external returns (uint256 tokenId);
    function createLockFor(
        uint256 amount,
        uint256 lockDuration,
        address account,
        bool transferable,
        bool forfeitable
    ) external returns (uint256 tokenId);
    function increaseAmount(uint256 tokenId, uint256 amount) external;
    function increaseUnlockTime(uint256 tokenId, uint256 lockDuration) external;
    function withdraw(uint256 tokenId) external;
    function forfeit(uint256 tokenId) external;
    function getUserPoint(uint256 tokenId, uint256 epoch) external view returns (UserPoint memory);
    function getGlobalPoint(uint256 epoch) external view returns (Point memory);
    function getLockedBalance(uint256 tokenId) external view returns (LockedBalance memory);
    function isTransferable(uint256 tokenId) external view returns (bool);
    function totalLocked() external view returns (uint256);
    function epoch() external view returns (uint256);
    function userPointEpoch(uint256 tokenId) external view returns (uint256);
    function nextTokenId() external view returns (uint256);
    function provider(uint256 tokenId) external view returns (address);
    function transferableAfter(uint256 tokenId) external view returns (uint256);
    function forfeitable(uint256 tokenId) external view returns (bool);
    function forfeitAdmin() external view returns (address);
    function slopeChanges(uint256 timestamp) external view returns (int128);
    function balanceOfNFT(uint256 tokenId) external view returns (uint256);
    function balanceOfNFTAt(uint256 tokenId, uint256 timestamp) external view returns (uint256);
    function balanceAndOwnerOfNFTAt(
        uint256 tokenId,
        uint256 timestamp
    ) external view returns (uint256, address);
    function totalVeHemiSupply() external view returns (uint256);
    function totalVeHemiSupplyAt(uint256 timestamp_) external view returns (uint256);

    // --- V2 Non-transferable + Forfeitable Curve Functions ---
    function seedAndFinalizeNonTransferablePositions(uint256[] calldata tokenIds) external;
    function nonTransferableTotalVeHemiSupply() external view returns (uint256);
    function nonTransferableTotalVeHemiSupplyAt(uint256 timestamp) external view returns (uint256);
    function forfeitableTotalVeHemiSupply() external view returns (uint256);
    function forfeitableTotalVeHemiSupplyAt(uint256 timestamp) external view returns (uint256);
    function supplyBreakdown() external view returns (uint256 total, uint256 locked_, uint256 forfeitable_, uint256 transferable);
    // nonTransferableSeedingFinalized(), nonTransferableSlopeChanges(uint256), and forfeitableSlopeChanges(uint256)
    // are exposed as public state variables via VeHemiStorageV2 (auto-generated getters).
}
