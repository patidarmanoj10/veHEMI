// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "forge-std/Test.sol";
import {VeHemi} from "src/VeHemi.sol";
import {VeHemiVoteDelegation} from "src/VeHemiVoteDelegation.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {IVeHemi} from "src/interfaces/IVeHemi.sol";

contract InvariantHandler is Test {
    VeHemi public veHemi;
    VeHemiVoteDelegation public delegation;
    MockERC20 public hemi;

    uint256 private constant YEAR = 365.25 days;
    uint256 private constant MONTH = YEAR / 12;
    uint256 private constant SIX_DAYS = MONTH / 5;

    uint256 private constant MIN_AMOUNT = 11e18; // must be >= VeHemi.MIN_LOCK_AMOUNT (10e18)
    uint256 private constant MAX_AMOUNT = 1_000e18;

    uint256 private constant MIN_DURATION = 2 * SIX_DAYS;
    uint256 private constant MAX_DURATION = 4 * YEAR;

    uint256 MAX_ACCUMULATED_WARP = SIX_DAYS * 255; // max duration between checkpoints the `totalVeHemiSupply()` supports
    uint256 maxWarp = MAX_ACCUMULATED_WARP;

    address[5] public users;
    address admin;

    // V2: Track non-transferrable token IDs for seeding
    uint256[] internal _nonTransferableTokenIds;
    bool public seeded;

    constructor(address admin_, address[5] memory _users) {
        users = _users;
        admin = admin_;

        hemi = new MockERC20("HEMI", "HEMI", 18);

        VeHemi logic = new VeHemi(address(hemi));

        ERC1967Proxy proxy = new ERC1967Proxy(
            address(logic),
            abi.encodeWithSelector(VeHemi.initialize.selector, admin_)
        );
        veHemi = VeHemi(address(proxy));

        delegation = new VeHemiVoteDelegation(address(veHemi));

        vm.startPrank(admin_);
        veHemi.updateVoteDelegation(delegation);
        veHemi.updateForfeitAdmin(admin_);
        vm.stopPrank();
    }

    // Return 0x0 instead of reverting if the NFT does not exist anymore
    function _ownerOf(uint256 tokenId) public returns (address from) {
        (bool ok, bytes memory data) = address(veHemi).call(
            abi.encodeWithSignature("ownerOf(uint256)", tokenId)
        );

        if (!ok) return address(0);

        assembly {
            from := mload(add(data, 32))
        }
    }

    // ── Position creation actions ────────────────────────────────────────

    /// @dev Creates a transferable lock (tracked in global curve only)
    function createLock(uint256 amount, uint256 duration) public returns (uint256 tokenId) {
        amount = bound(amount, MIN_AMOUNT, MAX_AMOUNT);
        duration = bound(duration, MIN_DURATION, MAX_DURATION / 2);

        vm.startPrank(msg.sender);
        hemi.mint(msg.sender, amount);
        hemi.approve(address(veHemi), amount);
        tokenId = veHemi.createLock(amount, duration);
        vm.stopPrank();

        maxWarp = MAX_ACCUMULATED_WARP;
    }

    /// @dev Creates a non-transferrable, non-forfeitable lock (non-transferable curve only).
    ///      Tracks the token ID for seeding.
    function createNonTransferablePosition(uint256 amount, uint256 duration) public returns (uint256 tokenId) {
        amount = bound(amount, MIN_AMOUNT, MAX_AMOUNT);
        duration = bound(duration, MIN_DURATION, MAX_DURATION / 2);

        vm.startPrank(admin);
        hemi.mint(admin, amount);
        hemi.approve(address(veHemi), amount);
        tokenId = veHemi.createLockFor(amount, duration, msg.sender, false, false);
        vm.stopPrank();

        if (!seeded) _nonTransferableTokenIds.push(tokenId);

        maxWarp = MAX_ACCUMULATED_WARP;
    }

    /// @dev Creates a non-transferrable, forfeitable lock (non-transferable + forfeitable curves).
    ///      Tracks the token ID for seeding.
    function createForfeitablePosition(uint256 amount, uint256 duration) public returns (uint256 tokenId) {
        amount = bound(amount, MIN_AMOUNT, MAX_AMOUNT);
        duration = bound(duration, MIN_DURATION, MAX_DURATION / 2);

        vm.startPrank(admin);
        hemi.mint(admin, amount);
        hemi.approve(address(veHemi), amount);
        tokenId = veHemi.createLockFor(amount, duration, msg.sender, false, true);
        vm.stopPrank();

        if (!seeded) _nonTransferableTokenIds.push(tokenId);

        maxWarp = MAX_ACCUMULATED_WARP;
    }

    // ── Seeding action ───────────────────────────────────────────────────

    /// @dev Seeds the non-transferable + forfeitable curves. Can only succeed once.
    ///      Skipped if no locked/forfeitable positions exist yet.
    ///      Filters out tokens that were burned (forfeited/withdrawn) before seeding.
    function seed() public {
        if (seeded) return;
        if (_nonTransferableTokenIds.length == 0) return;

        // Filter to only existing, non-transferrable tokens
        uint256 count;
        uint256[] memory filtered = new uint256[](_nonTransferableTokenIds.length);
        for (uint256 i; i < _nonTransferableTokenIds.length; i++) {
            uint256 id = _nonTransferableTokenIds[i];
            address owner = _ownerOf(id);
            if (owner == address(0)) continue; // burned
            if (veHemi.getLockedBalance(id).amount <= 0) continue; // empty
            filtered[count++] = id;
        }

        if (count == 0) return; // nothing to seed

        // Trim to actual count
        uint256[] memory toSeed = new uint256[](count);
        for (uint256 i; i < count; i++) {
            toSeed[i] = filtered[i];
        }

        // Sort ascending (insertion sort, small array)
        for (uint256 i = 1; i < toSeed.length; i++) {
            uint256 key = toSeed[i];
            uint256 j = i;
            while (j > 0 && toSeed[j - 1] > key) {
                toSeed[j] = toSeed[j - 1];
                j--;
            }
            toSeed[j] = key;
        }

        vm.prank(admin);
        veHemi.seedAndFinalizeNonTransferablePositions(toSeed);

        seeded = true;
        maxWarp = MAX_ACCUMULATED_WARP;
    }

    // ── Mutation actions ─────────────────────────────────────────────────

    function forfeit() public {
        for (uint256 id; id < veHemi.nextTokenId(); id++) {
            if (!veHemi.forfeitable(id)) continue;
            IVeHemi.LockedBalance memory _lock = veHemi.getLockedBalance(id);
            if (_lock.end <= block.timestamp) continue;
            // V2: Forfeit window expires at transferableAfter
            if (block.timestamp >= veHemi.transferableAfter(id)) continue;

            vm.prank(veHemi.forfeitAdmin());
            veHemi.forfeit(id);

            maxWarp = MAX_ACCUMULATED_WARP;

            break;
        }
    }

    function increaseAmount(uint256 amount) public {
        amount = bound(amount, MIN_AMOUNT, MAX_AMOUNT);

        for (uint256 id = 1; id < veHemi.nextTokenId(); id++) {
            IVeHemi.LockedBalance memory _lock = veHemi.getLockedBalance(id);

            if (_lock.amount == 0) continue;
            if (_lock.end <= block.timestamp) continue;

            address owner = veHemi.ownerOf(id);

            vm.startPrank(owner);
            hemi.mint(owner, amount);
            hemi.approve(address(veHemi), amount);
            veHemi.increaseAmount(id, amount);
            vm.stopPrank();

            maxWarp = MAX_ACCUMULATED_WARP;

            break;
        }
    }

    function increaseUnlockTime(uint256 duration) public {
        for (uint256 id = 1; id < veHemi.nextTokenId(); id++) {
            address owner = _ownerOf(id);

            if (owner == address(0)) continue;

            IVeHemi.LockedBalance memory _lock = veHemi.getLockedBalance(id);
            if (block.timestamp >= _lock.end) continue;
            uint256 currentDuration = _lock.end - block.timestamp;
            if (currentDuration + SIX_DAYS > MAX_DURATION) continue;

            duration = bound(duration, currentDuration + SIX_DAYS, MAX_DURATION);

            vm.prank(owner);
            veHemi.increaseUnlockTime(id, duration);

            maxWarp = MAX_ACCUMULATED_WARP;

            break;
        }
    }

    function transfer(uint256 rand) public {
        address to = users[rand % users.length];

        for (uint256 id = 1; id < veHemi.nextTokenId(); id++) {
            address from = _ownerOf(id);

            if (from == address(0) || to == from) continue;
            // Skip non-transferrable positions (would revert)
            if (!veHemi.isTransferable(id)) continue;

            vm.prank(from);
            veHemi.transferFrom(from, to, id);

            maxWarp = MAX_ACCUMULATED_WARP;

            break;
        }
    }

    function withdraw() public {
        for (uint256 id = 1; id < veHemi.nextTokenId(); id++) {
            address owner = _ownerOf(id);

            if (owner == address(0)) continue;

            IVeHemi.LockedBalance memory _lock = veHemi.getLockedBalance(id);

            if (block.timestamp < _lock.end) continue;

            vm.prank(owner);
            veHemi.withdraw(id);

            maxWarp = MAX_ACCUMULATED_WARP;

            break;
        }
    }

    function delegate(uint256 rand) public {
        address delegatee = users[rand % users.length];

        for (uint256 id = 1; id < veHemi.nextTokenId(); id++) {
            address owner = _ownerOf(id);

            if (owner == address(0)) continue;

            IVeHemi.LockedBalance memory _lock = veHemi.getLockedBalance(id);

            uint256 _nextCheckpoint = ((block.timestamp / 1 hours) * 1 hours) + 1 hours;

            if (_nextCheckpoint >= _lock.end) continue;

            vm.prank(owner);
            delegation.delegate(id, delegatee);

            break;
        }
    }

    function warp(uint256 time) public {
        if (maxWarp == 0) return;

        time = bound(time, 1, maxWarp);
        vm.warp(block.timestamp + time);

        maxWarp -= time;
    }

    /// @dev Permissionless bare-checkpoint path. Exercises `_checkpoint(0, ...)`
    ///      which writes to globalPointHistory / nonTransferableGlobalPointHistory /
    ///      forfeitableGlobalPointHistory without an accompanying user mutation.
    function checkpoint() public {
        veHemi.checkpoint();
    }
}
