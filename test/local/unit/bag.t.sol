// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {ERC721} from "lib/openzeppelin-contracts/contracts/token/ERC721/ERC721.sol";
import {Initializable} from "lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import {IBag} from "src/interface/IBag.sol";
import {Bag} from "src/Bag.sol";

contract BagERC20Mock is ERC20 {
    constructor() ERC20("Token", "TKN") {}

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }
}

contract BagERC20SecondMock is ERC20 {
    constructor() ERC20("Second Token", "TKN2") {}

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }
}

contract BagERC721Mock is ERC721 {
    constructor() ERC721("Collectible", "NFT") {}

    function mint(address account, uint256 tokenId) external {
        _mint(account, tokenId);
    }
}

contract NativeRejector {
    receive() external payable {
        revert("reject native");
    }
}

contract OwnerRegistryMock {
    mapping(uint256 id => address owner) internal owners;
    mapping(uint256 id => mapping(address spender => bool authorized)) internal authorizations;

    function setOwner(uint256 id, address owner) external {
        owners[id] = owner;
    }

    function setAuthorized(uint256 id, address spender, bool authorized) external {
        authorizations[id][spender] = authorized;
    }

    function ownerOf(uint256 id) external view returns (address) {
        return owners[id];
    }

    function isAuthorized(address spender, uint256 id) external view returns (bool) {
        return spender == owners[id] || authorizations[id][spender];
    }
}

contract BagTest is Test {
    address internal constant ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    Bag implementation;
    Bag bag;
    BagERC20Mock token;
    BagERC20SecondMock secondToken;
    BagERC721Mock nft;
    OwnerRegistryMock ownerRegistry;

    address owner = address(0xB0B);
    address other = address(0xCAFE);
    address recipient = address(0xA11CE);
    uint256 requestId = 42;

    function setUp() public {
        implementation = new Bag();
        ownerRegistry = new OwnerRegistryMock();
        bag = _deployBag(owner, requestId);
        token = new BagERC20Mock();
        secondToken = new BagERC20SecondMock();
        nft = new BagERC721Mock();
    }

    function _deployBag(address owner_, uint256 id_) internal returns (Bag) {
        ownerRegistry.setOwner(id_, owner_);
        return Bag(
            payable(address(
                    new ERC1967Proxy(
                        address(implementation), abi.encodeCall(Bag.initialize, (address(ownerRegistry), id_))
                    )
                ))
        );
    }

    function _claimSingleERC20(Bag bag_, address asset, address recipient_, uint256 amount)
        internal
        returns (uint256[] memory)
    {
        address[] memory assets = new address[](1);
        assets[0] = asset;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;

        return bag_.claim(assets, payable(recipient_), amounts);
    }

    function _claimSingleNative(Bag bag_, address payable recipient_, uint256 amount)
        internal
        returns (uint256[] memory)
    {
        address[] memory assets = new address[](1);
        assets[0] = ETH;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;

        return bag_.claim(assets, recipient_, amounts);
    }

    function testInitializeSetsExpectedOwnerRegistryAndConstants() public view {
        assertEq(bag.VERSION(), "0.1.0");
        assertEq(bag.ETH(), 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);
        assertEq(bag.id(), requestId);
        assertEq(bag.ownerRegistry(), address(ownerRegistry));
    }

    function testInitializeSupportsZeroRequestId() public {
        Bag zeroIdBag = _deployBag(owner, 0);

        assertEq(zeroIdBag.id(), 0);
        assertEq(zeroIdBag.ownerRegistry(), address(ownerRegistry));
    }

    function testFuzzInitializeSetsExpectedOwnerRegistryAndId(address owner_, uint256 id_) public {
        vm.assume(owner_ != address(0));

        Bag fuzzBag = _deployBag(owner_, id_);

        assertEq(fuzzBag.id(), id_);
        assertEq(fuzzBag.ownerRegistry(), address(ownerRegistry));
        assertEq(ownerRegistry.ownerOf(id_), owner_);
    }

    function testInitializeRevertsForZeroOwnerRegistry() public {
        vm.expectRevert(IBag.ZeroAddress.selector);
        new ERC1967Proxy(address(implementation), abi.encodeCall(Bag.initialize, (address(0), requestId)));
    }

    function testImplementationCannotBeInitialized() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(address(ownerRegistry), requestId);
    }

    function testProxyCannotBeInitializedTwice() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        bag.initialize(address(ownerRegistry), requestId + 1);
    }

    function testClaimTransfersERC20sAndNativeETH() public {
        token.mint(address(bag), 12 ether);
        secondToken.mint(address(bag), 8 ether);
        vm.deal(address(bag), 3 ether);
        uint256 recipientBalanceBefore = recipient.balance;

        address[] memory assets = new address[](3);
        assets[0] = address(token);
        assets[1] = bag.ETH();
        assets[2] = address(secondToken);
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 5 ether;
        amounts[1] = 1 ether;
        amounts[2] = 2 ether;

        vm.expectEmit(true, true, true, true, address(bag));
        emit IBag.ERC20Claimed(owner, recipient, address(token), 5 ether);
        vm.expectEmit(true, true, true, true, address(bag));
        emit IBag.NativeClaimed(owner, recipient, 1 ether);
        vm.expectEmit(true, true, true, true, address(bag));
        emit IBag.ERC20Claimed(owner, recipient, address(secondToken), 2 ether);

        vm.prank(owner);
        uint256[] memory amountsClaimed = bag.claim(assets, payable(recipient), amounts);

        assertEq(amountsClaimed.length, 3);
        assertEq(amountsClaimed[0], 5 ether);
        assertEq(amountsClaimed[1], 1 ether);
        assertEq(amountsClaimed[2], 2 ether);
        assertEq(token.balanceOf(recipient), 5 ether);
        assertEq(secondToken.balanceOf(recipient), 2 ether);
        assertEq(recipient.balance - recipientBalanceBefore, 1 ether);
        assertEq(token.balanceOf(address(bag)), 7 ether);
        assertEq(secondToken.balanceOf(address(bag)), 6 ether);
        assertEq(address(bag).balance, 2 ether);
    }

    function testClaimAllowsEmptyClaim() public {
        address[] memory assets = new address[](0);
        uint256[] memory amounts = new uint256[](0);

        vm.prank(owner);
        uint256[] memory amountsClaimed = bag.claim(assets, payable(recipient), amounts);

        assertEq(amountsClaimed.length, 0);
    }

    function testClaimRevertsWhenCallerIsNotRequestOwner() public {
        address[] memory assets = new address[](1);
        assets[0] = address(token);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1 ether;

        vm.expectRevert(abi.encodeWithSelector(IBag.NotRequestOwner.selector, other));
        vm.prank(other);
        bag.claim(assets, payable(recipient), amounts);
    }

    function testClaimAllowsAuthorizedOperator() public {
        token.mint(address(bag), 12 ether);
        ownerRegistry.setAuthorized(requestId, other, true);

        vm.prank(other);
        uint256 amount = _claimSingleERC20(bag, address(token), recipient, 5 ether)[0];

        assertEq(amount, 5 ether);
        assertEq(token.balanceOf(recipient), 5 ether);
        assertEq(token.balanceOf(address(bag)), 7 ether);
    }

    function testClaimRevertsForInvalidInputs() public {
        address[] memory assets = new address[](1);
        assets[0] = address(token);
        uint256[] memory amounts = new uint256[](2);

        vm.startPrank(owner);

        vm.expectRevert(IBag.InvalidArrayLength.selector);
        bag.claim(assets, payable(recipient), amounts);

        amounts = new uint256[](1);
        vm.expectRevert(IBag.ZeroAddress.selector);
        bag.claim(assets, payable(address(0)), amounts);

        assets[0] = address(0);
        vm.expectRevert(IBag.ZeroAddress.selector);
        bag.claim(assets, payable(recipient), amounts);

        vm.stopPrank();
    }

    function testClaimRevertsWhenNativeRecipientRejectsTransfer() public {
        NativeRejector rejector = new NativeRejector();
        vm.deal(address(bag), 3 ether);
        address[] memory assets = new address[](1);
        assets[0] = bag.ETH();
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1 ether;

        vm.expectRevert(bytes("reject native"));
        vm.prank(owner);
        bag.claim(assets, payable(address(rejector)), amounts);
    }

    function testClaimSingleERC20TransfersSpecifiedAmountAndEmits() public {
        token.mint(address(bag), 12 ether);

        vm.expectEmit(true, true, true, true, address(bag));
        emit IBag.ERC20Claimed(owner, recipient, address(token), 5 ether);

        vm.prank(owner);
        uint256 amount = _claimSingleERC20(bag, address(token), recipient, 5 ether)[0];

        assertEq(amount, 5 ether);
        assertEq(token.balanceOf(recipient), 5 ether);
        assertEq(token.balanceOf(address(bag)), 7 ether);
    }

    function testFuzzClaimSingleERC20TransfersSpecifiedAmount(address recipient_, uint128 balance, uint128 amount)
        public
    {
        vm.assume(recipient_ != address(0));
        vm.assume(recipient_ != address(bag));
        amount = uint128(bound(amount, 0, balance));
        token.mint(address(bag), balance);

        vm.prank(owner);
        uint256 amountClaimed = _claimSingleERC20(bag, address(token), recipient_, amount)[0];

        assertEq(amountClaimed, amount);
        assertEq(token.balanceOf(recipient_), amount);
        assertEq(token.balanceOf(address(bag)), uint256(balance) - amount);
    }

    function testClaimSingleERC20AllowsZeroAmountClaim() public {
        token.mint(address(bag), 12 ether);

        vm.expectEmit(true, true, true, true, address(bag));
        emit IBag.ERC20Claimed(owner, recipient, address(token), 0);

        vm.prank(owner);
        uint256 amount = _claimSingleERC20(bag, address(token), recipient, 0)[0];

        assertEq(amount, 0);
        assertEq(token.balanceOf(recipient), 0);
        assertEq(token.balanceOf(address(bag)), 12 ether);
    }

    function testClaimSingleERC20RevertsWhenAmountExceedsBalance() public {
        token.mint(address(bag), 12 ether);

        vm.expectRevert();
        vm.prank(owner);
        _claimSingleERC20(bag, address(token), recipient, 12 ether + 1);
    }

    function testFuzzClaimSingleERC20RevertsWhenAmountExceedsBalance(uint128 balance, uint128 excess) public {
        excess = uint128(bound(excess, 1, type(uint128).max));
        token.mint(address(bag), balance);

        vm.expectRevert();
        vm.prank(owner);
        _claimSingleERC20(bag, address(token), recipient, uint256(balance) + excess);
    }

    function testClaimSingleERC20RevertsWhenCallerIsNotRequestOwner() public {
        token.mint(address(bag), 12 ether);

        vm.expectRevert(abi.encodeWithSelector(IBag.NotRequestOwner.selector, other));
        vm.prank(other);
        _claimSingleERC20(bag, address(token), recipient, 1 ether);
    }

    function testClaimSingleERC20RevertsForZeroAssetOrRecipient() public {
        vm.startPrank(owner);

        vm.expectRevert(IBag.ZeroAddress.selector);
        _claimSingleERC20(bag, address(0), recipient, 1 ether);

        vm.expectRevert(IBag.ZeroAddress.selector);
        _claimSingleERC20(bag, address(token), address(0), 1 ether);

        vm.stopPrank();
    }

    function testClaimSingleERC20FollowsCurrentRequestOwnerAfterTransfer() public {
        token.mint(address(bag), 12 ether);

        ownerRegistry.setOwner(requestId, other);

        vm.expectRevert(abi.encodeWithSelector(IBag.NotRequestOwner.selector, owner));
        vm.prank(owner);
        _claimSingleERC20(bag, address(token), recipient, 1 ether);

        vm.prank(other);
        uint256 amount = _claimSingleERC20(bag, address(token), recipient, 12 ether)[0];

        assertEq(amount, 12 ether);
        assertEq(token.balanceOf(recipient), 12 ether);
    }

    function testFuzzClaimSingleERC20FollowsCurrentRequestOwnerAfterTransfer(uint128 balance, uint128 amount) public {
        amount = uint128(bound(amount, 0, balance));
        token.mint(address(bag), balance);

        ownerRegistry.setOwner(requestId, other);

        vm.expectRevert(abi.encodeWithSelector(IBag.NotRequestOwner.selector, owner));
        vm.prank(owner);
        _claimSingleERC20(bag, address(token), recipient, amount);

        vm.prank(other);
        uint256 amountClaimed = _claimSingleERC20(bag, address(token), recipient, amount)[0];

        assertEq(amountClaimed, amount);
        assertEq(token.balanceOf(recipient), amount);
        assertEq(token.balanceOf(address(bag)), uint256(balance) - amount);
    }

    function testClaimERC721TransfersTokenAndEmits() public {
        nft.mint(address(bag), 7);

        vm.expectEmit(true, true, true, true, address(bag));
        emit IBag.ERC721Claimed(owner, recipient, address(nft), 7);

        vm.prank(owner);
        bag.claimERC721(address(nft), recipient, 7);

        assertEq(nft.ownerOf(7), recipient);
    }

    function testFuzzClaimERC721TransfersToken(address recipient_, uint256 tokenId) public {
        vm.assume(recipient_ != address(0));
        vm.assume(recipient_.code.length == 0);
        nft.mint(address(bag), tokenId);

        vm.prank(owner);
        bag.claimERC721(address(nft), recipient_, tokenId);

        assertEq(nft.ownerOf(tokenId), recipient_);
    }

    function testClaimERC721RevertsWhenCallerIsNotRequestOwner() public {
        nft.mint(address(bag), 7);

        vm.expectRevert(abi.encodeWithSelector(IBag.NotRequestOwner.selector, other));
        vm.prank(other);
        bag.claimERC721(address(nft), recipient, 7);
    }

    function testClaimERC721RevertsForZeroAssetOrRecipient() public {
        vm.startPrank(owner);

        vm.expectRevert(IBag.ZeroAddress.selector);
        bag.claimERC721(address(0), recipient, 7);

        vm.expectRevert(IBag.ZeroAddress.selector);
        bag.claimERC721(address(nft), address(0), 7);

        vm.stopPrank();
    }

    function testClaimSingleNativeTransfersSpecifiedAmountAndEmits() public {
        vm.deal(address(bag), 3 ether);
        uint256 recipientBalanceBefore = recipient.balance;

        vm.expectEmit(true, true, true, true, address(bag));
        emit IBag.NativeClaimed(owner, recipient, 1 ether);

        vm.prank(owner);
        uint256 amount = _claimSingleNative(bag, payable(recipient), 1 ether)[0];

        assertEq(amount, 1 ether);
        assertEq(recipient.balance - recipientBalanceBefore, 1 ether);
        assertEq(address(bag).balance, 2 ether);
    }

    function testFuzzClaimSingleNativeTransfersSpecifiedAmount(
        address payable recipient_,
        uint128 balance,
        uint128 amount
    ) public {
        vm.assume(recipient_ != address(0));
        vm.assume(uint160(address(recipient_)) > 10);
        vm.assume(recipient_ != payable(0x000000000000000000636F6e736F6c652e6c6f67));
        vm.assume(recipient_ != payable(address(bag)));
        vm.assume(recipient_.code.length == 0);
        amount = uint128(bound(amount, 0, balance));
        vm.deal(address(bag), balance);
        uint256 recipientBalanceBefore = recipient_.balance;

        vm.prank(owner);
        uint256 amountClaimed = _claimSingleNative(bag, recipient_, amount)[0];

        assertEq(amountClaimed, amount);
        assertEq(recipient_.balance - recipientBalanceBefore, amount);
        assertEq(address(bag).balance, uint256(balance) - amount);
    }

    function testClaimSingleNativeAllowsZeroAmountClaim() public {
        vm.deal(address(bag), 3 ether);

        vm.expectEmit(true, true, true, true, address(bag));
        emit IBag.NativeClaimed(owner, recipient, 0);

        vm.prank(owner);
        uint256 amount = _claimSingleNative(bag, payable(recipient), 0)[0];

        assertEq(amount, 0);
        assertEq(address(bag).balance, 3 ether);
    }

    function testClaimSingleNativeRevertsWhenAmountExceedsBalance() public {
        vm.deal(address(bag), 3 ether);

        vm.expectRevert();
        vm.prank(owner);
        _claimSingleNative(bag, payable(recipient), 3 ether + 1);
    }

    function testFuzzClaimSingleNativeRevertsWhenAmountExceedsBalance(uint128 balance, uint128 excess) public {
        excess = uint128(bound(excess, 1, type(uint128).max));
        vm.deal(address(bag), balance);

        vm.expectRevert();
        vm.prank(owner);
        _claimSingleNative(bag, payable(recipient), uint256(balance) + excess);
    }

    function testClaimSingleNativeRevertsWhenCallerIsNotRequestOwner() public {
        vm.deal(address(bag), 3 ether);

        vm.expectRevert(abi.encodeWithSelector(IBag.NotRequestOwner.selector, other));
        vm.prank(other);
        _claimSingleNative(bag, payable(recipient), 1 ether);
    }

    function testClaimSingleNativeRevertsForZeroRecipient() public {
        vm.expectRevert(IBag.ZeroAddress.selector);
        vm.prank(owner);
        _claimSingleNative(bag, payable(address(0)), 1 ether);
    }

    function testClaimSingleNativeRevertsWhenRecipientRejectsNativeTransfer() public {
        NativeRejector rejector = new NativeRejector();
        vm.deal(address(bag), 3 ether);

        vm.expectRevert(bytes("reject native"));
        vm.prank(owner);
        _claimSingleNative(bag, payable(address(rejector)), 1 ether);
    }

    function testReceiveAcceptsNativeETH() public {
        vm.deal(other, 1 ether);

        vm.prank(other);
        (bool success,) = address(bag).call{value: 1 ether}("");

        assertTrue(success);
        assertEq(address(bag).balance, 1 ether);
    }
}
