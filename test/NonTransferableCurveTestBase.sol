// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "forge-std/Test.sol";
import "../src/VeHemi.sol";
import "../src/VeHemiVoteDelegation.sol";
import "../src/interfaces/IVeHemi.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "./mocks/MockERC20.sol";

/// @title NonTransferableCurveTestBase
/// @notice Base test for VeHemi V2 non-transferable curve (non-transferable position tracking).
///         Deploys VeHemi + VeHemiVoteDelegation WITHOUT restaking infrastructure.
contract NonTransferableCurveTestBase is Test {
    MockERC20 hemi;
    VeHemi veHemi;
    VeHemiVoteDelegation delegation;

    address admin = address(this);
    address alice = address(0x1122);
    address bob = address(0x3344);
    address charlie = address(0x5566);

    uint256 internal constant YEAR = 365.25 days;
    uint256 internal constant MONTH = YEAR / 12;
    uint256 internal constant SIX_DAYS = MONTH / 5;
    uint256 internal constant MAX_TIME = 4 * YEAR;

    uint256 constant MAX_AMOUNT = 1_000 ether;
    uint256 constant DEFAULT_LOCK_AMOUNT = 100 ether;
    uint256 constant DEFAULT_LOCK_DURATION = 2 * 365 days;

    function setUp() public virtual {
        hemi = new MockERC20("HEMI", "HEMI", 18);
        hemi.mint(alice, MAX_AMOUNT);
        hemi.mint(bob, MAX_AMOUNT);
        hemi.mint(charlie, MAX_AMOUNT);

        VeHemi logic = new VeHemi(address(hemi));
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(logic),
            abi.encodeWithSelector(VeHemi.initialize.selector, admin)
        );
        veHemi = VeHemi(address(proxy));

        delegation = new VeHemiVoteDelegation(address(veHemi));
        veHemi.updateVoteDelegation(delegation);

        vm.prank(alice);
        hemi.approve(address(veHemi), type(uint256).max);
        vm.prank(bob);
        hemi.approve(address(veHemi), type(uint256).max);
        vm.prank(charlie);
        hemi.approve(address(veHemi), type(uint256).max);
    }

    /// @dev Helper to create a transferable lock (matches RestakingTest helper signature)
    function createLock(
        address account_,
        uint256 amount_,
        uint256 duration_
    ) public returns (uint256 _tokenId, uint256 _slope, uint256 _end) {
        vm.startPrank(account_);
        hemi.mint(account_, amount_);
        hemi.approve(address(veHemi), type(uint256).max);
        _tokenId = veHemi.createLock(amount_, duration_);
        vm.stopPrank();
        _slope = amount_ / MAX_TIME;
        _end = veHemi.getLockedBalance(_tokenId).end;
    }
}
