import { expect } from "chai";
import { anyValue } from "@nomicfoundation/hardhat-chai-matchers/withArgs";
import * as helpers from "@nomicfoundation/hardhat-network-helpers";
import { CHAIN_ID_0, ONE_DAY_IN_SECONDS, USER_STAKE_AMOUNT, VALOR_CHECK_PRECISION, amountCloseTo, ledgerFixture } from "./utilities/index";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";

import { LedgerTest } from "../types/contracts/test";

describe("Vesting", function () {
  async function claimAndCheckVestingRequest(
    ledger: LedgerTest,
    user: HardhatEthersSigner,
    CHAIN_ID_0: number,
    requestId: number,
    vestingAmounts: BigInt[]
  ) {
    await expect(ledger.connect(user).claimVestingRequest(user.address, CHAIN_ID_0, requestId))
      .to.emit(ledger, "VestingClaimed")
      .withArgs(anyValue, CHAIN_ID_0, user.address, requestId, vestingAmounts[requestId], vestingAmounts[requestId], anyValue);
  }

  it("check vesting initial state", async function () {
    const { ledger, user } = await ledgerFixture();

    expect(await ledger.vestingLockPeriod()).to.equal(15 * ONE_DAY_IN_SECONDS);
    expect(await ledger.vestingLinearPeriod()).to.equal(75 * ONE_DAY_IN_SECONDS);
    await expect(ledger.calculateVestingOrderAmount(user.address, 0)).to.be.revertedWithCustomError(ledger, "UserDontHaveVestingRequest");
  });

  it("user can request vesting and contract correctly calculates VestingOrderAmount over time", async function () {
    const { ledger, user } = await ledgerFixture();

    const vestingAmount = USER_STAKE_AMOUNT;
    await expect(ledger.connect(user).createVestingRequest(user.address, CHAIN_ID_0, vestingAmount))
      .to.emit(ledger, "VestingRequested")
      .withArgs(1, CHAIN_ID_0, user.address, 0, vestingAmount, anyValue);

    const userVestingRequests = await ledger.getUserVestingRequests(user.address);
    expect(userVestingRequests.length).to.equal(1);
    expect(userVestingRequests[0]["requestId"]).to.equal(0);
    expect(userVestingRequests[0]["esOrderAmount"]).to.equal(vestingAmount);
    expect(await ledger.calculateVestingOrderAmount(user.address, 0)).to.equal(0);

    const vestingStartTime = await helpers.time.latest();
    // After 15 days, the user can withdraw half of the vesting amount
    await helpers.time.increaseTo(vestingStartTime + ONE_DAY_IN_SECONDS * 15);
    expect(await ledger.calculateVestingOrderAmount(user.address, 0)).to.be.equal(vestingAmount / BigInt(2));

    // After half of the linear vesting period, the user can withdraw 3 / 4 of the vesting amount
    await helpers.time.increaseTo(vestingStartTime + ONE_DAY_IN_SECONDS * 15 + (ONE_DAY_IN_SECONDS * 75) / 2);
    expect(await ledger.calculateVestingOrderAmount(user.address, 0)).to.be.equal((vestingAmount * BigInt(3)) / BigInt(4));

    // After the linear vesting period, the user can withdraw the full vesting amount
    await helpers.time.increaseTo(vestingStartTime + ONE_DAY_IN_SECONDS * 90);
    expect(await ledger.calculateVestingOrderAmount(user.address, 0)).to.be.equal(vestingAmount);
  });

  it("user can cancel vesting request", async function () {
    const { ledger, user } = await ledgerFixture();

    const vestingAmount = USER_STAKE_AMOUNT;
    await ledger.connect(user).createVestingRequest(user.address, CHAIN_ID_0, vestingAmount);

    await expect(ledger.connect(user).cancelVestingRequest(user.address, CHAIN_ID_0, 0))
      .to.emit(ledger, "VestingCanceled")
      .withArgs(anyValue, CHAIN_ID_0, user.address, 0, vestingAmount);

    await expect(ledger.calculateVestingOrderAmount(user.address, 0)).to.be.revertedWithCustomError(ledger, "UserDontHaveVestingRequest");
  });

  it("user can cancel all vesting requests", async function () {
    const { ledger, user } = await ledgerFixture();

    const vestingAmount = USER_STAKE_AMOUNT;
    await ledger.connect(user).createVestingRequest(user.address, CHAIN_ID_0, vestingAmount);
    await ledger.connect(user).createVestingRequest(user.address, CHAIN_ID_0, vestingAmount);

    // Both requests can be calculated, so, they are created
    expect(await ledger.connect(user).calculateVestingOrderAmount(user.address, 0)).to.be.equal(0);
    expect(await ledger.connect(user).calculateVestingOrderAmount(user.address, 1)).to.be.equal(0);

    const tx = await ledger.connect(user).cancelAllVestingRequests(user.address, CHAIN_ID_0);
    await expect(tx).to.emit(ledger, "VestingCanceled").withArgs(anyValue, CHAIN_ID_0, user.address, 0, vestingAmount);
    await expect(tx).to.emit(ledger, "VestingCanceled").withArgs(anyValue, CHAIN_ID_0, user.address, 1, vestingAmount);

    // After canceling all requests, they can't be calculated
    await expect(ledger.calculateVestingOrderAmount(user.address, 0)).to.be.revertedWithCustomError(ledger, "UserDontHaveVestingRequest");
    await expect(ledger.calculateVestingOrderAmount(user.address, 1)).to.be.revertedWithCustomError(ledger, "UserDontHaveVestingRequest");
  });

  it("user can claim vesting request after lock period", async function () {
    const { ledger, user } = await ledgerFixture();

    const vestingAmount = USER_STAKE_AMOUNT;
    await ledger.connect(user).createVestingRequest(user.address, CHAIN_ID_0, vestingAmount);

    // User can't claim the vesting request before the lock period passes
    await expect(ledger.connect(user).claimVestingRequest(user.address, CHAIN_ID_0, 0)).to.be.revertedWithCustomError(
      ledger,
      "VestingLockPeriodNotPassed"
    );

    const vestingStartTime = await helpers.time.latest();
    await helpers.time.increaseTo(vestingStartTime + ONE_DAY_IN_SECONDS * 15);

    await expect(ledger.connect(user).claimVestingRequest(user.address, CHAIN_ID_0, 0))
      .to.emit(ledger, "VestingClaimed")
      .withArgs(anyValue, CHAIN_ID_0, user.address, 0, vestingAmount, amountCloseTo(vestingAmount / BigInt(2), VALOR_CHECK_PRECISION), 2);

    await expect(ledger.calculateVestingOrderAmount(user.address, 0)).to.be.revertedWithCustomError(ledger, "UserDontHaveVestingRequest");
  });

  it("vested amount is correctly calculated", async function () {
    const { ledger, user } = await ledgerFixture();

    const vestingAmount = USER_STAKE_AMOUNT;
    await ledger.connect(user).createVestingRequest(user.address, CHAIN_ID_0, vestingAmount);

    const vestingStartTime = await helpers.time.latest();
    await helpers.time.increaseTo(vestingStartTime + ONE_DAY_IN_SECONDS * 15);

    expect(await ledger.calculateVestingOrderAmount(user.address, 0)).to.be.equal(vestingAmount / BigInt(2));

    await helpers.time.increaseTo(vestingStartTime + ONE_DAY_IN_SECONDS * 15 + (ONE_DAY_IN_SECONDS * 75) / 2);
    expect(await ledger.calculateVestingOrderAmount(user.address, 0)).to.be.equal((vestingAmount * BigInt(3)) / BigInt(4));

    await helpers.time.increaseTo(vestingStartTime + ONE_DAY_IN_SECONDS * 90);
    expect(await ledger.calculateVestingOrderAmount(user.address, 0)).to.be.equal(vestingAmount);
  });

  it("check that cancel vesting request removes right request", async function () {
    const { ledger, user } = await ledgerFixture();

    const vestingAmounts = [USER_STAKE_AMOUNT, USER_STAKE_AMOUNT * BigInt(2), USER_STAKE_AMOUNT * BigInt(3), USER_STAKE_AMOUNT * BigInt(4)];

    // Create requests with different amounts
    for (let i = 0; i < 4; i++) {
      await expect(ledger.connect(user).createVestingRequest(user.address, CHAIN_ID_0, vestingAmounts[i]))
        .to.emit(ledger, "VestingRequested")
        .withArgs(anyValue, CHAIN_ID_0, user.address, i, vestingAmounts[i], anyValue);
    }

    // Remocve the first request
    await expect(ledger.connect(user).cancelVestingRequest(user.address, CHAIN_ID_0, 0))
      .to.emit(ledger, "VestingCanceled")
      .withArgs(anyValue, CHAIN_ID_0, user.address, 0, vestingAmounts[0]);

    // Check full vesting period
    const vestingStartTime = await helpers.time.latest();
    await helpers.time.increaseTo(vestingStartTime + ONE_DAY_IN_SECONDS * 90);

    // Claim second request
    await claimAndCheckVestingRequest(ledger, user, CHAIN_ID_0, 1, vestingAmounts);

    // Check that cancelled and claimed requests removed
    await expect(ledger.calculateVestingOrderAmount(user.address, 0)).to.be.revertedWithCustomError(ledger, "UserDontHaveVestingRequest");
    await expect(ledger.calculateVestingOrderAmount(user.address, 1)).to.be.revertedWithCustomError(ledger, "UserDontHaveVestingRequest");

    // Claim last requests
    await claimAndCheckVestingRequest(ledger, user, CHAIN_ID_0, 3, vestingAmounts);
    await claimAndCheckVestingRequest(ledger, user, CHAIN_ID_0, 2, vestingAmounts);
  });

  it("Vesting: pause should fail functions, that requires unpaused state", async function () {
    const { ledger, owner, user } = await ledgerFixture();

    await ledger.connect(owner).pause();
    await expect(ledger.connect(user).createVestingRequest(user.address, 0, 1000)).to.be.revertedWithCustomError(ledger, "EnforcedPause");
    await expect(ledger.connect(user).cancelVestingRequest(user.address, 0, 0)).to.be.revertedWithCustomError(ledger, "EnforcedPause");
    await expect(ledger.connect(user).cancelAllVestingRequests(user.address, 0)).to.be.revertedWithCustomError(ledger, "EnforcedPause");
    await expect(ledger.connect(user).claimVestingRequest(user.address, 0, 0)).to.be.revertedWithCustomError(ledger, "EnforcedPause");
  });
});
