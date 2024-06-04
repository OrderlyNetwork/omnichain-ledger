// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// Mock imports
import {OFTMock} from "./mocks/OFTMock.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";
import {OFTComposerMock} from "./mocks/OFTComposerMock.sol";

// OApp imports
import {IOAppOptionsType3, EnforcedOptionParam} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/libs/OAppOptionsType3.sol";
import {OptionsBuilder} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/libs/OptionsBuilder.sol";

// OFT imports
import {IOFT, SendParam, OFTReceipt} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/interfaces/IOFT.sol";
import {MessagingFee, MessagingReceipt} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/OFTCore.sol";
import {OFTMsgCodec} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/libs/OFTMsgCodec.sol";
import {OFTComposeMsgCodec} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/libs/OFTComposeMsgCodec.sol";

// OZ imports
import {IERC20} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
// Forge imports
import "forge-std/console.sol";

// DevTools imports
import {TestHelperOz5} from "@layerzerolabs/test-devtools-evm-foundry/contracts/TestHelperOz5.sol";

// OCCAdapter imports
import "../../contracts/test/LedgerTest.sol";
import "../../contracts/ProxyLedger.sol";
import "../../contracts/lib/LedgerOCCManager.sol";
// md imports
import "./MerkleHelper.sol";

interface ILzReceipt {
    function getLzSendReceipt() external returns (MessagingReceipt memory, OFTReceipt memory, bytes memory, bytes memory);
}

contract LedgerProxyTest is TestHelperOz5 {
    using OptionsBuilder for bytes;

    uint32 aEid = 1;
    uint32 bEid = 2;

    OFTMock aOFT;
    OFTMock bOFT;

    OFTMock usdc;

    ProxyLedger proxyA;
    LedgerTest ledgerB;

    LedgerOCCManager ledgerOCCManager;

    address public userA = address(0x1);
    address public userB = address(0x2);
    uint256 public initialBalance = 100 ether;

    function setUp() public virtual override {
        vm.deal(userA, 1000 ether);
        vm.deal(userB, 1000 ether);

        super.setUp();
        setUpEndpoints(2, LibraryType.UltraLightNode);

        aOFT = OFTMock(_deployOApp(type(OFTMock).creationCode, abi.encode("aOFT", "aOFT", address(endpoints[aEid]), address(this))));

        bOFT = OFTMock(_deployOApp(type(OFTMock).creationCode, abi.encode("bOFT", "bOFT", address(endpoints[bEid]), address(this))));

        usdc = OFTMock(_deployOApp(type(OFTMock).creationCode, abi.encode("usdc", "usdc", address(endpoints[aEid]), address(this))));

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
        bytes memory initBytes = abi.encodeWithSelector(ProxyLedger.initialize.selector, address(aOFT), address(usdc), address(this));
        address proxyAddr = address(new ERC1967Proxy(proxyAImpl, initBytes));
        proxyA = ProxyLedger(payable(proxyAddr));
        usdc.mint(address(proxyA), 100 ether);

        proxyA.setLzEndpoint(endpoints[aEid]);

        ledgerOCCManager = new LedgerOCCManager();
        ledgerOCCManager.initialize(address(bOFT), address(this));
        ledgerB = new LedgerTest();
        address placeholderAddr = address(ledgerB);
        ledgerB.initialize(address(this), address(ledgerOCCManager), placeholderAddr, bOFT, 1 ether, 100 ether);

        ledgerOCCManager.setLedgerAddr(address(ledgerB));
        ledgerOCCManager.setLzEndpoint(endpoints[bEid]);

        proxyA.setMyChainId(aEid);

        ledgerOCCManager.setMyChainId(bEid);

        proxyA.setLedgerInfo(bEid, address(ledgerOCCManager));
        proxyA.setChainId2Eid(bEid, bEid);

        ledgerOCCManager.setChainId2Eid(aEid, aEid);
        ledgerOCCManager.setChainId2ProxyLedgerAddr(aEid, address(proxyA));

        vm.deal(address(ledgerOCCManager), 1000 ether);
    }

    function _deliver_occ_msg(address sender, address from, address to, uint32 fromEid, uint32 toEid) public {
        // lzCompose params
        (MessagingReceipt memory msgReceipt, OFTReceipt memory oftReceipt, bytes memory msgCompose, bytes memory options) = ILzReceipt(sender)
            .getLzSendReceipt();

        // lzCompose params
        bytes memory composerMsg_ = OFTComposeMsgCodec.encode(
            msgReceipt.nonce,
            fromEid,
            oftReceipt.amountReceivedLD,
            abi.encodePacked(addressToBytes32(sender), msgCompose)
        );
        this.lzCompose(toEid, from, options, msgReceipt.guid, to, composerMsg_);
    }

    function test_constructor() public {
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

        uint256 nativeFee = proxyA.quoteStake(tokensToSend, userA, false);
        vm.prank(userA);
        proxyA.stake{value: nativeFee}(tokensToSend, false);
        verifyPackets(bEid, addressToBytes32(address(bOFT)));

        assertEq(aOFT.balanceOf(userA), initialBalance - tokensToSend);
        assertEq(bOFT.balanceOf(address(ledgerOCCManager)), tokensToSend);

        // lzCompose params
        (MessagingReceipt memory msgReceipt, OFTReceipt memory oftReceipt, bytes memory msgCompose, bytes memory options) = proxyA.getLzSendReceipt();

        // lzCompose params
        uint32 dstEid_ = bEid;
        address from_ = address(bOFT);
        bytes memory options_ = options;
        bytes32 guid_ = msgReceipt.guid;
        address to_ = address(ledgerOCCManager);
        bytes memory composerMsg_ = OFTComposeMsgCodec.encode(
            msgReceipt.nonce,
            aEid,
            oftReceipt.amountReceivedLD,
            abi.encodePacked(addressToBytes32(address(proxyA)), msgCompose)
        );
        this.lzCompose(dstEid_, from_, options_, guid_, to_, composerMsg_);
    }

    function test_occ_claim_reward() public {
        bOFT.mint(address(ledgerOCCManager), 10000 ether);
        // userA and userB and address(this)
        address[] memory users = new address[](3);
        users[0] = userA;
        users[1] = userB;
        users[2] = address(this);
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 10 ether;
        amounts[1] = 20 ether;
        amounts[2] = 30 ether;

        console.log("start build tree...");

        MerkleTreeHelper.Tree memory tree = MerkleTreeHelper.buildTree(users, amounts);

        uint256 cumulativeAmount = 10 ether;

        uint32 distributionId = 1;
        uint256 timestamp = block.timestamp;
        bytes memory ipfsCid = "0x";
        ledgerB.createDistribution(distributionId, LedgerToken.ORDER, tree.root, timestamp, ipfsCid);

        // get proof of userA
        bytes32[] memory merkleProof = MerkleTreeHelper.getProof(tree, 0, 3);

        // length of proof
        console.log("proof length: ");
        console.log(merkleProof.length);

        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(userA, amounts[0]))));
        MerkleTreeHelper.verifyProof(tree.root, leaf, merkleProof);

        uint256 nativeFee = proxyA.quoteClaimReward(distributionId, userA, cumulativeAmount, merkleProof, false);
        vm.prank(userA);
        proxyA.claimReward{value: nativeFee}(distributionId, cumulativeAmount, merkleProof, false);
        verifyPackets(bEid, addressToBytes32(address(bOFT)));

        _deliver_occ_msg(address(proxyA), address(bOFT), address(ledgerOCCManager), aEid, bEid);

        verifyPackets(aEid, addressToBytes32(address(aOFT)));

        _deliver_occ_msg(address(ledgerOCCManager), address(aOFT), address(proxyA), bEid, aEid);
    }

    function test_occ_user_unstake() public {
        uint256 tokensToSend = 1 ether;
        test_occ_user_stake();

        uint8 opCode = uint8(PayloadDataType.CreateOrderUnstakeRequest);

        uint256 nativeFee = proxyA.quoteSendUserRequest(tokensToSend, userA, opCode);
        vm.prank(userA);
        proxyA.sendUserRequest{value: nativeFee}(tokensToSend, opCode);
        verifyPackets(bEid, addressToBytes32(address(bOFT)));

        _deliver_occ_msg(address(proxyA), address(bOFT), address(ledgerOCCManager), aEid, bEid);
    }

    function test_occ_user_cancel_unstake() public {
        uint256 tokensToSend = 1 ether;
        test_occ_user_unstake();

        uint8 opCode = uint8(PayloadDataType.CancelOrderUnstakeRequest);

        uint256 nativeFee = proxyA.quoteSendUserRequest(tokensToSend, userA, opCode);
        vm.prank(userA);
        proxyA.sendUserRequest{value: nativeFee}(tokensToSend, opCode);
        verifyPackets(bEid, addressToBytes32(address(bOFT)));

        _deliver_occ_msg(address(proxyA), address(bOFT), address(ledgerOCCManager), aEid, bEid);
    }

    function test_occ_user_withdraw_order() public {
        uint256 tokensToSend = 1 ether;
        test_occ_user_unstake();

        vm.warp(block.timestamp + 7 days); // warp time to 1 day later (1 day = 86400 seconds)

        uint8 opCode = uint8(PayloadDataType.WithdrawOrder);

        uint256 nativeFee = proxyA.quoteSendUserRequest(tokensToSend, userA, opCode);
        vm.prank(userA);
        proxyA.sendUserRequest{value: nativeFee}(tokensToSend, opCode);
        verifyPackets(bEid, addressToBytes32(address(bOFT)));

        _deliver_occ_msg(address(proxyA), address(bOFT), address(ledgerOCCManager), aEid, bEid);

        verifyPackets(aEid, addressToBytes32(address(aOFT)));
        _deliver_occ_msg(address(ledgerOCCManager), address(aOFT), address(proxyA), bEid, aEid);
    }

    function test_occ_user_redeem_valor() public {
        uint256 redeemAmount = 100;
        vm.warp(block.timestamp + 14 days); // warp time to 1 day later (1 day = 86400 seconds
        ledgerB.setTotalValorAmount(5000);
        test_occ_user_stake();

        console.log("block.timestamp: ");
        console.log(block.timestamp);
        console.log("batch_id: ");
        console.log(ledgerB.getCurrentBatchId());

        for (uint i = 0; i < 13; i++) {
            vm.warp(block.timestamp + 1 days); // warp time to 1 day later (1 day = 86400 seconds)
            ledgerB.dailyUsdcNetFeeRevenueTestNoSignatureCheck(1000);
        }

        console.log("block.timestamp: ");
        console.log(block.timestamp);
        // vm.warp(block.timestamp + 14 days);
        console.log("ledgerB.getCurrentBatchId(): ");
        console.log(ledgerB.getCurrentBatchId());

        // ledgerB.setCollectedValor(userA, 2000);

        uint8 opCode = uint8(PayloadDataType.RedeemValor);

        uint256 nativeFee = proxyA.quoteSendUserRequest(redeemAmount, userA, opCode);
        vm.prank(userA);
        proxyA.sendUserRequest{value: nativeFee}(redeemAmount, opCode);
        verifyPackets(bEid, addressToBytes32(address(bOFT)));

        _deliver_occ_msg(address(proxyA), address(bOFT), address(ledgerOCCManager), aEid, bEid);
    }

    function test_occ_user_claim_usdc_revenue() public {
        uint256 claimAmount = 0;
        test_occ_user_redeem_valor();
        // ledgerB.updateValorVars();
        // ledgerB.dailyUsdcNetFeeRevenue(1000*14);
        vm.warp(block.timestamp + 2 days);
        ledgerB.fixBatchValorToUsdcRate(1);
        ledgerB.batchPreparedToClaim(1);

        (uint256 batchStartTime, uint256 batchEndTime, bool claimable, uint256 redeemedValorAmount, uint256 fixedValorToUsdcRateScaled) = ledgerB
            .getBatchInfo(1);

        console.log("batchStartTime: ");
        console.log(batchStartTime);
        console.log("batchEndTime: ");
        console.log(batchEndTime);
        console.log("claimable: ");
        console.log(claimable);
        console.log("redeemedValorAmount: ");
        console.log(redeemedValorAmount);
        console.log("fixedValorToUsdcRateScaled: ");
        console.log(fixedValorToUsdcRateScaled);

        uint8 opCode = uint8(PayloadDataType.ClaimUsdcRevenue);

        uint256 nativeFee = proxyA.quoteSendUserRequest(claimAmount, userA, opCode);
        vm.prank(userA);
        proxyA.sendUserRequest{value: nativeFee}(claimAmount, opCode);
        verifyPackets(bEid, addressToBytes32(address(bOFT)));

        _deliver_occ_msg(address(proxyA), address(bOFT), address(ledgerOCCManager), aEid, bEid);

        verifyPackets(aEid, addressToBytes32(address(aOFT)));
        _deliver_occ_msg(address(ledgerOCCManager), address(aOFT), address(proxyA), bEid, aEid);
    }
}
