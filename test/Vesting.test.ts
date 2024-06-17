import { expect } from "chai";
import { anyValue } from "@nomicfoundation/hardhat-chai-matchers/withArgs";
import * as helpers from "@nomicfoundation/hardhat-network-helpers";
import { ONE_DAY_IN_SECONDS, ledgerFixture } from "./utilities/index";
import { Contract } from "ethers";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";

describe("Vesting", function () {
  async function vestingFixture() {
    const { ledger, orderTokenOft, owner, user, updater, operator } = await ledgerFixture();
    return { ledger, orderTokenOft, owner, user, updater, operator };
  }

  async function claimAndCheckVestingRequest(
    ledger: Contract,
    user: HardhatEthersSigner,
    chainId: number,
    requestId: number,
    vestingAmounts: number[]
  ) {
    await expect(ledger.connect(user).claimVestingRequest(user.address, chainId, requestId))
      .to.emit(ledger, "VestingClaimed")
      .withArgs(anyValue, chainId, user.address, requestId, vestingAmounts[requestId], vestingAmounts[requestId], anyValue);
  }

  it("check vesting initial state", async function () {
    const { ledger, orderTokenOft, owner, user, updater, operator } = await vestingFixture();

    expect(await ledger.vestingLockPeriod()).to.equal(15 * ONE_DAY_IN_SECONDS);
    expect(await ledger.vestingLinearPeriod()).to.equal(75 * ONE_DAY_IN_SECONDS);
    await expect(ledger.calculateVestingOrderAmount(user.address, 0)).to.be.revertedWithCustomError(ledger, "UserDontHaveVestingRequest");
  });

  it("user can request vesting and contract correctly calculates VestingOrderAmount over time", async function () {
    const { ledger, orderTokenOft, owner, user, updater, operator } = await vestingFixture();

    const chainId = 0;
    const vestingAmount = 1000;
    await expect(ledger.connect(user).createVestingRequest(user.address, chainId, vestingAmount))
      .to.emit(ledger, "VestingRequested")
      .withArgs(1, chainId, user.address, 0, vestingAmount, anyValue);

    const userVestingRequests = await ledger.getUserVestingRequests(user.address);
    expect(userVestingRequests.length).to.equal(1);
    expect(userVestingRequests[0]["requestId"]).to.equal(0);
    expect(userVestingRequests[0]["esOrderAmount"]).to.equal(vestingAmount);
    expect(await ledger.calculateVestingOrderAmount(user.address, 0)).to.equal(0);

    const vestingStartTime = await helpers.time.latest();
    // After 15 days, the user can withdraw half of the vesting amount
    await helpers.time.increaseTo(vestingStartTime + ONE_DAY_IN_SECONDS * 15);
    expect(await ledger.calculateVestingOrderAmount(user.address, 0)).to.be.equal(vestingAmount / 2);

    // After half of the linear vesting period, the user can withdraw 3 / 4 of the vesting amount
    await helpers.time.increaseTo(vestingStartTime + ONE_DAY_IN_SECONDS * 15 + (ONE_DAY_IN_SECONDS * 75) / 2);
    expect(await ledger.calculateVestingOrderAmount(user.address, 0)).to.be.equal((vestingAmount * 3) / 4);

    // After the linear vesting period, the user can withdraw the full vesting amount
    await helpers.time.increaseTo(vestingStartTime + ONE_DAY_IN_SECONDS * 90);
    expect(await ledger.calculateVestingOrderAmount(user.address, 0)).to.be.equal(vestingAmount);
  });

  it("user can cancel vesting request", async function () {
    const { ledger, orderTokenOft, owner, user, updater, operator } = await vestingFixture();

    const chainId = 0;
    const vestingAmount = 1000;
    await ledger.connect(user).createVestingRequest(user.address, chainId, vestingAmount);

    await expect(ledger.connect(user).cancelVestingRequest(user.address, chainId, 0))
      .to.emit(ledger, "VestingCanceled")
      .withArgs(anyValue, chainId, user.address, 0, vestingAmount);

    await expect(ledger.calculateVestingOrderAmount(user.address, 0)).to.be.revertedWithCustomError(ledger, "UserDontHaveVestingRequest");
  });

  it("user can cancel all vesting requests", async function () {
    const { ledger, orderTokenOft, owner, user, updater, operator } = await vestingFixture();

    const chainId = 0;
    const vestingAmount = 1000;
    await ledger.connect(user).createVestingRequest(user.address, chainId, vestingAmount);
    await ledger.connect(user).createVestingRequest(user.address, chainId, vestingAmount);

    // Both requests can be calculated, so, they are created
    expect(await ledger.connect(user).calculateVestingOrderAmount(user.address, 0)).to.be.equal(0);
    expect(await ledger.connect(user).calculateVestingOrderAmount(user.address, 1)).to.be.equal(0);

    const tx = await ledger.connect(user).cancelAllVestingRequests(user.address, chainId);
    await expect(tx).to.emit(ledger, "VestingCanceled").withArgs(anyValue, chainId, user.address, 0, vestingAmount);
    await expect(tx).to.emit(ledger, "VestingCanceled").withArgs(anyValue, chainId, user.address, 1, vestingAmount);

    // After canceling all requests, they can't be calculated
    await expect(ledger.calculateVestingOrderAmount(user.address, 0)).to.be.revertedWithCustomError(ledger, "UserDontHaveVestingRequest");
    await expect(ledger.calculateVestingOrderAmount(user.address, 1)).to.be.revertedWithCustomError(ledger, "UserDontHaveVestingRequest");
  });

  it("user can claim vesting request after lock period", async function () {
    const { ledger, orderTokenOft, owner, user, updater, operator } = await vestingFixture();

    const chainId = 0;
    const vestingAmount = 1000;
    await ledger.connect(user).createVestingRequest(user.address, chainId, vestingAmount);

    // User can't claim the vesting request before the lock period passes
    await expect(ledger.connect(user).claimVestingRequest(user.address, chainId, 0)).to.be.revertedWithCustomError(
      ledger,
      "VestingLockPeriodNotPassed"
    );

    const vestingStartTime = await helpers.time.latest();
    await helpers.time.increaseTo(vestingStartTime + ONE_DAY_IN_SECONDS * 15);

    await expect(ledger.connect(user).claimVestingRequest(user.address, chainId, 0))
      .to.emit(ledger, "VestingClaimed")
      .withArgs(anyValue, chainId, user.address, 0, vestingAmount, vestingAmount / 2, 2);

    await expect(ledger.calculateVestingOrderAmount(user.address, 0)).to.be.revertedWithCustomError(ledger, "UserDontHaveVestingRequest");
  });

  it("vested amount is correctly calculated", async function () {
    const { ledger, orderTokenOft, owner, user, updater, operator } = await vestingFixture();

    const chainId = 0;
    const vestingAmount = 1000;
    await ledger.connect(user).createVestingRequest(user.address, chainId, vestingAmount);

    const vestingStartTime = await helpers.time.latest();
    await helpers.time.increaseTo(vestingStartTime + ONE_DAY_IN_SECONDS * 15);

    expect(await ledger.calculateVestingOrderAmount(user.address, 0)).to.be.equal(vestingAmount / 2);

    await helpers.time.increaseTo(vestingStartTime + ONE_DAY_IN_SECONDS * 15 + (ONE_DAY_IN_SECONDS * 75) / 2);
    expect(await ledger.calculateVestingOrderAmount(user.address, 0)).to.be.equal((vestingAmount * 3) / 4);

    await helpers.time.increaseTo(vestingStartTime + ONE_DAY_IN_SECONDS * 90);
    expect(await ledger.calculateVestingOrderAmount(user.address, 0)).to.be.equal(vestingAmount);
  });

  it("check that cancel vesting request removes right request", async function () {
    const { ledger, orderTokenOft, owner, user, updater, operator } = await vestingFixture();

    const chainId = 0;
    const vestingAmounts = [1000, 2000, 3000, 4000];

    // Create requests with different amounts
    for (let i = 0; i < 4; i++) {
      await expect(ledger.connect(user).createVestingRequest(user.address, chainId, vestingAmounts[i]))
        .to.emit(ledger, "VestingRequested")
        .withArgs(anyValue, chainId, user.address, i, vestingAmounts[i], anyValue);
    }

    // Remocve the first request
    await expect(ledger.connect(user).cancelVestingRequest(user.address, chainId, 0))
      .to.emit(ledger, "VestingCanceled")
      .withArgs(anyValue, chainId, user.address, 0, vestingAmounts[0]);

    // Check full vesting period
    const vestingStartTime = await helpers.time.latest();
    await helpers.time.increaseTo(vestingStartTime + ONE_DAY_IN_SECONDS * 90);

    // Claim second request
    await claimAndCheckVestingRequest(ledger, user, chainId, 1, vestingAmounts);

    // Check that cancelled and claimed requests removed
    await expect(ledger.calculateVestingOrderAmount(user.address, 0)).to.be.revertedWithCustomError(ledger, "UserDontHaveVestingRequest");
    await expect(ledger.calculateVestingOrderAmount(user.address, 1)).to.be.revertedWithCustomError(ledger, "UserDontHaveVestingRequest");

    // Claim last requests
    await claimAndCheckVestingRequest(ledger, user, chainId, 3, vestingAmounts);
    await claimAndCheckVestingRequest(ledger, user, chainId, 2, vestingAmounts);
  });

  it("Vesting: pause should fail functions, that requires unpaused state", async function () {
    const { ledger, orderTokenOft, owner, user, updater, operator } = await vestingFixture();

    await ledger.connect(owner).pause();
    await expect(ledger.connect(user).createVestingRequest(user.address, 0, 1000)).to.be.revertedWithCustomError(ledger, "EnforcedPause");
    await expect(ledger.connect(user).cancelVestingRequest(user.address, 0, 0)).to.be.revertedWithCustomError(ledger, "EnforcedPause");
    await expect(ledger.connect(user).cancelAllVestingRequests(user.address, 0)).to.be.revertedWithCustomError(ledger, "EnforcedPause");
    await expect(ledger.connect(user).claimVestingRequest(user.address, 0, 0)).to.be.revertedWithCustomError(ledger, "EnforcedPause");
  });
});
