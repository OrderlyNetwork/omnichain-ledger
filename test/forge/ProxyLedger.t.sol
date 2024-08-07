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
import {LedgerTest} from "../../contracts/test/LedgerTest.sol";
import {OmnichainLedgerV1} from "../../contracts/OmnichainLedgerV1.sol";
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

    address public orderCollectorAddress = address(0x3);

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

        console.log("ProxyLedger: ");
        // deploy and initialize upgradeable proxy ledger
        address proxyAImpl = address(new ProxyLedger());
        bytes memory initBytes = abi.encodeWithSelector(ProxyLedger.initialize.selector, address(aOFT), address(usdc), address(this));
        address proxyAddr = address(new ERC1967Proxy(proxyAImpl, initBytes));
        proxyA = ProxyLedger(payable(proxyAddr));
        usdc.mint(address(proxyA), 200 ether);

        proxyA.setLzEndpoint(endpoints[aEid]);

        console.log("ledgerOCCManager: ");
        address ledgerOCCManagerImpl = address(new LedgerOCCManager());
        bytes memory ledgerOCCManagerInitBytes = abi.encodeWithSelector(LedgerOCCManager.initialize.selector, address(bOFT), address(this));
        address ledgerOCCManagerProxyAddr = address(new ERC1967Proxy(ledgerOCCManagerImpl, ledgerOCCManagerInitBytes));
        ledgerOCCManager = LedgerOCCManager(payable(ledgerOCCManagerProxyAddr));

        console.log("LedgerTest: ");
        address ledgerBImpl = address(new LedgerTest());
        bytes memory ledgerBInitBytes = abi.encodeWithSelector(
            OmnichainLedgerV1.initialize.selector,
            address(this),
            address(ledgerOCCManager),
            1 ether,
            100 ether
        );
        address ledgerBProxyAddr = address(new ERC1967Proxy(ledgerBImpl, ledgerBInitBytes));
        ledgerB = LedgerTest(payable(ledgerBProxyAddr));

        ledgerOCCManager.setOrderCollector(orderCollectorAddress);
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

    function _createMerkleDistribution(
        LedgerToken _token,
        uint32 _distributionId
    ) public returns (uint32 distributionId, MerkleTreeHelper.Tree memory tree, uint256[] memory amounts, uint256 totalAmount) {
        bOFT.mint(address(ledgerOCCManager), 10000 ether);
        // userA and userB and address(this)
        address[] memory users = new address[](3);
        users[0] = userA;
        users[1] = userB;
        users[2] = address(this);
        amounts = new uint256[](3);
        amounts[0] = 10 ether;
        amounts[1] = 20 ether;
        amounts[2] = 30 ether;
        totalAmount = amounts[0] + amounts[1] + amounts[2];

        tree = MerkleTreeHelper.buildTree(users, amounts);

        distributionId = _distributionId;
        uint256 timestamp = block.timestamp;
        bytes memory ipfsCid = "0x";
        ledgerB.createDistribution(distributionId, _token, tree.root, timestamp, ipfsCid);
    }

    function _composeAndSendOneWayRequest(uint8 _opCode, uint256 _amount, address _user) public {
        uint256 nativeFee = proxyA.quoteSendUserRequest(_amount, _user, _opCode);
        vm.prank(_user);
        proxyA.sendUserRequest{value: nativeFee}(_amount, _opCode);
        verifyPackets(bEid, addressToBytes32(address(bOFT)));
        _deliver_occ_msg(address(proxyA), address(bOFT), address(ledgerOCCManager), aEid, bEid);
    }

    function _composeAndSendTwoWayRequest(uint8 _opCode, uint256 _amount, address _user) public {
        _composeAndSendOneWayRequest(_opCode, _amount, _user);

        verifyPackets(aEid, addressToBytes32(address(aOFT)));
        _deliver_occ_msg(address(ledgerOCCManager), address(aOFT), address(proxyA), bEid, aEid);
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

        uint256 nativeFee = proxyA.quoteStakeOrder(tokensToSend, userA);
        vm.prank(userA);
        proxyA.stakeOrder{value: nativeFee}(tokensToSend);
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

        // Move time to valor emission start time
        vm.warp(block.timestamp + 1 days);
    }

    function test_occ_claim_reward() public {
        (uint32 distributionId, MerkleTreeHelper.Tree memory tree, uint256[] memory amounts, ) = _createMerkleDistribution(LedgerToken.ORDER, 1);
        uint256 cumulativeAmountUserA = amounts[0];

        // get proof of userA
        bytes32[] memory merkleProof = MerkleTreeHelper.getProof(tree, 0, 3);

        // length of proof
        console.log("proof length: ");
        console.log(merkleProof.length);

        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(userA, amounts[0]))));
        MerkleTreeHelper.verifyProof(tree.root, leaf, merkleProof);

        uint256 nativeFee = proxyA.quoteClaimReward(distributionId, userA, cumulativeAmountUserA, merkleProof);
        vm.prank(userA);
        proxyA.claimReward{value: nativeFee}(distributionId, cumulativeAmountUserA, merkleProof);
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
        ledgerB.setValorEmissionStartTimestamp(block.timestamp + 1);
        test_occ_user_stake();
        vm.warp(block.timestamp + 14 days); // warp time to 1 day later (1 day = 86400 seconds

        console.log("block.timestamp: ");
        console.log(block.timestamp);
        console.log("batch_id: ");
        console.log(ledgerB.getCurrentBatchId());

        for (uint i = 0; i < 12; i++) {
            vm.warp(block.timestamp + 1 days); // warp time to 1 day later (1 day = 86400 seconds)
            ledgerB.dailyUsdcNetFeeRevenueTestNoSignatureCheck(1000);
        }

        console.log("block.timestamp: ");
        console.log(block.timestamp);
        // vm.warp(block.timestamp + 14 days);
        console.log("ledgerB.getCurrentBatchId(): ");
        console.log(ledgerB.getCurrentBatchId());

        uint256 userValor = ledgerB.getUserValor(userA);
        console.log("userValor: ");
        console.log(userValor);
        uint256 redeemAmount = userValor / 2;

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
        vm.warp(block.timestamp + 2 days);
        ledgerB.updateValorVars();
        uint256 totalValorEmitted = ledgerB.getTotalValorEmitted();
        ledgerB.dailyUsdcNetFeeRevenueTestNoSignatureCheck(totalValorEmitted * 2);
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
        uint256 usdcAmount = (redeemedValorAmount * fixedValorToUsdcRateScaled) / 1e27;
        console.log("usdcAmount: ");
        console.log(usdcAmount);

        uint8 opCode = uint8(PayloadDataType.ClaimUsdcRevenue);

        uint256 nativeFee = proxyA.quoteSendUserRequest(claimAmount, userA, opCode);
        vm.prank(userA);
        proxyA.sendUserRequest{value: nativeFee}(claimAmount, opCode);
        verifyPackets(bEid, addressToBytes32(address(bOFT)));

        _deliver_occ_msg(address(proxyA), address(bOFT), address(ledgerOCCManager), aEid, bEid);

        verifyPackets(aEid, addressToBytes32(address(aOFT)));
        _deliver_occ_msg(address(ledgerOCCManager), address(aOFT), address(proxyA), bEid, aEid);
    }

    function test_esorder_lifecycle() public {
        (uint32 distributionId, MerkleTreeHelper.Tree memory tree, uint256[] memory amounts, ) = _createMerkleDistribution(LedgerToken.ESORDER, 1);
        uint256 cumulativeAmountUserA = amounts[0];

        // get proof of userA
        bytes32[] memory merkleProof = MerkleTreeHelper.getProof(tree, 0, 3);

        // Claim user's esOrder reward
        uint256 nativeFee = proxyA.quoteClaimReward(distributionId, userA, cumulativeAmountUserA, merkleProof);
        vm.prank(userA);
        proxyA.claimReward{value: nativeFee}(distributionId, cumulativeAmountUserA, merkleProof);
        verifyPackets(bEid, addressToBytes32(address(bOFT)));
        _deliver_occ_msg(address(proxyA), address(bOFT), address(ledgerOCCManager), aEid, bEid);

        // Unstake user's esOrder and vest them
        _composeAndSendOneWayRequest(uint8(PayloadDataType.EsOrderUnstakeAndVest), 3 ether, userA);

        // Cancel user's vesting request
        _composeAndSendOneWayRequest(uint8(PayloadDataType.CancelVestingRequest), 0, userA);

        // Create new unstake request
        _composeAndSendOneWayRequest(uint8(PayloadDataType.EsOrderUnstakeAndVest), 2 ether, userA);

        //Wait for 15 days
        vm.warp(block.timestamp + 15 days);

        // Check user and order collector balances before claiming vesting request
        uint256 userBalanceBefore = aOFT.balanceOf(userA);
        assertEq(userBalanceBefore, initialBalance);
        uint256 orderCollectorBalanceBefore = bOFT.balanceOf(orderCollectorAddress);
        assertEq(orderCollectorBalanceBefore, 0);

        // Claim user's vesting request with requestId 1
        _composeAndSendTwoWayRequest(uint8(PayloadDataType.ClaimVestingRequest), 1, userA);

        // Check user balance after claiming vesting request (should be half of the vested amount)
        uint256 userBalanceAfter = aOFT.balanceOf(userA);
        assertEq(userBalanceAfter, initialBalance + 1 ether);

        // Unvested Orders should be transferred to the order collector
        uint256 orderCollectorBalanceAfter = bOFT.balanceOf(orderCollectorAddress);
        assertEq(orderCollectorBalanceAfter, 1 ether);
    }

    function test_withdrawTo() public {
        uint256 ethAmount = 1 ether;
        vm.deal(address(proxyA), ethAmount);
        vm.deal(address(ledgerOCCManager), ethAmount);

        proxyA.withdrawTo(address(this));
        ledgerOCCManager.withdrawTo(address(this));
    }
}
