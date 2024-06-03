// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import {IOFT} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/interfaces/IOFT.sol";
import {LedgerToken} from "../lib/OCCTypes.sol";
import {OmnichainLedgerV1} from "../OmnichainLedgerV1.sol";

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
}
