// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// Mock imports
import { OFTMock } from "./mocks/OFTMock.sol";
import { ERC20Mock } from "./mocks/ERC20Mock.sol";
import { OFTComposerMock } from "./mocks/OFTComposerMock.sol";

// OApp imports
import { IOAppOptionsType3, EnforcedOptionParam } from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/libs/OAppOptionsType3.sol";
import { OptionsBuilder } from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/libs/OptionsBuilder.sol";

// OFT imports
import { IOFT, SendParam, OFTReceipt } from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/interfaces/IOFT.sol";
import { MessagingFee, MessagingReceipt } from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/OFTCore.sol";
import { OFTMsgCodec } from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/libs/OFTMsgCodec.sol";
import { OFTComposeMsgCodec } from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/libs/OFTComposeMsgCodec.sol";

// OZ imports
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
// Forge imports
import "forge-std/console.sol";

// DevTools imports
import { TestHelperOz5 } from "@layerzerolabs/test-devtools-evm-foundry/contracts/TestHelperOz5.sol";

// OCCAdapter imports
import "../../contracts/Ledger.sol";
import "../../contracts/ProxyLedger.sol";

contract LedgerProxyTest is TestHelperOz5 {
    using OptionsBuilder for bytes;

    uint32 aEid = 1;
    uint32 bEid = 2;

    OFTMock aOFT;
    OFTMock bOFT;

    ProxyLedger proxyA;
    Ledger ledgerB;

    address public userA = address(0x1);
    address public userB = address(0x2);
    uint256 public initialBalance = 100 ether;

    function setUp() public virtual override {
        vm.deal(userA, 1000 ether);
        vm.deal(userB, 1000 ether);

        super.setUp();
        setUpEndpoints(2, LibraryType.UltraLightNode);

        aOFT = OFTMock(
            _deployOApp(type(OFTMock).creationCode, abi.encode("aOFT", "aOFT", address(endpoints[aEid]), address(this)))
        );

        bOFT = OFTMock(
            _deployOApp(type(OFTMock).creationCode, abi.encode("bOFT", "bOFT", address(endpoints[bEid]), address(this)))
        );

        // config and wire the ofts
        address[] memory ofts = new address[](2);
        ofts[0] = address(aOFT);
        ofts[1] = address(bOFT);
        this.wireOApps(ofts);

        // mint tokens
        aOFT.mint(userA, initialBalance);
        bOFT.mint(userB, initialBalance);

        // deploy and initialize upgradeable proxy ledger
        address proxyAImpl = address(new ProxyLedger());
        bytes memory initBytes = abi.encodeWithSelector(ProxyLedger.initialize.selector, address(aOFT), address(this));
        address proxyAddr = address(new ERC1967Proxy(proxyAImpl, initBytes));
        proxyA = ProxyLedger(payable(proxyAddr));

        ledgerB = new Ledger();
        ledgerB.initialize(address(this), address(ledgerB), aOFT, 1 ether, 100 ether);

        proxyA.setMyChainId(aEid);

        ledgerB.setMyChainId(bEid);

        proxyA.setLedgerInfo(bEid, address(ledgerB));
        proxyA.setChainId2Eid(bEid, bEid);

        ledgerB.setChainId2Eid(aEid, aEid);
        ledgerB.setChainId2ProxyLedgerAddr(aEid, address(proxyA));

        vm.deal(address(ledgerB), 1000 ether);
    }

    function _test_constructor() public {
        assertEq(aOFT.owner(), address(this));
        assertEq(bOFT.owner(), address(this));

        assertEq(aOFT.balanceOf(userA), initialBalance);
        assertEq(bOFT.balanceOf(userB), initialBalance);

        assertEq(aOFT.token(), address(aOFT));
        assertEq(bOFT.token(), address(bOFT));
    }

    function test_occ_user_stake() public {

        assertEq(aOFT.balanceOf(userA), initialBalance);
        assertEq(bOFT.balanceOf(userB), initialBalance);

        uint256 tokensToSend = 1 ether;

        vm.prank(userA);
        aOFT.approve(address(proxyA), tokensToSend);

        uint256 nativeFee = proxyA.qouteStake(tokensToSend, userA, false);
        vm.prank(userA);
        proxyA.stake{value: nativeFee}(tokensToSend, userA, false);
        verifyPackets(bEid, addressToBytes32(address(bOFT)));

        assertEq(aOFT.balanceOf(userA), initialBalance - tokensToSend);
        assertEq(bOFT.balanceOf(address(ledgerB)), tokensToSend);

        // lzCompose params
        (MessagingReceipt memory msgReceipt, OFTReceipt memory oftReceipt, bytes memory msgCompose, bytes memory options) = proxyA.getLzSendReceipt();

        // lzCompose params
        uint32 dstEid_ = bEid;
        address from_ = address(bOFT);
        bytes memory options_ = options;
        bytes32 guid_ = msgReceipt.guid;
        address to_ = address(ledgerB);
        bytes memory composerMsg_ = OFTComposeMsgCodec.encode(
            msgReceipt.nonce,
            aEid,
            oftReceipt.amountReceivedLD,
            abi.encodePacked(addressToBytes32(address(proxyA)), msgCompose)
        );
        this.lzCompose(dstEid_, from_, options_, guid_, to_, composerMsg_);
    }


    // TODO import the rest of oft tests?
}
