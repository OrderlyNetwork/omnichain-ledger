// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import {IOFT} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/interfaces/IOFT.sol";
import {LedgerToken} from "../lib/OCCTypes.sol";
import {OmnichainLedgerV1} from "../OmnichainLedgerV1.sol";
import {LedgerSignedTypes} from "../lib/LedgerTypes.sol";
import {Signature} from "../lib/Signature.sol";

contract OmnichainLedgerTestV1 is OmnichainLedgerV1 {
    function setBatchDuration(uint256 _batchDuration) external {
        batchDuration = _batchDuration;
    }

    function setUnstakeLockPeriod(uint256 _unstakeLockPeriod) external {
        unstakeLockPeriod = _unstakeLockPeriod;
    }

    function setVestingLockPeriod(uint256 _vestingLockPeriod) external {
        vestingLockPeriod = _vestingLockPeriod;
    }

    function setVestingLinearPeriod(uint256 _vestingLinearPeriod) external {
        vestingLinearPeriod = _vestingLinearPeriod;
    }

    function dailyUsdcNetFeeRevenueTestNoSignatureCheck(uint256 _usdcNetFeeRevenue, uint256 _timestamp) public onlyRole(TREASURE_UPDATER_ROLE) {
        _dailyUsdcNetFeeRevenueTest(_usdcNetFeeRevenue, _timestamp);
    }

    function dailyUsdcNetFeeRevenueTestNoTimeCheck(LedgerSignedTypes.UintValueData calldata data) external onlyRole(TREASURE_UPDATER_ROLE) {
        Signature.verifyUintValueSignature(data, usdcUpdaterAddress);
        _dailyUsdcNetFeeRevenueTest(data.value, data.timestamp);
    }

    function _dailyUsdcNetFeeRevenueTest(uint256 _usdcNetFeeRevenue, uint256 _timestamp) public onlyRole(TREASURE_UPDATER_ROLE) {
        lastUsdcNetFeeRevenueUpdateTimestamp = block.timestamp;
        totalUsdcInTreasure += _usdcNetFeeRevenue;
        _updateValorToUsdcRateScaled();
        emit DailyUsdcNetFeeRevenueUpdated(_timestamp, _usdcNetFeeRevenue, totalUsdcInTreasure, getTotalValorAmount(), valorToUsdcRateScaled);
        _possiblyFixBatchValorToUsdcRateForPreviousBatch();
    }
}
