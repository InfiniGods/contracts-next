// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";

import {CloneFactory} from "src/infra/CloneFactory.sol";
import {EIP1967Proxy} from "src/infra/EIP1967Proxy.sol";

import {LibString} from "src/lib/LibString.sol";

import {ERC1155Core} from "src/core/token/ERC1155Core.sol";
import {SimpleMetadataHookERC1155, ERC1155Hook} from "src/hook/metadata/SimpleMetadataHookERC1155.sol";

contract SimpleMetadataHookERC1155Test is Test {

    using LibString for uint256;

    /*//////////////////////////////////////////////////////////////
                                SETUP
    //////////////////////////////////////////////////////////////*/

    // Participants
    address public platformAdmin = address(0x123);
    address public developer = address(0x456);
    address public endUser = 0xDDdDddDdDdddDDddDDddDDDDdDdDDdDDdDDDDDDd;

    // Target test contracts
    ERC1155Core public erc1155Core;
    SimpleMetadataHookERC1155 public metadataHook;

    function setUp() public {

        // Platform deploys metadata hook.
        address mintHookImpl = address(new SimpleMetadataHookERC1155());

        bytes memory initData = abi.encodeWithSelector(
            metadataHook.initialize.selector,
            platformAdmin // upgradeAdmin
        );
        address mintHookProxy = address(new EIP1967Proxy(mintHookImpl, initData));
        metadataHook = SimpleMetadataHookERC1155(mintHookProxy);

        // Platform deploys ERC1155 core implementation and clone factory.
        address erc1155CoreImpl = address(new ERC1155Core());
        CloneFactory factory = new CloneFactory();

        vm.startPrank(developer);

        ERC1155Core.InitCall memory initCall;
        address[] memory preinstallHooks = new address[](1);
        preinstallHooks[0] = address(metadataHook);

        bytes memory erc1155InitData = abi.encodeWithSelector(
            ERC1155Core.initialize.selector,
            initCall,
            preinstallHooks,
            developer, // core contract admin
            "Test ERC1155",
            "TST",
            "ipfs://QmPVMvePSWfYXTa8haCbFavYx4GM4kBPzvdgBw7PTGUByp/0" // mock contract URI of actual length
        );
        erc1155Core = ERC1155Core(factory.deployProxyByImplementation(erc1155CoreImpl, erc1155InitData, bytes32("salt")));

        vm.stopPrank();

        // Set labels
        vm.deal(endUser, 100 ether);

        vm.label(platformAdmin, "Admin");
        vm.label(developer, "Developer");
        vm.label(endUser, "Claimer");
        
        vm.label(address(erc1155Core), "ERC1155Core");
        vm.label(address(mintHookImpl), "metadataHook");
        vm.label(mintHookProxy, "ProxymetadataHook");
    }

    function test_setTokenURI_state() public {
        uint256 tokenId = 454;

        assertEq(erc1155Core.uri(tokenId), "");

        // Set token URI
        string memory tokenURI = "ipfs://QmPVMvePSWfYXTa8haCbFavYx4GM4kBPzvdgBw7PTGUByp/454";

        vm.prank(developer);
        metadataHook.setTokenURI(address(erc1155Core), tokenId, tokenURI);

        assertEq(erc1155Core.uri(tokenId),tokenURI);

        string memory tokenURI2 = "ipfs://QmPVMveABCDEYXTa8haCbFavYx4GM4kBPzvdgBw7PTGUByp/454";

        vm.prank(developer);
        metadataHook.setTokenURI(address(erc1155Core), tokenId, tokenURI2);

        assertEq(erc1155Core.uri(tokenId),tokenURI2);
    }
}
