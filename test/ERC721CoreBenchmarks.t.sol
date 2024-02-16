// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";

import "src/lib/LibClone.sol";
import "src/common/UUPSUpgradeable.sol";

import { CloneFactory } from "src/infra/CloneFactory.sol";
import { EIP1967Proxy } from "src/infra/EIP1967Proxy.sol";
import { MinimalUpgradeableRouter } from "src/infra/MinimalUpgradeableRouter.sol";
import { MockOneExtensionImpl, MockFourExtensionImpl } from "test/mocks/MockExtensionImpl.sol";

import { ERC721Core, ERC721Initializable } from "src/core/token/ERC721Core.sol";
import { ERC721Extension, AllowlistMintExtensionERC721 } from "src/extension/mint/AllowlistMintExtensionERC721.sol";
import { LazyMintExtension } from "src/extension/metadata/LazyMintExtension.sol";
import { RoyaltyExtension } from "src/extension/royalty/RoyaltyExtension.sol";
import { IERC721 } from "src/interface/eip/IERC721.sol";
import { IExtension } from "src/interface/extension/IExtension.sol";
import { IInitCall } from "src/interface/common/IInitCall.sol";

/**
 *  This test showcases how users would use ERC-721 contracts on the thirdweb platform.
 *
 *  CORE CONTRACTS:
 *
 *  Developers will deploy non-upgradeable minimal clones of token core contracts e.g. the ERC-721 Core contract.
 *
 *      - This contract is initializable, and meant to be used with proxy contracts.
 *      - Implements the token standard (and the respective token metadata standard).
 *      - Uses the role based permission model of the `Permission` contract.
 *      - Implements the `IExtensionInstaller` interface.
 *
 *  EXTENSIONS:
 *
 *  Core contracts work with "extensions". There is a fixed set of 6 extensions supported by the core contract:
 *
 *      - BeforeMint: called before a token is minted in the ERC721Core.mint call.
 *      - BeforeTransfer: called before a token is transferred in the ERC721.transferFrom call.
 *      - BeforeBurn: called before a token is burned in the ERC721.burn call.
 *      - BeforeApprove: called before the ERC721.approve call.
 *      - Token URI: called when the ERC721Metadata.tokenURI function is called.
 *      - Royalty: called when the ERC2981.royaltyInfo function is called.
 *
 *  Each of these extensions is an external call made to a contract that implements the `IExtension` interface.
 *
 *  The purpose of extensions is to allow developers to extend their contract's functionality by running custom logic
 *  right before a token is minted, transferred, burned, or approved, or for returning a token's metadata or royalty info.
 *
 *  Developers can install extensions into their core contracts, and uninstall extensions at any time.
 *
 *  UPGRADEABILITY:
 *
 *  thirdweb will publish upgradeable, 'shared state' extensions for developers (see src/erc721/extensions/). These extension contracts are
 *  designed to be used by develpers as a shared resource, and are upgradeable by thirdweb. This allows thirdweb to make
 *  beacon upgrades to developer contracts using these extensions.
 */
contract ERC721CoreBenchmarkTest is Test {
    /*//////////////////////////////////////////////////////////////
                                SETUP
    //////////////////////////////////////////////////////////////*/

    // Participants
    address public platformAdmin = address(0x123);
    address public platformUser = address(0x456);
    address public claimer = 0xDDdDddDdDdddDDddDDddDDDDdDdDDdDDdDDDDDDd;

    // Test util
    CloneFactory public cloneFactory;

    // Target test contracts
    address public erc721Implementation;
    address public extensionProxyAddress;

    ERC721Core public erc721;
    AllowlistMintExtensionERC721 public simpleClaimExtension;
    LazyMintExtension public lazyMintExtension;
    RoyaltyExtension public royaltyExtension;

    MockOneExtensionImpl public mockOneExtension;
    MockFourExtensionImpl public mockFourExtension;

    // Token claim params
    uint256 public pricePerToken = 0.1 ether;
    uint256 public availableSupply = 100;

    function setUp() public {
        // Setup up to enabling minting on ERC-721 contract.

        // Platform contracts: gas incurred by platform.
        vm.startPrank(platformAdmin);

        cloneFactory = new CloneFactory();

        extensionProxyAddress = cloneFactory.deployDeterministicERC1967(
            address(new AllowlistMintExtensionERC721()),
            abi.encodeWithSelector(AllowlistMintExtensionERC721.initialize.selector, platformAdmin),
            bytes32("salt")
        );
        simpleClaimExtension = AllowlistMintExtensionERC721(extensionProxyAddress);
        assertEq(simpleClaimExtension.getNextTokenIdToMint(address(erc721)), 0);

        address lazyMintExtensionProxyAddress = cloneFactory.deployDeterministicERC1967(
            address(new LazyMintExtension()),
            abi.encodeWithSelector(AllowlistMintExtensionERC721.initialize.selector, platformAdmin),
            bytes32("salt")
        );
        lazyMintExtension = LazyMintExtension(lazyMintExtensionProxyAddress);

        address royaltyExtensionProxyAddress = address(
            new MinimalUpgradeableRouter(platformAdmin, address(new RoyaltyExtension()))
        );
        royaltyExtension = RoyaltyExtension(royaltyExtensionProxyAddress);

        address mockAddress = address(
            new EIP1967Proxy(
                address(new MockOneExtensionImpl()),
                abi.encodeWithSelector(MockOneExtensionImpl.initialize.selector, platformAdmin)
            )
        );
        mockOneExtension = MockOneExtensionImpl(mockAddress);

        mockAddress = address(
            new EIP1967Proxy(
                address(new MockFourExtensionImpl()),
                abi.encodeWithSelector(MockFourExtensionImpl.initialize.selector, platformAdmin)
            )
        );
        mockFourExtension = MockFourExtensionImpl(mockAddress);

        erc721Implementation = address(new ERC721Core());

        vm.stopPrank();

        // Developer contract: gas incurred by developer.
        vm.startPrank(platformUser);

        IInitCall.InitCall memory initCall;
        bytes memory data = abi.encodeWithSelector(
            ERC721Core.initialize.selector,
            initCall,
            new address[](0),
            platformUser,
            "Test",
            "TST",
            "contractURI://"
        );
        erc721 = ERC721Core(cloneFactory.deployProxyByImplementation(erc721Implementation, data, bytes32("salt")));

        vm.stopPrank();

        vm.label(address(erc721), "ERC721Core");
        vm.label(erc721Implementation, "ERC721CoreImpl");
        vm.label(extensionProxyAddress, "AllowlistMintExtensionERC721");
        vm.label(platformAdmin, "Admin");
        vm.label(platformUser, "Developer");
        vm.label(claimer, "Claimer");
        
        // Developer installs `AllowlistMintExtensionERC721` extension
        vm.startPrank(platformUser);

        erc721.installExtension(IExtension(extensionProxyAddress));
        erc721.installExtension(IExtension(lazyMintExtensionProxyAddress));

        // Developer sets up token metadata and claim conditions: gas incurred by developer
        erc721.hookFunctionWrite(
            erc721.TOKEN_URI_FLAG(),
            0,
            abi.encodeWithSelector(LazyMintExtension.lazyMint.selector, 10_000, "https://example.com/", "")
        );

        string[] memory inputs = new string[](2);
        inputs[0] = "node";
        inputs[1] = "test/scripts/generateRoot.ts";

        bytes memory result = vm.ffi(inputs);
        bytes32 root = abi.decode(result, (bytes32));

        AllowlistMintExtensionERC721.ClaimCondition memory condition = AllowlistMintExtensionERC721.ClaimCondition({
            price: pricePerToken,
            availableSupply: availableSupply,
            allowlistMerkleRoot: root
        });
        erc721.hookFunctionWrite(
            erc721.BEFORE_MINT_FLAG(),
            0,
            abi.encodeWithSelector(AllowlistMintExtensionERC721.setClaimCondition.selector, condition)
        );

        AllowlistMintExtensionERC721.FeeConfig memory feeConfig;
        feeConfig.primarySaleRecipient = platformUser;
        feeConfig.platformFeeRecipient = address(0x789);
        feeConfig.platformFeeBps = 100; // 1%

        erc721.hookFunctionWrite(
            erc721.BEFORE_MINT_FLAG(),
            0,
            abi.encodeWithSelector(AllowlistMintExtensionERC721.setDefaultFeeConfig.selector, feeConfig)
        );

        vm.stopPrank();

        vm.deal(claimer, 10 ether);
    }

    /*//////////////////////////////////////////////////////////////
                        DEPLOY END-USER CONTRACT
    //////////////////////////////////////////////////////////////*/

    function test_deployEndUserContract() public {
        // Deploy a minimal proxy to the ERC721Core implementation contract.

        vm.pauseGasMetering();

        IInitCall.InitCall memory initCall;

        address impl = erc721Implementation;
        bytes memory data = abi.encodeWithSelector(
            ERC721Core.initialize.selector,
            initCall,
            new address[](0),
            platformUser,
            "Test",
            "TST",
            "contractURI://"
        );
        bytes32 salt = bytes32("salt");

        vm.resumeGasMetering();

        cloneFactory.deployProxyByImplementation(impl, data, salt);
    }

    function test_deployEndUserContract_withExtensions() public {
        // Deploy a minimal proxy to the ERC721Core implementation contract.

        vm.pauseGasMetering();

        address[] memory extensions = new address[](3);
        extensions[0] = address(simpleClaimExtension);
        extensions[1] = address(lazyMintExtension);
        extensions[2] = address(royaltyExtension);

        IInitCall.InitCall memory initCall;

        address impl = erc721Implementation;
        bytes memory data = abi.encodeWithSelector(
            ERC721Core.initialize.selector,
            initCall,
            extensions,
            platformUser,
            "Test",
            "TST",
            "contractURI://"
        );
        bytes32 salt = bytes32("salt");

        vm.resumeGasMetering();

        cloneFactory.deployProxyByImplementation(impl, data, salt);
    }

    /*//////////////////////////////////////////////////////////////
                        MINT 1 TOKEN AND 10 TOKENS
    //////////////////////////////////////////////////////////////*/

    function test_mintOneToken() public {
        vm.pauseGasMetering();

        // Check pre-mint state
        string[] memory inputs = new string[](2);
        inputs[0] = "node";
        inputs[1] = "test/scripts/getProof.ts";

        bytes memory result = vm.ffi(inputs);
        bytes32[] memory proofs = abi.decode(result, (bytes32[]));
        uint256 quantityToClaim = 1;

        bytes memory encodedArgs = abi.encode(proofs);

        ERC721Core claimContract = erc721;
        address claimerAddress = claimer;

        vm.prank(claimerAddress);

        vm.resumeGasMetering();

        // Claim token
        claimContract.mint{ value: pricePerToken }(claimerAddress, quantityToClaim, encodedArgs);
    }

    function test_mintTenTokens() public {
        vm.pauseGasMetering();

        // Check pre-mint state
        string[] memory inputs = new string[](2);
        inputs[0] = "node";
        inputs[1] = "test/scripts/getProof.ts";

        bytes memory result = vm.ffi(inputs);
        bytes32[] memory proofs = abi.decode(result, (bytes32[]));
        uint256 quantityToClaim = 10;

        bytes memory encodedArgs = abi.encode(proofs);

        ERC721Core claimContract = erc721;
        address claimerAddress = claimer;

        vm.prank(claimerAddress);

        vm.resumeGasMetering();

        // Claim token
        claimContract.mint{ value: pricePerToken * 10 }(claimerAddress, quantityToClaim, encodedArgs);
    }

    /*//////////////////////////////////////////////////////////////
                            TRANSFER 1 TOKEN
    //////////////////////////////////////////////////////////////*/

    function test_transferOneToken() public {
        vm.pauseGasMetering();

        // Claimer claims one token
        string[] memory claimInputs = new string[](2);
        claimInputs[0] = "node";
        claimInputs[1] = "test/scripts/getProof.ts";

        bytes memory claimResult = vm.ffi(claimInputs);
        bytes32[] memory proofs = abi.decode(claimResult, (bytes32[]));
        uint256 quantityToClaim = 1;

        bytes memory encodedArgs = abi.encode(proofs);

        // Claim token
        vm.prank(claimer);
        erc721.mint{ value: pricePerToken }(claimer, quantityToClaim, encodedArgs);

        uint256 tokenId = 0;
        address to = address(0x121212);
        address from = claimer;

        ERC721Core erc721Contract = erc721;
        vm.prank(from);

        vm.resumeGasMetering();

        // Transfer token
        erc721Contract.transferFrom(from, to, tokenId);
    }

    /*//////////////////////////////////////////////////////////////
                        PERFORM A BEACON UPGRADE
    //////////////////////////////////////////////////////////////*/

    function test_performUpgrade() public {
        vm.pauseGasMetering();

        address newAdmin = address(0x7890);
        address newImpl = address(new AllowlistMintExtensionERC721());
        address currentAdmin = platformAdmin;
        UUPSUpgradeable proxy = UUPSUpgradeable(payable(extensionProxyAddress));

        vm.prank(currentAdmin);

        vm.resumeGasMetering();

        // Perform upgrade
        proxy.upgradeToAndCall(newImpl, "");
        // assertEq(ERC721Extension(address(proxy)).admin(), newAdmin);
    }

    /*//////////////////////////////////////////////////////////////
            ADD NEW FUNCTIONALITY AND UPDATE FUNCTIONALITY
    //////////////////////////////////////////////////////////////*/

    function test_installOneExtension() public {
        vm.pauseGasMetering();

        address mockAddress = address(mockOneExtension);
        IExtension mockExtension = IExtension(mockAddress);

        ERC721Core extensionConsumer = erc721;

        vm.prank(platformUser);

        vm.resumeGasMetering();

        extensionConsumer.installExtension(mockExtension);
    }

    function test_installfiveExtensions() public {
        vm.pauseGasMetering();

        address mockAddress = address(mockFourExtension);
        IExtension mockExtension = IExtension(mockAddress);
        ERC721Core extensionConsumer = erc721;

        vm.prank(platformUser);
        extensionConsumer.uninstallExtension(IExtension(extensionProxyAddress));

        vm.prank(platformUser);

        vm.resumeGasMetering();

        extensionConsumer.installExtension(mockExtension);
    }

    function test_uninstallOneExtension() public {
        vm.pauseGasMetering();

        address mockAddress = address(mockOneExtension);
        IExtension mockExtension = IExtension(mockAddress);
        ERC721Core extensionConsumer = erc721;

        vm.prank(platformUser);
        extensionConsumer.installExtension(mockExtension);

        vm.prank(platformUser);

        vm.resumeGasMetering();

        extensionConsumer.uninstallExtension(mockExtension);
    }

    function test_uninstallFiveExtensions() public {
        vm.pauseGasMetering();

        address mockAddress = address(mockFourExtension);
        IExtension mockExtension = IExtension(mockAddress);
        ERC721Core extensionConsumer = erc721;

        vm.prank(platformUser);
        extensionConsumer.uninstallExtension(IExtension(extensionProxyAddress));

        vm.prank(platformUser);
        extensionConsumer.installExtension(mockExtension);

        vm.prank(platformUser);

        vm.resumeGasMetering();

        extensionConsumer.uninstallExtension(mockExtension);
    }
}
