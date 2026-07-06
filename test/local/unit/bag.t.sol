// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {ERC721} from "lib/openzeppelin-contracts/contracts/token/ERC721/ERC721.sol";
import {IERC721Receiver} from "lib/openzeppelin-contracts/contracts/token/ERC721/IERC721Receiver.sol";
import {Initializable} from "lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import {IBag} from "src/interface/IBag.sol";
import {Bag} from "src/withdrawal/Bag.sol";

contract BagERC20Mock is ERC20 {
    constructor() ERC20("Token", "TKN") {}

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

contract BagTest is Test {
    Bag implementation;
    Bag bag;
    BagERC20Mock token;
    BagERC721Mock nft;

    address owner = address(0xB0B);
    address other = address(0xCAFE);
    address recipient = address(0xA11CE);
    uint256 requestId = 42;

    function setUp() public {
        implementation = new Bag();
        bag = _deployBag(owner, requestId);
        token = new BagERC20Mock();
        nft = new BagERC721Mock();
    }

    function _deployBag(address owner_, uint256 id_) internal returns (Bag) {
        return
            Bag(
                payable(address(
                        new ERC1967Proxy(address(implementation), abi.encodeCall(Bag.initialize, (owner_, id_)))
                    ))
            );
    }

    function testInitializeMintsExpectedNFTMetadataAndConstants() public {
        assertEq(bag.VERSION(), "0.1.0");
        assertEq(bag.TOKEN_ID(), 1);
        assertEq(bag.id(), requestId);
        assertEq(bag.name(), "YieldNest Withdrawal Bag #42");
        assertEq(bag.symbol(), "ynBAG-42");
        assertEq(bag.ownerOf(bag.TOKEN_ID()), owner);
        assertEq(bag.balanceOf(owner), 1);
    }

    function testInitializeSupportsZeroRequestIdMetadata() public {
        Bag zeroIdBag = _deployBag(owner, 0);

        assertEq(zeroIdBag.name(), "YieldNest Withdrawal Bag #0");
        assertEq(zeroIdBag.symbol(), "ynBAG-0");
        assertEq(zeroIdBag.id(), 0);
        assertEq(zeroIdBag.ownerOf(zeroIdBag.TOKEN_ID()), owner);
    }

    function testFuzzInitializeMintsExpectedNFTMetadataAndId(address owner_, uint256 id_) public {
        vm.assume(owner_ != address(0));

        Bag fuzzBag = _deployBag(owner_, id_);
        string memory idString = vm.toString(id_);

        assertEq(fuzzBag.id(), id_);
        assertEq(fuzzBag.name(), string.concat("YieldNest Withdrawal Bag #", idString));
        assertEq(fuzzBag.symbol(), string.concat("ynBAG-", idString));
        assertEq(fuzzBag.ownerOf(fuzzBag.TOKEN_ID()), owner_);
        assertEq(fuzzBag.balanceOf(owner_), 1);
    }

    function testInitializeRevertsForZeroOwner() public {
        vm.expectRevert(IBag.ZeroAddress.selector);
        new ERC1967Proxy(address(implementation), abi.encodeCall(Bag.initialize, (address(0), requestId)));
    }

    function testImplementationCannotBeInitialized() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(owner, requestId);
    }

    function testProxyCannotBeInitializedTwice() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        bag.initialize(owner, requestId + 1);
    }

    function testClaimERC20TransfersSpecifiedAmountAndEmits() public {
        token.mint(address(bag), 12 ether);

        vm.expectEmit(true, true, true, true, address(bag));
        emit IBag.ERC20Claimed(owner, recipient, address(token), 5 ether);

        vm.prank(owner);
        uint256 amount = bag.claimERC20(address(token), recipient, 5 ether);

        assertEq(amount, 5 ether);
        assertEq(token.balanceOf(recipient), 5 ether);
        assertEq(token.balanceOf(address(bag)), 7 ether);
    }

    function testFuzzClaimERC20TransfersSpecifiedAmount(address recipient_, uint128 balance, uint128 amount) public {
        vm.assume(recipient_ != address(0));
        vm.assume(recipient_ != address(bag));
        amount = uint128(bound(amount, 0, balance));
        token.mint(address(bag), balance);

        vm.prank(owner);
        uint256 amountClaimed = bag.claimERC20(address(token), recipient_, amount);

        assertEq(amountClaimed, amount);
        assertEq(token.balanceOf(recipient_), amount);
        assertEq(token.balanceOf(address(bag)), uint256(balance) - amount);
    }

    function testClaimERC20AllowsZeroAmountClaim() public {
        token.mint(address(bag), 12 ether);

        vm.expectEmit(true, true, true, true, address(bag));
        emit IBag.ERC20Claimed(owner, recipient, address(token), 0);

        vm.prank(owner);
        uint256 amount = bag.claimERC20(address(token), recipient, 0);

        assertEq(amount, 0);
        assertEq(token.balanceOf(recipient), 0);
        assertEq(token.balanceOf(address(bag)), 12 ether);
    }

    function testClaimERC20RevertsWhenAmountExceedsBalance() public {
        token.mint(address(bag), 12 ether);

        vm.expectRevert();
        vm.prank(owner);
        bag.claimERC20(address(token), recipient, 12 ether + 1);
    }

    function testFuzzClaimERC20RevertsWhenAmountExceedsBalance(uint128 balance, uint128 excess) public {
        excess = uint128(bound(excess, 1, type(uint128).max));
        token.mint(address(bag), balance);

        vm.expectRevert();
        vm.prank(owner);
        bag.claimERC20(address(token), recipient, uint256(balance) + excess);
    }

    function testClaimERC20RevertsWhenCallerIsNotNFTOwner() public {
        token.mint(address(bag), 12 ether);

        vm.expectRevert(abi.encodeWithSelector(IBag.NotBagOwner.selector, other));
        vm.prank(other);
        bag.claimERC20(address(token), recipient, 1 ether);
    }

    function testClaimERC20RevertsForZeroAssetOrRecipient() public {
        vm.startPrank(owner);

        vm.expectRevert(IBag.ZeroAddress.selector);
        bag.claimERC20(address(0), recipient, 1 ether);

        vm.expectRevert(IBag.ZeroAddress.selector);
        bag.claimERC20(address(token), address(0), 1 ether);

        vm.stopPrank();
    }

    function testClaimERC20FollowsCurrentNFTOwnerAfterTransfer() public {
        token.mint(address(bag), 12 ether);
        uint256 tokenId = bag.TOKEN_ID();

        vm.prank(owner);
        bag.transferFrom(owner, other, tokenId);

        vm.expectRevert(abi.encodeWithSelector(IBag.NotBagOwner.selector, owner));
        vm.prank(owner);
        bag.claimERC20(address(token), recipient, 1 ether);

        vm.prank(other);
        uint256 amount = bag.claimERC20(address(token), recipient, 12 ether);

        assertEq(amount, 12 ether);
        assertEq(token.balanceOf(recipient), 12 ether);
    }

    function testFuzzClaimERC20FollowsCurrentNFTOwnerAfterTransfer(uint128 balance, uint128 amount) public {
        amount = uint128(bound(amount, 0, balance));
        token.mint(address(bag), balance);
        uint256 tokenId = bag.TOKEN_ID();

        vm.prank(owner);
        bag.transferFrom(owner, other, tokenId);

        vm.expectRevert(abi.encodeWithSelector(IBag.NotBagOwner.selector, owner));
        vm.prank(owner);
        bag.claimERC20(address(token), recipient, amount);

        vm.prank(other);
        uint256 amountClaimed = bag.claimERC20(address(token), recipient, amount);

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

    function testClaimERC721RevertsWhenCallerIsNotNFTOwner() public {
        nft.mint(address(bag), 7);

        vm.expectRevert(abi.encodeWithSelector(IBag.NotBagOwner.selector, other));
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

    function testClaimNativeTransfersSpecifiedAmountAndEmits() public {
        vm.deal(address(bag), 3 ether);
        uint256 recipientBalanceBefore = recipient.balance;

        vm.expectEmit(true, true, true, true, address(bag));
        emit IBag.NativeClaimed(owner, recipient, 1 ether);

        vm.prank(owner);
        uint256 amount = bag.claimNative(payable(recipient), 1 ether);

        assertEq(amount, 1 ether);
        assertEq(recipient.balance - recipientBalanceBefore, 1 ether);
        assertEq(address(bag).balance, 2 ether);
    }

    function testFuzzClaimNativeTransfersSpecifiedAmount(address payable recipient_, uint128 balance, uint128 amount)
        public
    {
        vm.assume(recipient_ != address(0));
        vm.assume(recipient_ != payable(address(bag)));
        vm.assume(recipient_.code.length == 0);
        amount = uint128(bound(amount, 0, balance));
        vm.deal(address(bag), balance);
        uint256 recipientBalanceBefore = recipient_.balance;

        vm.prank(owner);
        uint256 amountClaimed = bag.claimNative(recipient_, amount);

        assertEq(amountClaimed, amount);
        assertEq(recipient_.balance - recipientBalanceBefore, amount);
        assertEq(address(bag).balance, uint256(balance) - amount);
    }

    function testClaimNativeAllowsZeroAmountClaim() public {
        vm.deal(address(bag), 3 ether);

        vm.expectEmit(true, true, true, true, address(bag));
        emit IBag.NativeClaimed(owner, recipient, 0);

        vm.prank(owner);
        uint256 amount = bag.claimNative(payable(recipient), 0);

        assertEq(amount, 0);
        assertEq(address(bag).balance, 3 ether);
    }

    function testClaimNativeRevertsWhenAmountExceedsBalance() public {
        vm.deal(address(bag), 3 ether);

        vm.expectRevert();
        vm.prank(owner);
        bag.claimNative(payable(recipient), 3 ether + 1);
    }

    function testFuzzClaimNativeRevertsWhenAmountExceedsBalance(uint128 balance, uint128 excess) public {
        excess = uint128(bound(excess, 1, type(uint128).max));
        vm.deal(address(bag), balance);

        vm.expectRevert();
        vm.prank(owner);
        bag.claimNative(payable(recipient), uint256(balance) + excess);
    }

    function testClaimNativeRevertsWhenCallerIsNotNFTOwner() public {
        vm.deal(address(bag), 3 ether);

        vm.expectRevert(abi.encodeWithSelector(IBag.NotBagOwner.selector, other));
        vm.prank(other);
        bag.claimNative(payable(recipient), 1 ether);
    }

    function testClaimNativeRevertsForZeroRecipient() public {
        vm.expectRevert(IBag.ZeroAddress.selector);
        vm.prank(owner);
        bag.claimNative(payable(address(0)), 1 ether);
    }

    function testClaimNativeRevertsWhenRecipientRejectsNativeTransfer() public {
        NativeRejector rejector = new NativeRejector();
        vm.deal(address(bag), 3 ether);

        vm.expectRevert(bytes("reject native"));
        vm.prank(owner);
        bag.claimNative(payable(address(rejector)), 1 ether);
    }

    function testReceiveAcceptsNativeETH() public {
        vm.deal(other, 1 ether);

        vm.prank(other);
        (bool success,) = address(bag).call{value: 1 ether}("");

        assertTrue(success);
        assertEq(address(bag).balance, 1 ether);
    }

    function testBagDoesNotImplementERC721Receiver() public {
        assertFalse(bag.supportsInterface(type(IERC721Receiver).interfaceId));
    }
}
