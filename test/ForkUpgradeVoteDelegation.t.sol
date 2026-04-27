// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "forge-std/Test.sol";
import "../src/VeHemiVoteDelegation.sol";
import "../src/interfaces/IVeHemiVoteDelegation.sol";
import "../src/interfaces/IVeHemi.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Minimal typed interface for the Hemi mainnet ProxyAdmin, which
///      uses the OpenZeppelin v4 `upgrade(address,address)` signature.
///      Declared here rather than imported from OZ v5 (whose ProxyAdmin
///      uses the different `upgradeAndCall(proxy,impl,data)` shape).
interface IProxyAdminV4 {
    function upgrade(address proxy, address implementation) external;
}

/**
 * @title ForkUpgradeVoteDelegationTest
 * @notice Fork test for the VeHemiVoteDelegation proxy upgrade on Hemi mainnet.
 *         Specifically validates that the V1/V2 chain-inheritance refactor
 *         preserves bit-identical storage across the upgrade and that real
 *         delegation state survives. Complements ForkUpgradeNonTransferableCurve.t.sol
 *         which covers the VeHemi proxy.
 *
 * @dev The production Safe batch (deploy/04_upgrade_vehemi_v2.ts) upgrades the
 *      delegation proxy as step 1 BEFORE upgrading VeHemi. This test replays
 *      that single step in isolation on a mainnet fork. New tests here:
 *        1. testForkDelegationRawSlotPreservation — bit-identical slots 0-49
 *           pre/post upgrade on the live proxy. Pre-upgrade assertion that
 *           V2 slots (4, 5, gap 6-49) are zero pins the guarantee that the
 *           Aragon additions land in untouched storage.
 *        2. testForkDelegationProxyAdminAndImplSlot — ERC-1967 admin slot
 *           preserved; implementation slot rotates to the new bytecode.
 *        3. testForkKnownDelegationPreservedPostUpgrade — a live delegation
 *           (picked by scanning the LOCKED_TOKEN_IDS range for an active
 *           record) must decode identically pre/post via the public getter.
 *        4. testForkDelegationAragonSlotsDefaultZero — post-upgrade the new
 *           V2 fields (autoDelegate, trustedAdapter) default to zero. Verifies
 *           the upgrade does not accidentally populate them.
 *        5. testForkDelegationSetTrustedAdapterPostUpgrade — exercises the
 *           new setter path to confirm slot 5 (trustedAdapter) is writable
 *           and that the getter reads it back correctly.
 *
 * Run with:
 *     forge test --match-contract ForkUpgradeVoteDelegationTest --fork-url $HEMI_RPC_URL -vvv
 */
contract ForkUpgradeVoteDelegationTest is Test {
    // -- Known Hemi mainnet addresses --
    address constant VEHEMI_PROXY = 0x371d3718D5b7F75EAb050FAe6Da7DF3092031c89;
    address constant VOTE_DELEGATION_PROXY = 0xBF5b2f370370494B8A4575962512dd3ea7c29e2d;
    address constant PROXY_ADMIN = 0x7e4D4FB40449A56377fD54fC6Dd800fa202c0f0F;
    address constant GNOSIS_SAFE = 0x694fA0816999Da16E8783C0f5cDE68c13a33C4e6;
    address constant HEMI_TOKEN = 0x99e3dE3817F6081B2568208337ef83295b7f591D;

    // LOCKED_TOKEN_IDS range per deploy/04_upgrade_vehemi_v2.ts
    uint256 constant LOCKED_RANGE_START = 28660;
    uint256 constant LOCKED_RANGE_END = 28806; // exclusive

    // ERC-1967 slots
    bytes32 constant IMPL_SLOT =
        bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);
    bytes32 constant ADMIN_SLOT =
        bytes32(uint256(keccak256("eip1967.proxy.admin")) - 1);

    // EIP-712 (must match VeHemiVoteDelegation.sol private constants).
    bytes32 constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 constant DELEGATION_TYPEHASH =
        keccak256("Delegation(uint256 delegator,address delegatee,uint256 nonce,uint256 expiry)");
    bytes32 constant EIP712_NAME_HASH = keccak256(bytes("veHEMIDelegation"));
    bytes32 constant EIP712_VERSION_HASH = keccak256(bytes("1.0.0"));

    VeHemiVoteDelegation delegation;
    IVeHemi veHemi;

    /// @dev Skip tests when not running on a Hemi fork.
    modifier onlyFork() {
        if (block.chainid != 43111) {
            vm.skip(true);
            return;
        }
        _;
    }

    function setUp() public {
        // Optional block pin: if HEMI_FORK_BLOCK is set in env, fork `hemi`
        // at that block (see foundry.toml [rpc_endpoints]). This gives
        // reproducible results and lets Foundry's RPC cache absorb repeated
        // runs. When unset, fall back to whatever fork the CLI provided.
        uint256 pinnedBlock = vm.envOr("HEMI_FORK_BLOCK", uint256(0));
        if (pinnedBlock != 0) {
            vm.createSelectFork("hemi", pinnedBlock);
        }

        if (block.chainid != 43111) {
            vm.skip(true);
            return;
        }
        delegation = VeHemiVoteDelegation(VOTE_DELEGATION_PROXY);
        veHemi = IVeHemi(VEHEMI_PROXY);
    }

    // ─── Helpers ─────────────────────────────────────────────────────────

    /// @dev Replay step 1 of deploy/04_upgrade_vehemi_v2.ts: deploy a new
    ///      VeHemiVoteDelegation impl and call ProxyAdmin.upgrade as the
    ///      Gnosis Safe (which owns ProxyAdmin on mainnet).
    function _upgradeDelegationProxy() internal returns (VeHemiVoteDelegation) {
        VeHemiVoteDelegation newImpl = new VeHemiVoteDelegation(VEHEMI_PROXY);
        vm.prank(GNOSIS_SAFE);
        IProxyAdminV4(PROXY_ADMIN).upgrade(VOTE_DELEGATION_PROXY, address(newImpl));
        return newImpl;
    }

    /// @dev Find the first token in the LOCKED range that has a live
    ///      non-zero delegation stored in slot 0 (delegatee != address(0)).
    ///      Returns (tokenId, delegatee) or reverts if none is found.
    function _findLiveDelegation() internal view returns (uint256, address) {
        for (uint256 id = LOCKED_RANGE_START; id < LOCKED_RANGE_END; ++id) {
            (address delegatee,,,, ) = delegation.delegations(id);
            if (delegatee != address(0)) {
                return (id, delegatee);
            }
        }
        revert("no live delegation found in LOCKED range");
    }

    // ─── Tests ───────────────────────────────────────────────────────────

    /// @notice Slots 0-49 of the delegation proxy must be bit-identical
    ///         before and after the upgrade.
    ///
    ///         Pre-upgrade, slots 4 (autoDelegate), 5 (trustedAdapter), and
    ///         6-49 (the refactored __gapV2) MUST all read zero — the
    ///         deployed V1 impl never wrote them. Asserting this pre-upgrade
    ///         makes the post-upgrade equality non-vacuous for those slots.
    function testForkDelegationRawSlotPreservation() public onlyFork {
        bytes32[50] memory pre;
        for (uint256 i; i < 50; ++i) {
            pre[i] = vm.load(VOTE_DELEGATION_PROXY, bytes32(i));
        }

        // Slots 4-49 must be zero pre-upgrade. Slots 0-3 are mapping bases
        // and will also read zero (data lives at keccak-derived addresses);
        // we don't assert that to keep the test future-proof against any
        // legitimate reason a base slot could be non-zero.
        for (uint256 i = 4; i < 50; ++i) {
            assertEq(
                pre[i],
                bytes32(0),
                string.concat("delegation slot ", vm.toString(i), " non-zero pre-upgrade")
            );
        }

        _upgradeDelegationProxy();

        for (uint256 i; i < 50; ++i) {
            bytes32 post = vm.load(VOTE_DELEGATION_PROXY, bytes32(i));
            assertEq(
                post,
                pre[i],
                string.concat("delegation slot ", vm.toString(i), " changed across upgrade")
            );
        }
    }

    /// @notice The ProxyAdmin ERC-1967 admin slot must survive the upgrade;
    ///         the implementation slot must rotate to the newly-deployed impl.
    function testForkDelegationProxyAdminAndImplSlot() public onlyFork {
        bytes32 adminPre = vm.load(VOTE_DELEGATION_PROXY, ADMIN_SLOT);
        bytes32 implPre = vm.load(VOTE_DELEGATION_PROXY, IMPL_SLOT);

        assertEq(
            address(uint160(uint256(adminPre))),
            PROXY_ADMIN,
            "ERC-1967 admin slot did not match PROXY_ADMIN pre-upgrade"
        );
        assertTrue(
            address(uint160(uint256(implPre))) != address(0),
            "ERC-1967 impl slot unexpectedly zero pre-upgrade"
        );

        VeHemiVoteDelegation newImpl = _upgradeDelegationProxy();

        bytes32 adminPost = vm.load(VOTE_DELEGATION_PROXY, ADMIN_SLOT);
        bytes32 implPost = vm.load(VOTE_DELEGATION_PROXY, IMPL_SLOT);

        assertEq(adminPost, adminPre, "ERC-1967 admin slot changed across upgrade");
        assertEq(
            address(uint160(uint256(implPost))),
            address(newImpl),
            "ERC-1967 impl slot did not rotate to new impl"
        );
        assertTrue(implPost != implPre, "ERC-1967 impl slot did not change");
    }

    /// @notice A real on-chain delegation must decode identically pre/post
    ///         upgrade via the public getter. Uses a scanning helper so the
    ///         test survives individual tokens being forfeited/withdrawn.
    function testForkKnownDelegationPreservedPostUpgrade() public onlyFork {
        (uint256 tokenId, address delegatee) = _findLiveDelegation();

        (
            address preDelegatee,
            uint48 preEnd,
            uint96 preBias,
            uint96 preAmount,
            uint64 preSlope
        ) = delegation.delegations(tokenId);
        assertEq(preDelegatee, delegatee, "_findLiveDelegation inconsistency");
        assertTrue(preDelegatee != address(0), "pre-delegatee is zero");
        assertTrue(preBias > 0, "pre-bias is zero - would be vacuous");

        _upgradeDelegationProxy();

        (
            address postDelegatee,
            uint48 postEnd,
            uint96 postBias,
            uint96 postAmount,
            uint64 postSlope
        ) = delegation.delegations(tokenId);

        assertEq(postDelegatee, preDelegatee, "Delegation.delegatee changed");
        assertEq(postEnd, preEnd, "Delegation.end changed");
        assertEq(postBias, preBias, "Delegation.bias changed");
        assertEq(postAmount, preAmount, "Delegation.amount changed");
        assertEq(postSlope, preSlope, "Delegation.slope changed");
    }

    /// @notice The V2 Aragon fields (autoDelegate, trustedAdapter) must
    ///         default to zero after the upgrade — the upgrade MUST NOT
    ///         accidentally populate them with stray data from any adjacent
    ///         slot.
    function testForkDelegationAragonSlotsDefaultZero() public onlyFork {
        _upgradeDelegationProxy();

        // trustedAdapter lives directly at slot 5 → read via getter.
        assertEq(
            delegation.trustedAdapter(),
            address(0),
            "trustedAdapter unexpectedly populated post-upgrade"
        );

        // autoDelegate[arbitrary address] must read address(0) by default.
        // Sample a handful of live delegatees found in the LOCKED range; the
        // mapping is never written during the upgrade so a per-owner check is
        // pointless beyond a non-zero sample. Cap size is RPC-budget driven
        // (public Hemi RPC caps at 300 req/min).
        uint256 sampleCap = vm.envOr("FORK_SAMPLE_SIZE", uint256(20));
        uint256 checked;
        for (uint256 id = LOCKED_RANGE_START; id < LOCKED_RANGE_END && checked < sampleCap; ++id) {
            (address delegatee,,,, ) = delegation.delegations(id);
            if (delegatee != address(0)) {
                assertEq(
                    delegation.autoDelegate(delegatee),
                    address(0),
                    "autoDelegate unexpectedly populated for a live delegatee"
                );
                checked++;
            }
        }
        assertTrue(checked > 0, "could not find any live delegatees to spot-check");
    }

    /// @notice Post-upgrade, the new setTrustedAdapter path must work end-to-end:
    ///         the VeHemi-owner (Gnosis Safe) calls setTrustedAdapter, and the
    ///         getter reads back the new value from slot 5.
    function testForkDelegationSetTrustedAdapterPostUpgrade() public onlyFork {
        _upgradeDelegationProxy();

        address newAdapter = makeAddr("newTrustedAdapter");

        // Only the VeHemi owner (Gnosis Safe on mainnet) can call.
        vm.prank(GNOSIS_SAFE);
        delegation.setTrustedAdapter(newAdapter);

        assertEq(
            delegation.trustedAdapter(),
            newAdapter,
            "setTrustedAdapter did not persist to slot 5"
        );

        // Raw slot read confirms slot 5 is the backing storage.
        bytes32 slot5 = vm.load(VOTE_DELEGATION_PROXY, bytes32(uint256(5)));
        assertEq(
            address(uint160(uint256(slot5))),
            newAdapter,
            "slot 5 raw value does not match getter"
        );
    }

    /// @notice Unauthorized callers must not be able to call setTrustedAdapter
    ///         post-upgrade.
    function testForkDelegationSetTrustedAdapterUnauthorizedReverts() public onlyFork {
        _upgradeDelegationProxy();

        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert(VeHemiVoteDelegation.NotVeHemiOwner.selector);
        delegation.setTrustedAdapter(attacker);
    }

    // ─── Functional + state-preservation suite ───────────────────────────
    //
    // The tests above pin STORAGE BYTES (raw slot 0-49 equality, ERC-1967
    // slots, one live delegation struct round-trip). They do not exercise
    // the contract after the upgrade, and they do not verify mapping data
    // at keccak-derived addresses. The tests below fill that gap:
    //
    //   6.  testForkDelegateFunctionalPostUpgrade
    //       Calls delegate() post-upgrade as the real NFT owner and
    //       verifies voting power shifts across the checkpoint boundary.
    //   7.  testForkDelegateBySigPostUpgrade
    //       Mints a fresh position owned by a test-generated key, upgrades,
    //       then relays a valid EIP-712 signature. Pins the EIP-712 domain
    //       and nonce semantics across the upgrade.
    //   8.  testForkGetPastVotesRoundTrip
    //       Samples getVotes + getPastVotes at five historical timestamps
    //       pre/post upgrade and asserts bit-for-bit equality.
    //   9.  testForkDelegationCheckpointHistoryPreservation
    //       For every unique live delegatee in the LOCKED range, captures
    //       the full DelegateCheckpoint[] array pre/post and asserts
    //       element-level equality on all five struct fields.
    //  10.  testForkSetTrustedAdapterAndDelegateAllFor
    //       Safe sets trustedAdapter, adapter calls delegateAllFor, and
    //       every non-expired NFT owned by the target account must be
    //       re-delegated. Pins autoDelegate is set too.
    //  11.  testForkDelegationHashSnapshotPreservation
    //       Full-state hash-aggregate: folds every live delegation + every
    //       unique delegatee's full checkpoint history + their nonces into
    //       a single bytes32 via the DelegationSnapshot helper, captured
    //       pre/post upgrade. Compresses the entire mapping-preservation
    //       check into a single assertion (2 external calls per side) with
    //       a non-vacuity guard against the zero hash.

    /// @dev Scan the LOCKED range and return the first `cap` tokenIds with a
    ///      non-zero delegatee. The cap keeps RPC budget bounded for CI
    ///      (public Hemi RPC throttles at 300 req/min; a single run scans
    ///      ~146 tokens plus follow-up reads, which can exhaust the window).
    ///      Callers that want the full set override via `FORK_SAMPLE_SIZE`.
    function _collectLiveTokenIds() internal view returns (uint256[] memory out) {
        uint256 cap = vm.envOr("FORK_SAMPLE_SIZE", uint256(20));
        uint256[] memory buf = new uint256[](cap);
        uint256 n;
        for (uint256 id = LOCKED_RANGE_START; id < LOCKED_RANGE_END && n < cap; ++id) {
            (address d,,,,) = delegation.delegations(id);
            if (d != address(0)) {
                buf[n++] = id;
            }
        }
        out = new uint256[](n);
        for (uint256 i; i < n; ++i) out[i] = buf[i];
    }

    /// @dev From a list of tokenIds, collect the deduplicated set of
    ///      delegatee addresses. Quadratic but bounded by the LOCKED range.
    function _uniqueDelegatees(uint256[] memory tokenIds)
        internal
        view
        returns (address[] memory out)
    {
        address[] memory buf = new address[](tokenIds.length);
        uint256 n;
        for (uint256 i; i < tokenIds.length; ++i) {
            (address d,,,,) = delegation.delegations(tokenIds[i]);
            bool seen;
            for (uint256 j; j < n; ++j) {
                if (buf[j] == d) { seen = true; break; }
            }
            if (!seen) buf[n++] = d;
        }
        out = new address[](n);
        for (uint256 i; i < n; ++i) out[i] = buf[i];
    }

    /// @dev Build the EIP-712 digest a delegateBySig signer must produce.
    ///      Mirrors the hashing in VeHemiVoteDelegation.delegateBySig.
    function _delegateBySigDigest(
        uint256 delegator,
        address delegatee,
        uint256 nonce,
        uint256 expiry
    ) internal view returns (bytes32) {
        bytes32 domainSeparator = keccak256(
            abi.encode(
                DOMAIN_TYPEHASH,
                EIP712_NAME_HASH,
                EIP712_VERSION_HASH,
                block.chainid,
                address(delegation)
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(DELEGATION_TYPEHASH, delegator, delegatee, nonce, expiry)
        );
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }

    /// @dev Parse a recorded log set for `DelegateVotesChanged` events and
    ///      assert the expected DIRECTIONALITY on old/new delegatees:
    ///        - at least one emit for `oldDelegatee` with previousVotes > newVotes
    ///          (votes being removed)
    ///        - at least one emit for `newDelegatee` with newVotes > previousVotes
    ///          (votes being added)
    ///      A previousVotes↔newVotes payload swap (the mutation class event-
    ///      topic-only pins miss) inverts both directions and fires this
    ///      assertion on both sides.
    function _assertDelegateVotesChangedDirectionality(
        Vm.Log[] memory logs,
        address oldDelegatee,
        address newDelegatee
    ) internal pure {
        bytes32 sig = keccak256("DelegateVotesChanged(address,uint256,uint256)");
        bool sawOldDecrease;
        bool sawNewIncrease;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length < 2 || logs[i].topics[0] != sig) continue;
            address d = address(uint160(uint256(logs[i].topics[1])));
            (uint256 prevVotes, uint256 newVotes) = abi.decode(logs[i].data, (uint256, uint256));
            if (d == oldDelegatee && prevVotes > newVotes) sawOldDecrease = true;
            if (d == newDelegatee && newVotes > prevVotes) sawNewIncrease = true;
        }
        require(sawOldDecrease, "no DelegateVotesChanged(oldDelegatee) with decreasing payload");
        require(sawNewIncrease, "no DelegateVotesChanged(newDelegatee) with increasing payload");
    }

    // ─── 6. Functional delegate() post-upgrade ───────────────────────────

    /// @notice The contract must be FUNCTIONALLY alive after the upgrade:
    ///         a real NFT owner can call delegate(), and the delegated
    ///         voting power moves from `oldDelegatee` to `newDelegatee` by
    ///         exactly the target token's contribution (not just "drops"
    ///         — a no-op `_delegate` would satisfy a drop-assertion via
    ///         natural decay). A storage-clean upgrade that broke
    ///         `_delegate` arithmetic would pass every other test and fail
    ///         this one's quantitative diff check.
    function testForkDelegateFunctionalPostUpgrade() public onlyFork {
        (uint256 tokenId, address oldDelegatee) = _findLiveDelegation();
        address owner = veHemi.ownerOf(tokenId);
        address newDelegatee = makeAddr("newDelegatee");
        // Avoid picking a delegatee that happens to already hold votes (would
        // make the "new delegatee votes > 0" assertion vacuously true).
        require(
            delegation.getVotes(newDelegatee) == 0,
            "newDelegatee already has votes - pick a fresh addr"
        );
        require(
            newDelegatee != owner,
            "newDelegatee collides with owner - pick a fresh addr"
        );

        _upgradeDelegationProxy();

        // Future timestamp we'll warp to. Chosen to cross the next
        // CHECKPOINT_INTERVAL (1 hour) boundary regardless of sub-hour
        // alignment of block.timestamp at call time.
        uint256 futureTs = block.timestamp + 1 hours + 1;

        // Quantitative baseline: the exact contribution this token will
        // carry at futureTs. After the redelegation, this amount must move
        // from oldDelegatee to newDelegatee — distinguishing real delegation
        // from pure time decay.
        uint256 tokenContribFuture = veHemi.balanceOfNFTAt(tokenId, futureTs);
        // Minimum-contribution gate: if the contribution is a dust value, the
        // assertGe check against `oldVotesBefore - oldVotesAfter` is trivially
        // satisfied by natural decay alone. 1e15 wei (0.001 veHEMI) is orders
        // of magnitude above any realistic decay-within-1h budget, so an
        // assertion at this threshold genuinely distinguishes redelegation
        // from pure decay.
        require(
            tokenContribFuture >= 1e15,
            "tokenContribFuture too small - assertions would be vacuous vs decay"
        );

        // Also capture oldDelegatee's baseline votes at futureTs via getPastVotes
        // so we can separate the redelegation effect from pure time decay.
        uint256 oldVotesBefore = delegation.getVotes(oldDelegatee);
        require(oldVotesBefore > 0, "oldDelegatee has no votes pre-redelegate");

        // DelegateChanged(tokenId, oldDelegatee, newDelegatee) must fire.
        // All three args are indexed; data field is empty so we skip it.
        vm.expectEmit(true, true, true, false, address(delegation));
        emit IVeHemiVoteDelegation.DelegateChanged(tokenId, oldDelegatee, newDelegatee);
        // Record all logs so we can also assert the DATA payload of
        // DelegateVotesChanged events (topic-only pins miss previousVotes ↔
        // newVotes swaps, a real mutation class).
        vm.recordLogs();
        vm.prank(owner);
        delegation.delegate(tokenId, newDelegatee);
        _assertDelegateVotesChangedDirectionality(vm.getRecordedLogs(), oldDelegatee, newDelegatee);

        vm.warp(futureTs);
        vm.roll(block.number + 1);

        uint256 oldVotesAfter = delegation.getVotes(oldDelegatee);
        uint256 newVotesAfter = delegation.getVotes(newDelegatee);

        assertEq(
            delegation.delegation(tokenId).delegatee,
            newDelegatee,
            "delegation.delegatee did not update"
        );

        // The new delegatee's votes at futureTs MUST equal the token's
        // contribution at futureTs (up to 1 wei of rounding slack). A no-op
        // _delegate would leave newDelegatee at zero; a partial-credit bug
        // would leave it short.
        assertApproxEqAbs(
            newVotesAfter,
            tokenContribFuture,
            1,
            "newDelegatee votes != token contribution moved"
        );

        // The old delegatee must have LOST at least `tokenContribFuture`
        // worth of votes on top of whatever natural decay occurred — the
        // drop must exceed the contribution the token would still have
        // added at futureTs if no redelegation had happened.
        assertGe(
            oldVotesBefore - oldVotesAfter,
            tokenContribFuture,
            "oldDelegatee did not lose the redelegated contribution"
        );
    }

    // ─── 7. delegateBySig + EIP-712 domain continuity ────────────────────

    /// @notice A fresh position owned by a key we control must accept a
    ///         valid EIP-712-signed delegateBySig after the upgrade. Pins:
    ///         (a) the EIP-712 domain string still hashes to the same digest
    ///         the contract expects post-upgrade, (b) the nonces mapping at
    ///         slot 3 is readable/writable through the delegateBySig path,
    ///         and (c) a replay of the same signature reverts.
    function testForkDelegateBySigPostUpgrade() public onlyFork {
        (address signer, uint256 signerPk) = makeAddrAndKey("sigSigner");

        // Mint a fresh lock position owned by `signer`. Lock duration is
        // generously long so the position has non-trivial voting power.
        uint256 lockAmount = 100 ether;
        uint256 lockDuration = 365 days;
        deal(HEMI_TOKEN, signer, lockAmount);
        vm.startPrank(signer);
        IERC20(HEMI_TOKEN).approve(VEHEMI_PROXY, lockAmount);
        uint256 tokenId = veHemi.createLock(lockAmount, lockDuration);
        vm.stopPrank();

        uint256 noncePre = delegation.nonces(signer);

        _upgradeDelegationProxy();

        // Nonce must survive the upgrade bit-for-bit.
        assertEq(delegation.nonces(signer), noncePre, "nonce mutated by upgrade");

        address newDelegatee = makeAddr("sigDelegatee");
        uint256 expiry = block.timestamp + 1 hours;
        bytes32 digest = _delegateBySigDigest(tokenId, newDelegatee, noncePre, expiry);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);

        // A third-party relayer (not the signer, not the owner) submits the tx.
        // createLock auto-self-delegates, so fromDelegatee = signer at this point.
        address relayer = makeAddr("relayer");
        vm.expectEmit(true, true, true, false, address(delegation));
        emit IVeHemiVoteDelegation.DelegateChanged(tokenId, signer, newDelegatee);
        vm.prank(relayer);
        delegation.delegateBySig(tokenId, newDelegatee, noncePre, expiry, v, r, s);

        assertEq(
            delegation.delegation(tokenId).delegatee,
            newDelegatee,
            "delegateBySig did not update delegation"
        );
        assertEq(delegation.nonces(signer), noncePre + 1, "nonce did not increment");

        // Replay of the same signature must revert InvalidNonce.
        vm.prank(relayer);
        vm.expectRevert(VeHemiVoteDelegation.InvalidNonce.selector);
        delegation.delegateBySig(tokenId, newDelegatee, noncePre, expiry, v, r, s);
    }

    /// @notice delegateBySig must revert SignatureExpired when the `expiry`
    ///         is already in the past. Pins the expiry-check branch of
    ///         delegateBySig post-upgrade.
    function testForkDelegateBySigExpiredReverts() public onlyFork {
        (address signer, uint256 signerPk) = makeAddrAndKey("sigExpired");
        uint256 lockAmount = 100 ether;
        deal(HEMI_TOKEN, signer, lockAmount);
        vm.startPrank(signer);
        IERC20(HEMI_TOKEN).approve(VEHEMI_PROXY, lockAmount);
        uint256 tokenId = veHemi.createLock(lockAmount, 365 days);
        vm.stopPrank();

        _upgradeDelegationProxy();

        uint256 noncePre = delegation.nonces(signer);
        address newDelegatee = makeAddr("expiredDelegatee");
        // expiry in the past.
        uint256 expiry = block.timestamp - 1;
        bytes32 digest = _delegateBySigDigest(tokenId, newDelegatee, noncePre, expiry);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);

        vm.expectRevert(VeHemiVoteDelegation.SignatureExpired.selector);
        delegation.delegateBySig(tokenId, newDelegatee, noncePre, expiry, v, r, s);
    }

    /// @notice delegateBySig must revert NotOwner when the signature is for
    ///         a tokenId NOT owned by the signer. Pins the ownership check
    ///         after successful ECDSA recovery, post-upgrade.
    function testForkDelegateBySigNotOwnerReverts() public onlyFork {
        (address signer, uint256 signerPk) = makeAddrAndKey("sigNotOwner");
        address otherOwner = makeAddr("otherOwner");

        // Mint two positions owned by DIFFERENT addresses. The signer does
        // NOT own tokenId (otherOwner does).
        uint256 lockAmount = 100 ether;
        deal(HEMI_TOKEN, address(this), lockAmount);
        IERC20(HEMI_TOKEN).approve(VEHEMI_PROXY, lockAmount);
        uint256 tokenId = veHemi.createLockFor(lockAmount, 365 days, otherOwner, true, false);

        _upgradeDelegationProxy();

        uint256 noncePre = delegation.nonces(signer);
        address newDelegatee = makeAddr("notOwnerDelegatee");
        uint256 expiry = block.timestamp + 1 hours;
        bytes32 digest = _delegateBySigDigest(tokenId, newDelegatee, noncePre, expiry);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);

        // Signature recovers to `signer`, but ownerOf(tokenId) = otherOwner.
        vm.expectRevert(VeHemiVoteDelegation.NotOwner.selector);
        delegation.delegateBySig(tokenId, newDelegatee, noncePre, expiry, v, r, s);
    }

    /// @notice delegateBySig must revert on a malformed signature
    ///         (v=r=s=0). OZ v5's ECDSA.recover validates input and reverts
    ///         with ECDSAInvalidSignature before the contract's own fallback
    ///         InvalidSignature check fires — either revert is acceptable;
    ///         the invariant is "delegateBySig with a zeroed sig cannot
    ///         silently produce an invalid delegation."
    function testForkDelegateBySigInvalidSignatureReverts() public onlyFork {
        (uint256 tokenId, ) = _findLiveDelegation();

        _upgradeDelegationProxy();

        address newDelegatee = makeAddr("invSigDelegatee");
        uint256 expiry = block.timestamp + 1 hours;
        // Bare vm.expectRevert accepts either OZ's ECDSAInvalidSignature
        // (the likely path with v=0) or the contract's InvalidSignature
        // fallback (reached only if ECDSA happened to recover to zero).
        vm.expectRevert();
        delegation.delegateBySig(tokenId, newDelegatee, 0, expiry, 0, bytes32(0), bytes32(0));
    }

    // ─── 8. getVotes / getPastVotes round-trip ───────────────────────────

    /// @notice Voting power queries must return identical values pre and
    ///         post upgrade for every historical timestamp sampled. This
    ///         catches logic regressions in the checkpoint walk even when
    ///         raw storage bytes are bit-identical (e.g., a refactor that
    ///         changed the `_getPastVotes` algorithm but left slots intact).
    function testForkGetPastVotesRoundTrip() public onlyFork {
        (, address delegatee) = _findLiveDelegation();

        // Sample 7 historical timestamps plus the current block. The extra
        // timestamps (#5, #6) exercise branches a coarse 1h/6h/1d/7d/30d
        // sample misses:
        //   - block.timestamp - 1: the smallest possible past delta, pins
        //     the near-current read.
        //   - floor hour boundary: non-identical to any stored checkpoint
        //     timestamp (the contract stores CEIL'd boundaries, so
        //     floor(now/1h)*1h is always strictly before any stored entry).
        //     A useful extra between-checkpoints probe even though it does
        //     NOT exercise a distinct equality branch of the binary search.
        uint256 checkpointInterval = 1 hours;
        uint256 boundaryTs = (block.timestamp / checkpointInterval) * checkpointInterval;
        uint256[] memory times = new uint256[](8);
        times[0] = block.timestamp - 1 hours;
        times[1] = block.timestamp - 6 hours;
        times[2] = block.timestamp - 1 days;
        times[3] = block.timestamp - 7 days;
        times[4] = block.timestamp - 30 days;
        times[5] = block.timestamp - 1;
        times[6] = boundaryTs;
        times[7] = block.timestamp; // consumed by getVotes

        uint256[] memory pre = new uint256[](8);
        for (uint256 i; i < 7; ++i) pre[i] = delegation.getPastVotes(delegatee, times[i]);
        pre[7] = delegation.getVotes(delegatee);
        require(pre[7] > 0, "delegatee has zero votes - test would be vacuous");

        // Variance guard: at least two historical samples must differ, proving
        // the checkpoint walk actually traversed state rather than returning a
        // constant value across every timestamp (which would pass bit-for-bit
        // even if the walk were replaced by a stub). If the sampled delegatee
        // happens to have flat history at this particular fork block (e.g.,
        // delegated exactly once recently and never changed), skip rather
        // than hard-revert — a valid mainnet state shouldn't red the suite.
        bool sawDifference;
        for (uint256 i = 1; i < 7 && !sawDifference; ++i) {
            if (pre[i] != pre[0]) sawDifference = true;
        }
        if (!sawDifference) {
            vm.skip(true);
            return;
        }

        _upgradeDelegationProxy();

        for (uint256 i; i < 7; ++i) {
            assertEq(
                delegation.getPastVotes(delegatee, times[i]),
                pre[i],
                string.concat("getPastVotes drift at t[", vm.toString(i), "]")
            );
        }
        assertEq(delegation.getVotes(delegatee), pre[7], "getVotes drifted post-upgrade");
    }

    // ─── 9. Checkpoint history preservation ──────────────────────────────

    /// @notice For every unique live delegatee in the LOCKED range, the full
    ///         DelegateCheckpoint[] array (length + every struct field) must
    ///         round-trip across the upgrade. slot 1 (delegateCheckpoints) is
    ///         a mapping-to-dynamic-array and its data lives at keccak-derived
    ///         addresses outside the raw 0-49 scan — this is the only test
    ///         here that actually reads those keccak-derived words back.
    function testForkDelegationCheckpointHistoryPreservation() public onlyFork {
        uint256[] memory tokenIds = _collectLiveTokenIds();
        address[] memory delegatees = _uniqueDelegatees(tokenIds);
        require(delegatees.length > 0, "no live delegatees found in LOCKED range");

        IVeHemiVoteDelegation.DelegateCheckpoint[][] memory pre =
            new IVeHemiVoteDelegation.DelegateCheckpoint[][](delegatees.length);
        uint256 totalCheckpointsPre;
        for (uint256 i; i < delegatees.length; ++i) {
            pre[i] = delegation.getDelegationCheckpoints(delegatees[i]);
            totalCheckpointsPre += pre[i].length;
        }
        require(totalCheckpointsPre > 0, "no checkpoints found - test vacuous");

        _upgradeDelegationProxy();

        for (uint256 i; i < delegatees.length; ++i) {
            IVeHemiVoteDelegation.DelegateCheckpoint[] memory post =
                delegation.getDelegationCheckpoints(delegatees[i]);
            assertEq(
                post.length,
                pre[i].length,
                string.concat("checkpoint array length changed for delegatee index ", vm.toString(i))
            );
            for (uint256 j; j < post.length; ++j) {
                assertEq(post[j].normalizedBias, pre[i][j].normalizedBias, "normalizedBias drift");
                assertEq(post[j].fixedBias, pre[i][j].fixedBias, "fixedBias drift");
                assertEq(post[j].totalAmount, pre[i][j].totalAmount, "totalAmount drift");
                assertEq(post[j].normalizedSlope, pre[i][j].normalizedSlope, "normalizedSlope drift");
                assertEq(post[j].timestamp, pre[i][j].timestamp, "timestamp drift");
            }
        }
    }

    // ─── 10. End-to-end setTrustedAdapter + delegateAllFor ───────────────

    /// @notice Post-upgrade: the VeHemi owner (Gnosis Safe) sets a trusted
    ///         adapter; the adapter calls delegateAllFor(newOwner, delegatee);
    ///         every non-expired NFT owned by `newOwner` is re-delegated to
    ///         `delegatee`, and autoDelegate[newOwner] is set. Exercises the
    ///         new V2 adapter-bridge flow end-to-end.
    ///
    /// @dev Uses two FRESH test positions (rather than a live mainnet owner)
    ///      so the test is hermetic — a mainnet owner's portfolio may include
    ///      legacy positions that hit `_delegate` edge cases unrelated to the
    ///      upgrade. The contract flow (setter, authentication, iteration,
    ///      autoDelegate write) is identical either way; using fresh positions
    ///      just removes state-dependent noise.
    function testForkSetTrustedAdapterAndDelegateAllFor() public onlyFork {
        address newOwner = makeAddr("bulkOwner");
        address newDelegatee = makeAddr("bulkDelegatee");

        // Mint two fresh positions owned by newOwner.
        uint256 amount = 50 ether;
        deal(HEMI_TOKEN, address(this), amount * 2);
        IERC20(HEMI_TOKEN).approve(VEHEMI_PROXY, amount * 2);
        uint256 tokenId1 = veHemi.createLockFor(amount, 365 days, newOwner, true, false);
        uint256 tokenId2 = veHemi.createLockFor(amount, 365 days, newOwner, true, false);

        _upgradeDelegationProxy();

        // The adapter MUST be a contract — _delegate's notifyVotesChanged and
        // notifyDelegateChanged call via a high-level interface, and Solidity's
        // extcodesize pre-check reverts if the target has no code. Using an EOA
        // would fail even though the contract's own try/catch wraps the callee.
        MockAdapter adapterContract = new MockAdapter();
        address adapter = address(adapterContract);

        // TrustedAdapterUpdated event payload pin: old adapter (0) → new.
        vm.expectEmit(true, true, false, true, address(delegation));
        emit IVeHemiVoteDelegation.TrustedAdapterUpdated(address(0), adapter);
        vm.prank(GNOSIS_SAFE);
        delegation.setTrustedAdapter(adapter);
        assertEq(delegation.trustedAdapter(), adapter, "adapter setter did not persist");

        vm.prank(adapter);
        delegation.delegateAllFor(newOwner, newDelegatee);

        assertEq(
            delegation.autoDelegate(newOwner),
            newDelegatee,
            "autoDelegate[owner] not set by delegateAllFor"
        );
        assertEq(
            delegation.delegation(tokenId1).delegatee,
            newDelegatee,
            "tokenId1 not redelegated by delegateAllFor"
        );
        assertEq(
            delegation.delegation(tokenId2).delegatee,
            newDelegatee,
            "tokenId2 not redelegated by delegateAllFor"
        );

        // Unauthorized caller (non-adapter) must revert.
        address notAdapter = makeAddr("notAdapter");
        vm.prank(notAdapter);
        vm.expectRevert(VeHemiVoteDelegation.NotTrustedAdapter.selector);
        delegation.delegateAllFor(newOwner, newDelegatee);

        // delegateAllFor to address(0) must revert InvalidDelegatee.
        vm.prank(adapter);
        vm.expectRevert(VeHemiVoteDelegation.InvalidDelegatee.selector);
        delegation.delegateAllFor(newOwner, address(0));

        // Non-VeHemi-owner call to setTrustedAdapter must revert NotVeHemiOwner.
        vm.prank(makeAddr("randomUser"));
        vm.expectRevert(VeHemiVoteDelegation.NotVeHemiOwner.selector);
        delegation.setTrustedAdapter(address(adapterContract));
    }

    /// @notice The delegation contract wraps the adapter's notify callbacks
    ///         in try/catch (`IAdapterNotify.notifyVotesChanged`,
    ///         `notifyDelegateChanged`). Verifies that a MALICIOUS or buggy
    ///         adapter that reverts from those callbacks does NOT break the
    ///         delegate flow — exercises the defensive try/catch `catch`
    ///         branch that the happy-path MockAdapter never triggers.
    function testForkDelegateAllForToleratesAdapterReverts() public onlyFork {
        address revertingOwner = makeAddr("revertingOwner");
        address revertingDelegatee = makeAddr("revertingDelegatee");

        uint256 amount = 50 ether;
        deal(HEMI_TOKEN, address(this), amount);
        IERC20(HEMI_TOKEN).approve(VEHEMI_PROXY, amount);
        uint256 tokenId = veHemi.createLockFor(amount, 365 days, revertingOwner, true, false);

        _upgradeDelegationProxy();

        RevertingAdapter revertingAdapter = new RevertingAdapter();

        vm.prank(GNOSIS_SAFE);
        delegation.setTrustedAdapter(address(revertingAdapter));

        // Must succeed despite the adapter reverting on notify callbacks.
        vm.prank(address(revertingAdapter));
        delegation.delegateAllFor(revertingOwner, revertingDelegatee);

        assertEq(
            delegation.delegation(tokenId).delegatee,
            revertingDelegatee,
            "delegation failed to apply despite adapter revert"
        );
        assertEq(
            delegation.autoDelegate(revertingOwner),
            revertingDelegatee,
            "autoDelegate not set despite adapter revert"
        );
    }

    // ─── 11. Full-state hash aggregate ───────────────────────────────────

    /// @notice Compresses the full state-preservation check into a single
    ///         keccak-chained digest per side. Covers: every live delegation
    ///         (5 fields), every unique delegatee's full checkpoint array,
    ///         and the nonces for every token-owner that has delegated.
    ///         Uses the DelegationSnapshot helper contract so all reads
    ///         happen inside a single external call per side — cheap in RPC
    ///         budget and immune to a subset of tests being skipped.
    function testForkDelegationHashSnapshotPreservation() public onlyFork {
        DelegationSnapshot snap = new DelegationSnapshot();

        uint256[] memory tokenIds = _collectLiveTokenIds();
        address[] memory delegatees = _uniqueDelegatees(tokenIds);

        // Collect unique NFT owners so nonces[owner] is also folded in.
        address[] memory owners = new address[](tokenIds.length);
        uint256 nOwners;
        for (uint256 i; i < tokenIds.length; ++i) {
            address o = veHemi.ownerOf(tokenIds[i]);
            bool seen;
            for (uint256 j; j < nOwners; ++j) {
                if (owners[j] == o) { seen = true; break; }
            }
            if (!seen) owners[nOwners++] = o;
        }
        address[] memory uniqOwners = new address[](nOwners);
        for (uint256 i; i < nOwners; ++i) uniqOwners[i] = owners[i];

        bytes32 preHash = snap.snapshot(delegation, tokenIds, delegatees, uniqOwners);
        require(preHash != bytes32(0), "pre-upgrade hash is zero - snapshot produced empty input");

        _upgradeDelegationProxy();

        bytes32 postHash = snap.snapshot(delegation, tokenIds, delegatees, uniqOwners);
        assertEq(postHash, preHash, "delegation state hash changed across upgrade");
    }
}

/// @title MockAdapter
/// @notice Minimal IAdapterNotify-compatible adapter so the delegation
///         contract's try/catch-wrapped notify calls don't trigger
///         Solidity's high-level extcodesize-is-zero revert. Silent — we
///         don't assert on the notifications here; the point is only to
///         exercise the adapter bridge without spurious reverts.
contract MockAdapter {
    function notifyVotesChanged(address, uint256, uint256) external {}
    function notifyDelegateChanged(address, address, address) external {}
}

/// @title RevertingAdapter
/// @notice Adapter that always reverts from its notify callbacks. Used to
///         exercise the try/catch defensive wrapping in VeHemiVoteDelegation's
///         `_delegate` / `_writeNewCheckpoint` paths — a malicious adapter
///         must not be able to brick delegation by reverting from notify.
contract RevertingAdapter {
    function notifyVotesChanged(address, uint256, uint256) external pure {
        revert("reverting adapter");
    }
    function notifyDelegateChanged(address, address, address) external pure {
        revert("reverting adapter");
    }
}

/// @title DelegationSnapshot
/// @notice Folds every mapping-derived state field of VeHemiVoteDelegation
///         that is relevant to the V1/V2 upgrade safety into a single
///         bytes32 keccak chain. Reads happen entirely inside this contract
///         so the caller pays one external CALL (plus the interface view
///         calls it makes), not one per token/delegatee/owner.
contract DelegationSnapshot {
    function snapshot(
        VeHemiVoteDelegation delegation,
        uint256[] calldata tokenIds,
        address[] calldata delegatees,
        address[] calldata owners
    ) external view returns (bytes32 h) {
        // Fold every live Delegation struct: all 5 fields per tokenId.
        for (uint256 i; i < tokenIds.length; ++i) {
            IVeHemiVoteDelegation.Delegation memory d = delegation.delegation(tokenIds[i]);
            h = keccak256(
                abi.encodePacked(h, tokenIds[i], d.delegatee, d.end, d.bias, d.amount, d.slope)
            );
        }
        // Fold every unique delegatee's full checkpoint history.
        for (uint256 i; i < delegatees.length; ++i) {
            IVeHemiVoteDelegation.DelegateCheckpoint[] memory cps =
                delegation.getDelegationCheckpoints(delegatees[i]);
            h = keccak256(abi.encodePacked(h, delegatees[i], cps.length));
            for (uint256 j; j < cps.length; ++j) {
                h = keccak256(
                    abi.encodePacked(
                        h,
                        cps[j].normalizedBias,
                        cps[j].fixedBias,
                        cps[j].totalAmount,
                        cps[j].normalizedSlope,
                        cps[j].timestamp
                    )
                );
            }
        }
        // Fold nonces for every unique owner.
        for (uint256 i; i < owners.length; ++i) {
            h = keccak256(abi.encodePacked(h, owners[i], delegation.nonces(owners[i])));
        }
    }
}
