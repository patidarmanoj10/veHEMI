// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "forge-std/Test.sol";
import "../src/VeHemi.sol";
import "../src/interfaces/IVeHemi.sol";
import {TransparentUpgradeableProxy, ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import "./mocks/MockERC20.sol";
import "./mocks/MockHemiVoteDelegation.sol";

/// @title VeHemiV2UpgradeLocal
/// @notice Local (non-fork) end-to-end test of the production upgrade path:
///         TransparentUpgradeableProxy + ProxyAdmin + `ProxyAdmin.upgradeAndCall`.
///
///         Unlike the existing `test/VeHemi.t.sol` (which uses ERC1967Proxy)
///         and `test/ForkUpgradeNonTransferableCurve.t.sol` (fork-only), this test
///         exercises the EXACT proxy pattern used on Hemi mainnet in a CI-safe,
///         hermetic setting. It catches:
///          - Storage-layout drift across the implementation swap
///          - Admin authorization failures
///          - seedAndFinalizeNonTransferablePositions invocation semantics
///          - Pre-seeding "behaves like V1" guarantee (hooks gated on nonTransferableSeedingFinalized)
contract VeHemiV2UpgradeLocalTest is Test {
    MockERC20 hemi;
    MockHemiVoteDelegation mockDelegation;
    address admin;
    address user;
    ProxyAdmin proxyAdmin;
    TransparentUpgradeableProxy proxy;
    VeHemi veHemi;

    function setUp() public {
        admin = makeAddr("admin");
        user = makeAddr("user");

        hemi = new MockERC20("HEMI", "HEMI", 18);
        mockDelegation = new MockHemiVoteDelegation();

        // Deploy initial implementation and transparent proxy.
        // OZ v5's TransparentUpgradeableProxy constructor creates a ProxyAdmin
        // internally and sets it as the proxy's admin; the caller is the owner.
        VeHemi impl = new VeHemi(address(hemi));
        vm.prank(admin);
        proxy = new TransparentUpgradeableProxy(
            address(impl),
            admin,
            abi.encodeWithSelector(VeHemi.initialize.selector, admin)
        );

        veHemi = VeHemi(address(proxy));

        // Retrieve the ProxyAdmin that was auto-deployed by the TransparentUpgradeableProxy.
        // OZ v5 stores it at the EIP-1967 admin slot.
        bytes32 adminSlot = bytes32(uint256(keccak256("eip1967.proxy.admin")) - 1);
        bytes32 adminRaw = vm.load(address(proxy), adminSlot);
        proxyAdmin = ProxyAdmin(address(uint160(uint256(adminRaw))));

        vm.prank(admin);
        veHemi.updateVoteDelegation(IVeHemiVoteDelegation(address(mockDelegation)));

        hemi.mint(user, 10_000 ether);
        vm.prank(user);
        hemi.approve(address(veHemi), type(uint256).max);
    }

    // =========================================================================
    // Upgrade happy path
    // =========================================================================

    function test_UpgradeProxyViaProxyAdmin_Succeeds() public {
        VeHemi newImpl = new VeHemi(address(hemi));
        vm.prank(admin);
        proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(proxy)), address(newImpl), "");

        // Post-upgrade sanity: new impl is active, proxy's state survives.
        assertEq(address(veHemi.HEMI()), address(hemi));
    }

    struct V1Snapshot {
        uint256 totalLocked;
        uint256 totalVeHemiSupply;
        uint256 epoch;
        uint256 nextTokenId;
        address voteDel;
        address rewardDist;
        address forfeitAdmin;
        address ownerOf_;
        uint256 balanceOf_;
        uint256 balanceOfNFT;
        address provider_;
        uint256 transferableAfter_;
        bool forfeitable_;
        uint256 userPointEpoch_;
        IVeHemi.LockedBalance locked;
        IVeHemi.UserPoint userPoint;
        IVeHemi.Point globalPoint;
        int128 slopeChangeAtLockEnd;
        address ownableOwner;
    }

    function _snapshotV1(uint256 tokenId) internal view returns (V1Snapshot memory s) {
        s.totalLocked = veHemi.totalLocked();
        s.totalVeHemiSupply = veHemi.totalVeHemiSupply();
        s.epoch = veHemi.epoch();
        s.nextTokenId = veHemi.nextTokenId();
        s.voteDel = address(veHemi.voteDelegation());
        s.rewardDist = address(veHemi.rewardDistributor());
        s.forfeitAdmin = veHemi.forfeitAdmin();
        s.ownerOf_ = veHemi.ownerOf(tokenId);
        s.balanceOf_ = veHemi.balanceOf(user);
        s.balanceOfNFT = veHemi.balanceOfNFT(tokenId);
        s.provider_ = veHemi.provider(tokenId);
        s.transferableAfter_ = veHemi.transferableAfter(tokenId);
        s.forfeitable_ = veHemi.forfeitable(tokenId);
        s.userPointEpoch_ = veHemi.userPointEpoch(tokenId);
        s.locked = veHemi.getLockedBalance(tokenId);
        s.userPoint = veHemi.getUserPoint(tokenId, s.userPointEpoch_);
        s.globalPoint = veHemi.getGlobalPoint(s.epoch);
        s.slopeChangeAtLockEnd = veHemi.slopeChanges(uint256(s.locked.end));
        s.ownableOwner = veHemi.owner();
    }

    function _assertV1SnapshotEq(uint256 tokenId, V1Snapshot memory s) internal view {
        assertEq(veHemi.totalLocked(), s.totalLocked, "totalLocked");
        assertEq(veHemi.totalVeHemiSupply(), s.totalVeHemiSupply, "totalVeHemiSupply");
        assertEq(veHemi.epoch(), s.epoch, "epoch");
        assertEq(veHemi.nextTokenId(), s.nextTokenId, "nextTokenId");
        assertEq(address(veHemi.voteDelegation()), s.voteDel, "voteDelegation");
        assertEq(address(veHemi.rewardDistributor()), s.rewardDist, "rewardDistributor");
        assertEq(veHemi.forfeitAdmin(), s.forfeitAdmin, "forfeitAdmin");
        assertEq(veHemi.ownerOf(tokenId), s.ownerOf_, "ownerOf");
        assertEq(veHemi.balanceOf(user), s.balanceOf_, "balanceOf");
        assertEq(veHemi.balanceOfNFT(tokenId), s.balanceOfNFT, "balanceOfNFT");
        assertEq(veHemi.provider(tokenId), s.provider_, "provider");
        assertEq(veHemi.transferableAfter(tokenId), s.transferableAfter_, "transferableAfter");
        assertEq(veHemi.forfeitable(tokenId), s.forfeitable_, "forfeitable");
        assertEq(veHemi.userPointEpoch(tokenId), s.userPointEpoch_, "userPointEpoch");
        IVeHemi.LockedBalance memory lb = veHemi.getLockedBalance(tokenId);
        assertEq(lb.amount, s.locked.amount, "locked.amount");
        assertEq(lb.end, s.locked.end, "locked.end");
        IVeHemi.UserPoint memory up = veHemi.getUserPoint(tokenId, s.userPointEpoch_);
        assertEq(up.owner, s.userPoint.owner, "userPoint.owner");
        assertEq(up.point.bias, s.userPoint.point.bias, "userPoint.bias");
        assertEq(up.point.slope, s.userPoint.point.slope, "userPoint.slope");
        assertEq(up.point.timestamp, s.userPoint.point.timestamp, "userPoint.timestamp");
        assertEq(up.point.blockNumber, s.userPoint.point.blockNumber, "userPoint.blockNumber");
        assertEq(up.point.amount, s.userPoint.point.amount, "userPoint.amount");
        assertEq(up.point.fixedBias, s.userPoint.point.fixedBias, "userPoint.fixedBias");
        IVeHemi.Point memory gp = veHemi.getGlobalPoint(s.epoch);
        assertEq(gp.bias, s.globalPoint.bias, "globalPoint.bias");
        assertEq(gp.slope, s.globalPoint.slope, "globalPoint.slope");
        assertEq(gp.timestamp, s.globalPoint.timestamp, "globalPoint.timestamp");
        assertEq(gp.blockNumber, s.globalPoint.blockNumber, "globalPoint.blockNumber");
        assertEq(gp.amount, s.globalPoint.amount, "globalPoint.amount");
        assertEq(gp.fixedBias, s.globalPoint.fixedBias, "globalPoint.fixedBias");
        assertEq(
            veHemi.slopeChanges(uint256(s.locked.end)),
            s.slopeChangeAtLockEnd,
            "slopeChanges"
        );
        assertEq(veHemi.owner(), s.ownableOwner, "Ownable2Step.owner");
    }

    function test_UpgradePreservesV1State() public {
        vm.prank(user);
        uint256 tokenId = veHemi.createLock(1000 ether, 365 days);

        V1Snapshot memory pre = _snapshotV1(tokenId);

        VeHemi newImpl = new VeHemi(address(hemi));
        vm.prank(admin);
        proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(proxy)), address(newImpl), "");

        _assertV1SnapshotEq(tokenId, pre);
    }

    /// @dev OZ v5 upgradeable bases (ERC721, Ownable2Step, ReentrancyGuardTransient)
    ///      use ERC-7201 namespaced storage at keccak-derived slots OUTSIDE the
    ///      sequential 0–63 range VeHemi occupies. Verify that state stored in
    ///      those namespaces (ownership, NFT balances, approvals, pending-owner
    ///      transfers) survives an implementation swap byte-for-byte. This
    ///      catches a hypothetical OZ-version downgrade or base-reorder that
    ///      would collide with sequential slots.
    struct OZGetterSnapshot {
        address ownerOf_;
        uint256 balance;
        address approved;
        bool isOp;
        uint256 totalSupply_;
        uint256 tokenByIdx;
        uint256 tokenOfOwnerByIdx;
        address ownableOwner;
        address pendingOwner_;
    }

    /// @dev ERC-7201 namespace slot derivation:
    ///      slot = keccak256(abi.encode(uint256(keccak256(id)) - 1)) & ~0xff
    ///      The `& ~0xff` mask clears the low byte of the slot index, forcing
    ///      alignment to a multiple of 256 — gives each namespace a 256-slot
    ///      contiguous runway before colliding with the next namespace.
    ///      See EIP-7201.
    function _ozNamespaceSlot(string memory ns) internal pure returns (bytes32) {
        return keccak256(abi.encode(uint256(keccak256(bytes(ns))) - 1))
            & ~bytes32(uint256(0xff));
    }

    function _snapshotOZGetters(uint256 tokenId, address op) internal view returns (OZGetterSnapshot memory s) {
        s.ownerOf_ = veHemi.ownerOf(tokenId);
        s.balance = veHemi.balanceOf(user);
        s.approved = veHemi.getApproved(tokenId);
        s.isOp = veHemi.isApprovedForAll(user, op);
        s.totalSupply_ = veHemi.totalSupply();
        s.tokenByIdx = veHemi.tokenByIndex(0);
        s.tokenOfOwnerByIdx = veHemi.tokenOfOwnerByIndex(user, 0);
        s.ownableOwner = veHemi.owner();
        s.pendingOwner_ = veHemi.pendingOwner();
    }

    function _assertOZGettersEq(uint256 tokenId, address op, OZGetterSnapshot memory s) internal view {
        assertEq(veHemi.ownerOf(tokenId), s.ownerOf_, "ownerOf");
        assertEq(veHemi.balanceOf(user), s.balance, "balanceOf");
        assertEq(veHemi.getApproved(tokenId), s.approved, "getApproved");
        assertEq(veHemi.isApprovedForAll(user, op), s.isOp, "isApprovedForAll");
        assertEq(veHemi.totalSupply(), s.totalSupply_, "ERC721Enumerable totalSupply");
        assertEq(veHemi.tokenByIndex(0), s.tokenByIdx, "tokenByIndex");
        assertEq(veHemi.tokenOfOwnerByIndex(user, 0), s.tokenOfOwnerByIdx, "tokenOfOwnerByIndex");
        assertEq(veHemi.owner(), s.ownableOwner, "Ownable.owner");
        assertEq(veHemi.pendingOwner(), s.pendingOwner_, "Ownable2Step.pendingOwner");
    }

    /// @dev 5 namespaces × 4 slots each = 20 slots. Initializable is
    ///      included alongside the 4 storage-carrying bases — its
    ///      `_initialized` flag is non-zero after setUp, so the per-namespace
    ///      non-vacuity guard catches a future OZ rename of Initializable
    ///      (which would break the `initializer` modifier silently).
    function _ozNamespaceLabels() internal pure returns (string[5] memory) {
        return [
            string("ERC721"),
            string("ERC721Enumerable"),
            string("Ownable"),
            string("Ownable2Step"),
            string("Initializable")
        ];
    }

    function _ozNamespaceBases() internal pure returns (bytes32[5] memory) {
        return [
            _ozNamespaceSlot("openzeppelin.storage.ERC721"),
            _ozNamespaceSlot("openzeppelin.storage.ERC721Enumerable"),
            _ozNamespaceSlot("openzeppelin.storage.Ownable"),
            _ozNamespaceSlot("openzeppelin.storage.Ownable2Step"),
            _ozNamespaceSlot("openzeppelin.storage.Initializable")
        ];
    }

    function _captureOZNsSlots() internal view returns (bytes32[20] memory pre) {
        bytes32[5] memory bases = _ozNamespaceBases();
        for (uint256 b; b < 5; ++b) {
            for (uint256 i; i < 4; ++i) {
                pre[b * 4 + i] = vm.load(address(proxy), bytes32(uint256(bases[b]) + i));
            }
        }
    }

    function _assertOZNsSlotsEq(bytes32[20] memory pre) internal view {
        bytes32[5] memory bases = _ozNamespaceBases();
        for (uint256 b; b < 5; ++b) {
            for (uint256 i; i < 4; ++i) {
                assertEq(
                    vm.load(address(proxy), bytes32(uint256(bases[b]) + i)),
                    pre[b * 4 + i],
                    string.concat("OZ ns[", vm.toString(b), "] slot+", vm.toString(i))
                );
            }
        }
    }

    function test_UpgradePreservesOZParentStorage() public {
        // Mint an NFT and stage a pending-ownership transfer.
        vm.prank(user);
        uint256 tokenId = veHemi.createLock(1000 ether, 365 days);
        address newOwner = makeAddr("newOwner");
        vm.prank(admin);
        veHemi.transferOwnership(newOwner);

        // Approve an operator (hits _tokenApprovals / _operatorApprovals slots).
        address operator = makeAddr("operator");
        vm.prank(user);
        veHemi.approve(operator, tokenId);
        address operator2 = makeAddr("operator2");
        vm.prank(user);
        veHemi.setApprovalForAll(operator2, true);

        // Snapshot raw ERC-7201 namespace slots + getter outputs.
        bytes32[20] memory preNs = _captureOZNsSlots();
        OZGetterSnapshot memory preGetters = _snapshotOZGetters(tokenId, operator2);

        // Non-vacuity guard: each of the 5 OZ namespaces must have at least
        // one non-zero slot in the captured base+0..3 range. A PER-NAMESPACE
        // guard catches partial renames (where only 1 of 5 namespaces was
        // silently moved by an OZ upgrade), which a single all-zero OR guard
        // would miss. All 5 namespaces are guaranteed non-zero at this point:
        //   ERC721: _name/_symbol slots populated by __ERC721_init.
        //   ERC721Enumerable: _allTokens length incremented by mint.
        //   Ownable: _owner = admin.
        //   Ownable2Step: _pendingOwner = newOwner (via transferOwnership).
        //   Initializable: _initialized = 1 after initialize() consumed the slot.
        string[5] memory nsLabels = _ozNamespaceLabels();
        for (uint256 b; b < 5; ++b) {
            bool nsNonZero;
            for (uint256 i; i < 4; ++i) {
                if (preNs[b * 4 + i] != bytes32(0)) { nsNonZero = true; break; }
            }
            assertTrue(
                nsNonZero,
                string.concat(
                    "OZ namespace ",
                    nsLabels[b],
                    " all-zero pre-upgrade - test vacuous for this ns"
                )
            );
        }

        // Upgrade.
        VeHemi newImpl = new VeHemi(address(hemi));
        vm.prank(admin);
        proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(proxy)), address(newImpl), "");

        // Raw slot bytes + getter outputs must be identical post-upgrade.
        _assertOZNsSlotsEq(preNs);
        _assertOZGettersEq(tokenId, operator2, preGetters);

        // Pending ownership handoff must still be completable post-upgrade.
        vm.prank(newOwner);
        veHemi.acceptOwnership();
        assertEq(veHemi.owner(), newOwner, "acceptOwnership after upgrade");
    }

    function test_UpgradeCallableOnlyByAdmin() public {
        VeHemi newImpl = new VeHemi(address(hemi));
        // Non-admin caller must be rejected by ProxyAdmin's onlyOwner.
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", attacker)
        );
        proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(proxy)), address(newImpl), "");

        // And the admin must still be able to upgrade after a rejected attack.
        vm.prank(admin);
        proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(proxy)), address(newImpl), "");
    }

    function test_DoubleInitializeReverts() public {
        // The initializer was consumed in setUp. A direct initialize call must revert.
        vm.expectRevert(abi.encodeWithSignature("InvalidInitialization()"));
        veHemi.initialize(admin);
    }

    // =========================================================================
    // nonTransferableSeedingFinalized gate: pre-seeding, V2 must behave like V1.
    // =========================================================================

    function test_PreSeed_V2BehavesAsV1() public {
        // No seeding yet — nonTransferableSeedingFinalized is false.
        assertFalse(veHemi.nonTransferableSeedingFinalized());
        assertEq(veHemi.nonTransferableTotalVeHemiSupply(), 0);
        assertEq(veHemi.forfeitableTotalVeHemiSupply(), 0);

        // Normal flows must still work exactly like V1.
        vm.prank(user);
        uint256 tokenId = veHemi.createLock(1000 ether, 365 days);

        assertGt(veHemi.balanceOfNFT(tokenId), 0, "voting power should be non-zero pre-seed");
        assertGt(veHemi.totalVeHemiSupply(), 0, "total supply should be non-zero pre-seed");
    }

    function test_SeedAndFinalize_OnlyOnce() public {
        // Create a non-transferable position eligible for seeding.
        vm.prank(user);
        uint256 tokenId = veHemi.createLockFor(1000 ether, 365 days, user, false, false);

        uint256[] memory ids = new uint256[](1);
        ids[0] = tokenId;

        vm.prank(admin);
        veHemi.seedAndFinalizeNonTransferablePositions(ids);
        assertTrue(veHemi.nonTransferableSeedingFinalized());

        // Second attempt must revert with the specific selector.
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSignature("SeedingAlreadyFinalized()"));
        veHemi.seedAndFinalizeNonTransferablePositions(ids);
    }

    function test_SeedAndFinalize_OnlyOwner() public {
        uint256[] memory ids = new uint256[](0);
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", attacker)
        );
        veHemi.seedAndFinalizeNonTransferablePositions(ids);
    }

    /// @dev Front-run defense on the production upgrade path. Between the
    ///      Safe batch's tx 2 (V2 impl upgrade) and tx 3 (seed), a non-admin
    ///      EOA must be unable to hijack ownership via `initialize(attacker)`.
    function test_UpgradeThenInitializeFrontRun_Reverts() public {
        VeHemi newImpl = new VeHemi(address(hemi));
        vm.prank(admin);
        proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(proxy)), address(newImpl), "");

        address[] memory attackers = new address[](3);
        attackers[0] = makeAddr("attacker1");
        attackers[1] = makeAddr("attacker2");
        attackers[2] = user;

        for (uint256 i; i < attackers.length; ++i) {
            vm.prank(attackers[i]);
            vm.expectRevert(abi.encodeWithSignature("InvalidInitialization()"));
            veHemi.initialize(attackers[i]);
        }

        // Admin ownership must be intact.
        assertEq(veHemi.owner(), admin, "admin ownership lost");
    }

    /// @dev Lock in semantics of `seedAndFinalizeNonTransferablePositions([])` — whether
    ///      it reverts or flips the latch must not accidentally change. Current
    ///      behavior: reverts with EmptyArray to prevent the admin from
    ///      finalizing without seeding any positions.
    function test_SeedAndFinalize_EmptyArray_Reverts() public {
        uint256[] memory empty = new uint256[](0);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSignature("EmptyArray()"));
        veHemi.seedAndFinalizeNonTransferablePositions(empty);
        assertFalse(veHemi.nonTransferableSeedingFinalized(), "latch must remain unset when array empty");
    }

    // =========================================================================
    // Full deploy-script simulation: upgrade + seed in a sequenced Safe batch.
    // =========================================================================

    function test_FullUpgradeAndSeedFlow() public {
        // 1. Populate V1 state.
        vm.prank(user);
        uint256 tokenId = veHemi.createLockFor(1000 ether, 365 days, user, false, false);
        uint256 preTotalSupply = veHemi.totalVeHemiSupply();

        // 2. Deploy new impl.
        VeHemi newImpl = new VeHemi(address(hemi));

        // 3. Upgrade via ProxyAdmin (step 2 of deploy/04_upgrade_vehemi_v2.ts).
        vm.prank(admin);
        proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(proxy)), address(newImpl), "");

        // 4. Assert V1 state preserved.
        assertEq(veHemi.totalVeHemiSupply(), preTotalSupply);
        assertEq(veHemi.ownerOf(tokenId), user);
        assertFalse(veHemi.nonTransferableSeedingFinalized());

        // 5. Seed (step 3 of deploy script).
        uint256[] memory ids = new uint256[](1);
        ids[0] = tokenId;
        vm.prank(admin);
        veHemi.seedAndFinalizeNonTransferablePositions(ids);

        // 6. Verify subcurves now populated.
        assertTrue(veHemi.nonTransferableSeedingFinalized());
        assertGt(veHemi.nonTransferableTotalVeHemiSupply(), 0);

        // 7. Global curve still correct (additive with V2, no regression).
        assertEq(veHemi.totalVeHemiSupply(), preTotalSupply);
    }

    function test_UpgradeWithoutSeedFlow_BehavesAsV1() public {
        // Stage where upgrade tx1 succeeded but seed tx (tx3 in Safe batch)
        // has not yet run. V2 is live but dormant. Must behave exactly like V1.
        vm.prank(user);
        uint256 tokenId = veHemi.createLock(1000 ether, 365 days);

        VeHemi newImpl = new VeHemi(address(hemi));
        vm.prank(admin);
        proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(proxy)), address(newImpl), "");

        assertFalse(veHemi.nonTransferableSeedingFinalized());
        assertEq(veHemi.nonTransferableTotalVeHemiSupply(), 0);
        assertEq(veHemi.forfeitableTotalVeHemiSupply(), 0);

        // User ops work.
        vm.prank(user);
        veHemi.increaseAmount(tokenId, 500 ether);
        assertGt(veHemi.getLockedBalance(tokenId).amount, 1000 ether);
    }
}
