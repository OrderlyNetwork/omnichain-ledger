// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/console.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {IOAppOptionsType3, EnforcedOptionParam} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/libs/OAppOptionsType3.sol";
import {OptionsBuilder} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/libs/OptionsBuilder.sol";
import {IOFT, SendParam, OFTReceipt} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/interfaces/IOFT.sol";
import {MessagingFee, MessagingReceipt} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/OFTCore.sol";
import {OFTMsgCodec} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/libs/OFTMsgCodec.sol";
import {OFTComposeMsgCodec} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/libs/OFTComposeMsgCodec.sol";
import {TestHelperOz5} from "@layerzerolabs/test-devtools-evm-foundry/contracts/TestHelperOz5.sol";

import {LedgerTest} from "../../contracts/test/LedgerTest.sol";
import {OmnichainLedgerV1} from "../../contracts/OmnichainLedgerV1.sol";
import "../../contracts/ProxyLedger.sol";
import "../../contracts/lib/LedgerOCCManager.sol";

import {OFTMock} from "./mocks/OFTMock.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";
import {OappMock} from "./mocks/OappMock.sol";
import {OFTComposerMock} from "./mocks/OFTComposerMock.sol";
import {Base58} from "../utilities/Base58Helper.sol";
import "./MerkleHelper.sol";
import "./TestUtils.sol";

interface ILedgerSolanaEvents {
    event NewSolanaUser(bytes32 indexed solanaAddress, address indexed evmAddress);
    event Staked(uint256 indexed chainedEventId, uint256 indexed chainId, address indexed staker, uint256 amount, LedgerToken token);
    event OrderUnstakeRequested(uint256 indexed chainedEventId, uint256 indexed chainId, address indexed staker, uint256 amount);
    event OrderUnstakeCancelled(uint256 indexed chainedEventId, uint256 indexed chainId, address indexed staker, uint256 pendingOrderAmount);
    event OrderWithdrawn(uint256 indexed chainedEventId, uint256 indexed chainId, address indexed staker, uint256 amount);
    event OrderUnstakeAmountV2(
        uint256 indexed chainedEventId,
        uint256 indexed chainId,
        address indexed staker,
        uint256 totalUnstakedAmount,
        uint256 unlockTimestamp
    );
    event OrderWithdrawnNow(
        uint256 indexed chainedEventId,
        uint256 indexed chainId,
        address indexed staker,
        uint256 withdrawnAmount,
        uint256 collectedAmount
    );
    event RewardsClaimed(
        uint256 indexed chainedEventId,
        uint256 indexed chainId,
        uint32 indexed distributionId,
        address account,
        uint256 amount,
        LedgerToken token
    );
    event OFTSent(bytes32 indexed guid, uint32 dstEid, address indexed fromAddress, uint256 amountSentLD, uint256 amountReceivedLD);
    event EsOrderUnstake(uint256 indexed chainedEventId, uint256 indexed chainId, address indexed staker, uint256 amount);
    event VestingRequested(
        uint256 indexed chainEventId,
        uint256 indexed chainId,
        address indexed user,
        uint256 requestId,
        uint256 amountEsorderRequested,
        uint256 unlockTimestamp
    );
    event VestingCanceled(
        uint256 indexed chainEventId,
        uint256 indexed chainId,
        address indexed user,
        uint256 requestId,
        uint256 amountEsorderStakedBack
    );
    event VestingClaimed(
        uint256 indexed chainEventId,
        uint256 indexed chainId,
        address indexed user,
        uint256 requestId,
        uint256 amountEsorderBurned,
        uint256 amountOrderVested,
        uint256 vestedPeriod
    );
    event ValorRedeemed(uint256 indexed chainEventId, uint256 indexed chainId, address indexed user, uint16 batchId, uint256 valorAmount);
    event UsdcRevenueClaimed(uint256 indexed chainEventId, uint256 indexed chainId, address indexed user, uint256 usdcAmount);
    event LedgerOappSend();
}

contract LedgerSolanaConstants {
    string constant USER_A_SOLANA_ADDRESS_STR = "76y77prsiCMvXMjuoZ5VRrhG5qYBrUMYTE5WgHqgjEn6";
    uint8 constant UNSTAKE_NOW_COLLECT_PERCENT = 5;
    uint256 constant INITIAL_BALANCE = 100 ether;
    uint256 constant ONE_ETH = 1 ether;
    uint256 constant VESTING_LOCK_PERIOD = 7 days;
    address constant ORDER_COLLECTOR_ADDRESS = address(0x3);
}

contract LedgerSolanaTest is TestHelperOz5, LedgerSolanaConstants, ILedgerSolanaEvents {
    uint32 solanaEid = 1;
    uint32 ledgerEid = 2;
    OFTMock aOFT;
    OFTMock bOFT;
    OappMock ledgerOapp;
    LedgerTest omnichainLedger;
    LedgerOCCManager ledgerOCCManager;
    bytes32 userASolanaAddressBytes32;
    address userA;

    function setUp() public virtual override {
        super.setUp();
        setUpEndpoints(2, LibraryType.UltraLightNode);

        aOFT = OFTMock(_deployOApp(type(OFTMock).creationCode, abi.encode("aOFT", "aOFT", address(endpoints[solanaEid]), address(this))));
        bOFT = OFTMock(_deployOApp(type(OFTMock).creationCode, abi.encode("bOFT", "bOFT", address(endpoints[ledgerEid]), address(this))));
        ledgerOapp = new OappMock();

        // config and wire the ofts
        address[] memory ofts = new address[](2);
        ofts[0] = address(aOFT);
        ofts[1] = address(bOFT);
        this.wireOApps(ofts);

        // deploy and initialize upgradeable ledgerOCCManager
        console.log("ledgerOCCManager: ");
        address ledgerOCCManagerImpl = address(new LedgerOCCManager());
        bytes memory ledgerOCCManagerInitBytes = abi.encodeWithSelector(LedgerOCCManager.initialize.selector, address(bOFT), address(this));
        address ledgerOCCManagerProxyAddr = address(new ERC1967Proxy(ledgerOCCManagerImpl, ledgerOCCManagerInitBytes));
        ledgerOCCManager = LedgerOCCManager(payable(ledgerOCCManagerProxyAddr));

        // deploy and initialize upgradeable omnichainLedger
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
        omnichainLedger = LedgerTest(payable(ledgerBProxyAddr));

        ledgerOCCManager.setOrderCollector(ORDER_COLLECTOR_ADDRESS);
        ledgerOCCManager.setLedgerAddr(address(omnichainLedger));
        ledgerOCCManager.setLzEndpoint(endpoints[ledgerEid]);

        ledgerOCCManager.setMyChainId(ledgerEid);

        ledgerOCCManager.setSolanaEid(solanaEid);
        ledgerOCCManager.setChainId2Eid(solanaEid, solanaEid);
        ledgerOCCManager.setLedgerOappAddr(address(ledgerOapp));

        vm.deal(address(ledgerOCCManager), INITIAL_BALANCE);
        bOFT.mint(address(ledgerOCCManager), INITIAL_BALANCE);

        userASolanaAddressBytes32 = TestUtils.bytesToBytes32(Base58.decodeFromString(USER_A_SOLANA_ADDRESS_STR));
        userA = ledgerOCCManager.calculateUserSolana2EvmAddress(userASolanaAddressBytes32);
        vm.deal(userA, INITIAL_BALANCE);
    }

    function _createMerkleDistribution(
        LedgerToken _token,
        uint32 _distributionId
    ) public returns (uint32 distributionId, MerkleTreeHelper.Tree memory tree, uint256[] memory amounts, uint256 totalAmount) {
        bOFT.mint(address(ledgerOCCManager), 10000 ether);
        // userA and userB and address(this)
        address[] memory users = new address[](3);
        users[0] = userA;
        users[1] = ORDER_COLLECTOR_ADDRESS;
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
        omnichainLedger.createDistribution(distributionId, _token, tree.root, timestamp, ipfsCid);
    }

    function buildOccVaultMessage(
        uint256 amount,
        bytes32 senderSolanaAddress,
        PayloadDataType payloadType
    ) internal view returns (OCCVaultMessage memory) {
        return
            OCCVaultMessage({
                chainedEventId: 0,
                srcChainId: solanaEid,
                token: LedgerToken.PLACEHOLDER,
                tokenAmount: 0,
                sender: senderSolanaAddress,
                payloadType: uint8(payloadType),
                payload: abi.encode(amount)
            });
    }

    function test_solana_lzcompose_fail_cases() public {
        // Mock data for Stake payload
        bytes32 guid = bytes32(0);
        OCCVaultMessage memory occVaultMessage = OCCVaultMessage({
            chainedEventId: 0,
            srcChainId: solanaEid,
            token: LedgerToken.ORDER,
            tokenAmount: ONE_ETH,
            sender: userASolanaAddressBytes32,
            payloadType: uint8(PayloadDataType.Stake),
            payload: bytes("")
        });
        bytes memory composeMsg = abi.encode(occVaultMessage);
        bytes memory oftComposeMsg = OFTComposeMsgCodec.encode(0, solanaEid, ONE_ETH, abi.encodePacked(userASolanaAddressBytes32, composeMsg));

        vm.expectRevert("LedgerOCCManager: lzCompose sender check failed");
        ledgerOCCManager.lzCompose(address(bOFT), guid, oftComposeMsg, address(0x1), bytes(""));

        oftComposeMsg = OFTComposeMsgCodec.encode(0, solanaEid, ONE_ETH, abi.encodePacked(bytes32(""), composeMsg));
        vm.prank(endpoints[ledgerEid]);
        vm.expectRevert("LedgerOCCManager: composeMsg sender check failed");
        ledgerOCCManager.lzCompose(address(bOFT), guid, oftComposeMsg, address(0x1), bytes(""));

        occVaultMessage.payloadType = uint8(PayloadDataType.CreateOrderUnstakeRequest);
        composeMsg = abi.encode(occVaultMessage);
        oftComposeMsg = OFTComposeMsgCodec.encode(0, solanaEid, ONE_ETH, abi.encodePacked(userASolanaAddressBytes32, composeMsg));
        vm.prank(endpoints[ledgerEid]);
        vm.expectRevert("LedgerOCCManager: Only Stake payload is supported through Solana OFT channel");
        ledgerOCCManager.lzCompose(address(bOFT), guid, oftComposeMsg, address(0x1), bytes(""));

        occVaultMessage.payloadType = uint8(PayloadDataType.Stake);
        occVaultMessage.tokenAmount = 2 * ONE_ETH;
        composeMsg = abi.encode(occVaultMessage);
        oftComposeMsg = OFTComposeMsgCodec.encode(0, solanaEid, ONE_ETH, abi.encodePacked(userASolanaAddressBytes32, composeMsg));
        vm.prank(endpoints[ledgerEid]);
        vm.expectRevert("LedgerOCCManager: composeMsg stake amount check failed");
        ledgerOCCManager.lzCompose(address(bOFT), guid, oftComposeMsg, address(0x1), bytes(""));

        occVaultMessage.tokenAmount = ONE_ETH;
        occVaultMessage.token = LedgerToken.ESORDER;
        composeMsg = abi.encode(occVaultMessage);
        oftComposeMsg = OFTComposeMsgCodec.encode(0, solanaEid, ONE_ETH, abi.encodePacked(userASolanaAddressBytes32, composeMsg));
        vm.prank(endpoints[ledgerEid]);
        vm.expectRevert("LedgerOCCManager: only ORDER token can be staked");
        ledgerOCCManager.lzCompose(address(bOFT), guid, oftComposeMsg, address(0x1), bytes(""));

        occVaultMessage.token = LedgerToken.ORDER;
        occVaultMessage.srcChainId = ledgerEid;
        composeMsg = abi.encode(occVaultMessage);
        oftComposeMsg = OFTComposeMsgCodec.encode(0, solanaEid, ONE_ETH, abi.encodePacked(userASolanaAddressBytes32, composeMsg));
        vm.prank(endpoints[ledgerEid]);
        vm.expectRevert("LedgerOCCManager: composeMsg srcChainId check failed");
        ledgerOCCManager.lzCompose(address(bOFT), guid, oftComposeMsg, address(0x1), bytes(""));
    }

    function test_solana_stake() public {
        // Mock data for Stake payload
        uint256 amount = 10 ether;
        bytes32 guid = bytes32(0);
        OCCVaultMessage memory occVaultMessage = OCCVaultMessage({
            chainedEventId: 0,
            srcChainId: solanaEid,
            token: LedgerToken.ORDER,
            tokenAmount: amount,
            sender: userASolanaAddressBytes32,
            payloadType: uint8(PayloadDataType.Stake),
            payload: bytes("")
        });
        bytes memory composeMsg = abi.encode(occVaultMessage);
        bytes memory oftComposeMsg = OFTComposeMsgCodec.encode(0, solanaEid, amount, abi.encodePacked(userASolanaAddressBytes32, composeMsg));

        (uint256 userStakeOrderBefore, ) = omnichainLedger.getStakingInfo(userA);

        // Call lzCompose with Stake payload
        uint256 expectedChainedEventId = ledgerOCCManager.solanaChainEventId() + 1;
        vm.prank(endpoints[ledgerEid]);
        if (userStakeOrderBefore == 0) {
            vm.expectEmit(true, true, false, true);
            emit NewSolanaUser(userASolanaAddressBytes32, userA);
        }
        vm.expectEmit(true, true, true, true);
        emit Staked(expectedChainedEventId, solanaEid, userA, amount, LedgerToken.ORDER);

        ledgerOCCManager.lzCompose(address(bOFT), guid, oftComposeMsg, address(0x1), bytes(""));

        // Check if the user stake order is updated correctly
        (uint256 userStakeOrderAfter, ) = omnichainLedger.getStakingInfo(userA);
        assertEq(userStakeOrderAfter - userStakeOrderBefore, amount);
    }

    function test_solana_oapp_receive_fail_cases() public {
        OCCVaultMessage memory occVaultMessage = buildOccVaultMessage(ONE_ETH, userASolanaAddressBytes32, PayloadDataType.CreateOrderUnstakeRequest);
        vm.expectRevert("OnlyLedgerOapp");
        ledgerOCCManager.ledgerOappReceive(occVaultMessage);

        occVaultMessage = buildOccVaultMessage(ONE_ETH, userASolanaAddressBytes32, PayloadDataType.Stake);
        vm.prank(address(ledgerOapp));
        vm.expectRevert("LedgerOCCManager: unsupported payload type");
        ledgerOCCManager.ledgerOappReceive(occVaultMessage);
    }

    function test_solana_create_order_unstake_request() public {
        test_solana_stake();

        (uint256 userStakeOrderBefore, ) = omnichainLedger.getStakingInfo(userA);

        // Mock data for Stake payload
        uint256 expectedChainedEventId = ledgerOCCManager.solanaChainEventId() + 1;
        OCCVaultMessage memory occVaultMessage = buildOccVaultMessage(ONE_ETH, userASolanaAddressBytes32, PayloadDataType.CreateOrderUnstakeRequest);

        vm.prank(address(ledgerOapp));
        vm.expectEmit(true, true, true, true);
        emit OrderUnstakeRequested(expectedChainedEventId, solanaEid, userA, ONE_ETH);
        vm.expectEmit(true, true, true, true);
        emit OrderUnstakeAmountV2(expectedChainedEventId, solanaEid, userA, ONE_ETH, block.timestamp + VESTING_LOCK_PERIOD);
        ledgerOCCManager.ledgerOappReceive(occVaultMessage);

        // Check if the user stake order is updated correctly
        (uint256 userStakeOrderAfter, ) = omnichainLedger.getStakingInfo(userA);
        assertEq(userStakeOrderBefore - userStakeOrderAfter, ONE_ETH);

        (uint256 userPendingUnstake, ) = omnichainLedger.userPendingUnstake(userA);
        assertEq(userPendingUnstake, ONE_ETH);
    }

    function test_solana_cancel_unstake_request() public {
        test_solana_create_order_unstake_request();

        (uint256 userStakeOrderBefore, ) = omnichainLedger.getStakingInfo(userA);
        (uint256 userPendingUnstakeBefore, ) = omnichainLedger.userPendingUnstake(userA);

        // Mock data for Stake payload
        uint256 expectedChainedEventId = ledgerOCCManager.solanaChainEventId() + 1;
        OCCVaultMessage memory occVaultMessage = buildOccVaultMessage(0, userASolanaAddressBytes32, PayloadDataType.CancelOrderUnstakeRequest);

        vm.prank(address(ledgerOapp));
        vm.expectEmit(true, true, true, true);
        emit OrderUnstakeCancelled(expectedChainedEventId, solanaEid, userA, userPendingUnstakeBefore);
        vm.expectEmit(true, true, true, true);
        emit OrderUnstakeAmountV2(expectedChainedEventId, solanaEid, userA, 0, 0);
        ledgerOCCManager.ledgerOappReceive(occVaultMessage);

        // Check if the user stake order is updated correctly
        (uint256 userStakeOrderAfter, ) = omnichainLedger.getStakingInfo(userA);
        assertEq(userStakeOrderBefore + userPendingUnstakeBefore, userStakeOrderAfter);

        (uint256 userPendingUnstakeAfter, ) = omnichainLedger.userPendingUnstake(userA);
        assertEq(0, userPendingUnstakeAfter);
    }

    function test_solana_withdraw_order() public {
        test_solana_create_order_unstake_request();

        uint256 orderAwailableForWithdrawImmediateAfterRequest = omnichainLedger.getOrderAvailableToWithdraw(userA);
        assertEq(orderAwailableForWithdrawImmediateAfterRequest, 0);
        (uint256 userPendingUnstakeBefore, ) = omnichainLedger.userPendingUnstake(userA);

        vm.warp(block.timestamp + 7 days);
        uint256 orderAwailableForWithdrawAfterLockPeriod = omnichainLedger.getOrderAvailableToWithdraw(userA);
        assertEq(orderAwailableForWithdrawAfterLockPeriod, userPendingUnstakeBefore);

        (uint256 userStakeOrderBefore, ) = omnichainLedger.getStakingInfo(userA);

        // Mock data for Stake payload
        uint256 expectedChainedEventId = ledgerOCCManager.solanaChainEventId() + 1;
        OCCVaultMessage memory occVaultMessage = buildOccVaultMessage(0, userASolanaAddressBytes32, PayloadDataType.WithdrawOrder);

        vm.prank(address(ledgerOapp));
        vm.expectEmit(true, true, true, true);
        emit OrderWithdrawn(expectedChainedEventId, solanaEid, userA, orderAwailableForWithdrawAfterLockPeriod);
        vm.expectEmit(true, true, true, true);
        emit OrderUnstakeAmountV2(expectedChainedEventId, solanaEid, userA, 0, 0);
        ledgerOCCManager.ledgerOappReceive(occVaultMessage);

        // Check if the user stake order is updated correctly
        (uint256 userStakeOrderAfter, ) = omnichainLedger.getStakingInfo(userA);
        assertEq(userStakeOrderBefore, userStakeOrderAfter);

        (uint256 userPendingUnstakeAfter, ) = omnichainLedger.userPendingUnstake(userA);
        assertEq(0, userPendingUnstakeAfter);

        uint256 orderAwailableForWithdrawAfterWithdraw = omnichainLedger.getOrderAvailableToWithdraw(userA);
        assertEq(orderAwailableForWithdrawAfterWithdraw, 0);
    }

    function test_solana_unstake_order_now() public {
        test_solana_stake();

        (uint256 userStakeOrderBefore, ) = omnichainLedger.getStakingInfo(userA);

        // Mock data for Stake payload
        uint256 expectedChainedEventId = ledgerOCCManager.solanaChainEventId() + 1;
        uint256 expectedOrderAmountForCollect = (ONE_ETH * UNSTAKE_NOW_COLLECT_PERCENT) / 100;
        uint256 expectedOrderAmountForWithdraw = ONE_ETH - expectedOrderAmountForCollect;
        OCCVaultMessage memory occVaultMessage = buildOccVaultMessage(ONE_ETH, userASolanaAddressBytes32, PayloadDataType.UnstakeOrderNow);

        vm.prank(address(ledgerOapp));
        vm.expectEmit(true, true, true, true);
        emit OrderWithdrawnNow(expectedChainedEventId, solanaEid, userA, expectedOrderAmountForWithdraw, expectedOrderAmountForCollect);
        vm.expectEmit(false, true, true, true);
        emit OFTSent(0, solanaEid, address(ledgerOCCManager), expectedOrderAmountForWithdraw, expectedOrderAmountForWithdraw);
        ledgerOCCManager.ledgerOappReceive(occVaultMessage);

        // Check if the user stake order is updated correctly
        (uint256 userStakeOrderAfter, ) = omnichainLedger.getStakingInfo(userA);
        assertEq(userStakeOrderBefore - userStakeOrderAfter, ONE_ETH);

        (uint256 userPendingUnstake, ) = omnichainLedger.userPendingUnstake(userA);
        assertEq(userPendingUnstake, 0);
    }

    function test_solana_claim_reward_order() public {
        (uint32 distributionId, MerkleTreeHelper.Tree memory tree, uint256[] memory amounts, ) = _createMerkleDistribution(LedgerToken.ORDER, 1);
        uint256 cumulativeAmountUserA = amounts[0];

        bytes memory payload = abi.encode(
            LedgerPayloadTypes.ClaimRewardSolana({distributionId: distributionId, cumulativeAmount: cumulativeAmountUserA, merkleRoot: tree.root})
        );
        OCCVaultMessage memory occVaultMessage = OCCVaultMessage({
            chainedEventId: 0,
            srcChainId: solanaEid,
            token: LedgerToken.PLACEHOLDER,
            tokenAmount: 0,
            sender: userASolanaAddressBytes32,
            payloadType: uint8(PayloadDataType.ClaimRewardSolana),
            payload: payload
        });

        uint256 expectedChainedEventId = ledgerOCCManager.solanaChainEventId() + 1;

        vm.prank(address(ledgerOapp));
        vm.expectEmit(true, true, true, true);
        emit RewardsClaimed(expectedChainedEventId, solanaEid, distributionId, userA, cumulativeAmountUserA, LedgerToken.ORDER);
        vm.expectEmit(false, true, true, true);
        emit OFTSent(0, solanaEid, address(ledgerOCCManager), cumulativeAmountUserA, cumulativeAmountUserA);
        ledgerOCCManager.ledgerOappReceive(occVaultMessage);
    }

    function test_solana_claim_reward_esorder() public {
        (uint32 distributionId, MerkleTreeHelper.Tree memory tree, uint256[] memory amounts, ) = _createMerkleDistribution(LedgerToken.ESORDER, 1);
        uint256 cumulativeAmountUserA = amounts[0];

        bytes memory payload = abi.encode(
            LedgerPayloadTypes.ClaimRewardSolana({distributionId: distributionId, cumulativeAmount: cumulativeAmountUserA, merkleRoot: tree.root})
        );
        OCCVaultMessage memory occVaultMessage = OCCVaultMessage({
            chainedEventId: 0,
            srcChainId: solanaEid,
            token: LedgerToken.PLACEHOLDER,
            tokenAmount: 0,
            sender: userASolanaAddressBytes32,
            payloadType: uint8(PayloadDataType.ClaimRewardSolana),
            payload: payload
        });

        (, uint256 userStakeEsOrderBefore) = omnichainLedger.getStakingInfo(userA);
        uint256 expectedChainedEventId = ledgerOCCManager.solanaChainEventId() + 1;

        vm.prank(address(ledgerOapp));
        vm.expectEmit(true, true, true, true);
        emit RewardsClaimed(expectedChainedEventId, solanaEid, distributionId, userA, cumulativeAmountUserA, LedgerToken.ESORDER);
        vm.expectEmit(true, true, true, true);
        emit Staked(expectedChainedEventId, solanaEid, userA, cumulativeAmountUserA, LedgerToken.ESORDER);
        ledgerOCCManager.ledgerOappReceive(occVaultMessage);

        // Check if the user stake esOrder is updated correctly
        (, uint256 userStakeEsOrderAfter) = omnichainLedger.getStakingInfo(userA);
        assertEq(userStakeEsOrderAfter - userStakeEsOrderBefore, cumulativeAmountUserA);
    }

    function test_solana_esorder_unstake_and_vest() public {
        test_solana_claim_reward_esorder();

        OCCVaultMessage memory occVaultMessage = buildOccVaultMessage(ONE_ETH, userASolanaAddressBytes32, PayloadDataType.EsOrderUnstakeAndVest);

        (, uint256 userStakeEsOrderBefore) = omnichainLedger.getStakingInfo(userA);
        uint256 expectedChainedEventId = ledgerOCCManager.solanaChainEventId() + 1;
        uint256 expectedUnlockTimestamp = block.timestamp + omnichainLedger.vestingLockPeriod();

        vm.prank(address(ledgerOapp));
        vm.expectEmit(true, true, true, true);
        emit EsOrderUnstake(expectedChainedEventId, solanaEid, userA, ONE_ETH);
        vm.expectEmit(true, true, true, true);
        emit VestingRequested(expectedChainedEventId, solanaEid, userA, 0, ONE_ETH, expectedUnlockTimestamp);
        ledgerOCCManager.ledgerOappReceive(occVaultMessage);

        // Check if the user stake esOrder is updated correctly
        (, uint256 userStakeEsOrderAfter) = omnichainLedger.getStakingInfo(userA);
        assertEq(userStakeEsOrderBefore - userStakeEsOrderAfter, ONE_ETH);

        uint256 vestingEsOrderAmount = omnichainLedger.getUserVestingRequests(userA)[0].esOrderAmount;
        assertEq(vestingEsOrderAmount, ONE_ETH);
    }

    function test_solana_cancel_vesting_request() public {
        test_solana_esorder_unstake_and_vest();

        uint256 expectedChainedEventId = ledgerOCCManager.solanaChainEventId() + 1;
        uint256 requestId = 0;
        OCCVaultMessage memory occVaultMessage = buildOccVaultMessage(requestId, userASolanaAddressBytes32, PayloadDataType.CancelVestingRequest);

        (, uint256 userStakeEsOrderBefore) = omnichainLedger.getStakingInfo(userA);
        uint256 vestingEsOrderAmount = omnichainLedger.getUserVestingRequests(userA)[0].esOrderAmount;

        vm.prank(address(ledgerOapp));
        vm.expectEmit(true, true, true, true);
        emit VestingCanceled(expectedChainedEventId, solanaEid, userA, requestId, vestingEsOrderAmount);
        vm.expectEmit(true, true, true, true);
        emit Staked(expectedChainedEventId, solanaEid, userA, vestingEsOrderAmount, LedgerToken.ESORDER);
        ledgerOCCManager.ledgerOappReceive(occVaultMessage);

        // Check if vested esOrder is staked back
        (, uint256 userStakeEsOrderAfter) = omnichainLedger.getStakingInfo(userA);
        assertEq(userStakeEsOrderAfter - userStakeEsOrderBefore, vestingEsOrderAmount);
    }

    function test_solana_claim_vesting_request() public {
        test_solana_esorder_unstake_and_vest();

        uint256 expectedChainedEventId = ledgerOCCManager.solanaChainEventId() + 1;
        uint256 requestId = 0;
        OCCVaultMessage memory occVaultMessage = buildOccVaultMessage(requestId, userASolanaAddressBytes32, PayloadDataType.ClaimVestingRequest);

        uint256 vestingEsOrderAmount = omnichainLedger.getUserVestingRequests(userA)[0].esOrderAmount;

        // Should revert if vesting lock period is not passed
        vm.prank(address(ledgerOapp));
        vm.expectRevert();
        ledgerOCCManager.ledgerOappReceive(occVaultMessage);

        uint256 vestingLockPeriod = omnichainLedger.vestingLockPeriod();
        vm.warp(block.timestamp + vestingLockPeriod);
        vm.prank(address(ledgerOapp));
        vm.expectEmit(true, true, true, true);
        emit VestingClaimed(expectedChainedEventId, solanaEid, userA, requestId, vestingEsOrderAmount, vestingEsOrderAmount / 2, 0);
        vm.expectEmit(false, true, true, true);
        emit OFTSent(0, solanaEid, address(ledgerOCCManager), vestingEsOrderAmount / 2, vestingEsOrderAmount / 2);
        ledgerOCCManager.ledgerOappReceive(occVaultMessage);
    }

    function test_solana_redeem_valor() public {
        test_solana_stake();

        vm.warp(block.timestamp + 2 days);
        uint256 expectedChainedEventId = ledgerOCCManager.solanaChainEventId() + 1;
        uint256 userValorBefore = omnichainLedger.getUserValor(userA);

        OCCVaultMessage memory occVaultMessage = buildOccVaultMessage(userValorBefore, userASolanaAddressBytes32, PayloadDataType.RedeemValor);
        uint16 expectedBatchId = omnichainLedger.getCurrentBatchId();

        vm.prank(address(ledgerOapp));
        vm.expectEmit(true, true, true, true);
        emit ValorRedeemed(expectedChainedEventId, solanaEid, userA, expectedBatchId, userValorBefore);
        ledgerOCCManager.ledgerOappReceive(occVaultMessage);

        uint256 userValorAfter = omnichainLedger.getUserValor(userA);
        assertEq(userValorAfter, 0);
    }

    function test_solana_claim_usdc_revenue() public {
        test_solana_redeem_valor();

        uint256 batchDuration = omnichainLedger.batchDuration();
        vm.warp(block.timestamp + batchDuration);

        omnichainLedger.dailyUsdcNetFeeRevenueTestNoSignatureCheck(1 ether);
        omnichainLedger.batchPreparedToClaim(0);

        OCCVaultMessage memory occVaultMessage = buildOccVaultMessage(0, userASolanaAddressBytes32, PayloadDataType.ClaimUsdcRevenue);

        uint256 expectedChainedEventId = ledgerOCCManager.solanaChainEventId() + 1;
        vm.prank(address(ledgerOapp));
        vm.expectEmit(true, true, true, true);
        emit UsdcRevenueClaimed(expectedChainedEventId, solanaEid, userA, 1 ether);
        vm.expectEmit(false, true, true, true);
        emit LedgerOappSend();
        ledgerOCCManager.ledgerOappReceive(occVaultMessage);
    }
}
