import { Contract } from "ethers";
import { expect } from "chai";
import { anyValue } from "@nomicfoundation/hardhat-chai-matchers/withArgs";
import * as helpers from "@nomicfoundation/hardhat-network-helpers";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";

import { LedgerTest } from "../types/contracts/test";
import { LedgerToken, ledgerFixture, checkUserStakingBalance, checkUserPendingUnstake, ONE_DAY_IN_SECONDS, ONE_WEEK_IN_SECONDS, VALOR_PER_DAY, VALOR_PER_SECOND, CHAIN_ID_0, USER_STAKE_AMOUNT, userStakedAndValorEmissionStarted, VALOR_CHECK_PRECISION, waitForEmissionStart } from "./utilities/index";

describe("Staking", function () {
  async function makeInitialStake(
    ledger: LedgerTest,
    chainId: number,
    user: SignerWithAddress,
    orderStakingAmount: BigInt,
    esOrderStakingAmount: BigInt
  ) {
    if (orderStakingAmount.valueOf() > 0) {
      await ledger.connect(user).stake(user.address, chainId, LedgerToken.ORDER, orderStakingAmount.valueOf());
    }
    if (esOrderStakingAmount.valueOf() > 0) {
      await ledger.connect(user).stake(user.address, chainId, LedgerToken.ESORDER, esOrderStakingAmount.valueOf());
    }
    await checkUserStakingBalance(ledger, user, orderStakingAmount, esOrderStakingAmount);
  }

  it("check staking initial state", async function () {
    const { ledger, user } = await ledgerFixture();

    expect(await ledger.totalStakedAmount()).to.equal(0);
    expect(await ledger.accValorPerShareScaled()).to.equal(0);
    expect(await ledger.unstakeLockPeriod()).to.equal(ONE_WEEK_IN_SECONDS);
    expect(await ledger.userTotalStakingBalance(user.address)).to.equal(0);
    expect(await ledger.getOrderAvailableToWithdraw(user.address)).to.equal(0);
    expect(await ledger.getUserValor(user.address)).to.equal(0);
  });

  it("user can stake order tokens", async function () {
    const { ledger, user } = await ledgerFixture();
    const tx = await ledger.connect(user).stake(user.address, CHAIN_ID_0, LedgerToken.ORDER, USER_STAKE_AMOUNT);
    // Check the Staked event is emitted correctly
    await expect(tx).to.emit(ledger, "Staked").withArgs(anyValue, CHAIN_ID_0, user.address, USER_STAKE_AMOUNT, LedgerToken.ORDER);

    expect(await ledger.totalStakedAmount()).to.equal(USER_STAKE_AMOUNT);
    expect(await ledger.userTotalStakingBalance(user.address)).to.equal(USER_STAKE_AMOUNT);
    expect(await ledger.getOrderAvailableToWithdraw(user.address)).to.equal(0);
    expect(await ledger.getUserValor(user.address)).to.equal(0);
  });

  it("user stake should produce valor", async function () {
    const { ledger, user } = await userStakedAndValorEmissionStarted();

    await helpers.time.increase(ONE_DAY_IN_SECONDS);
    // Only one user staked, so user receives all valor emission for the day.
    expect(await ledger.getUserValor(user.address)).to.closeTo(VALOR_PER_DAY, VALOR_CHECK_PRECISION);
    expect(await ledger.getTotalValorAmount()).closeTo(VALOR_PER_DAY, VALOR_CHECK_PRECISION);

    // Check that updateValorVars emit valor
    await ledger.updateValorVars();
    expect(await ledger.getTotalValorEmittedStoreValue()).closeTo(VALOR_PER_DAY, VALOR_CHECK_PRECISION);
  });

  it("unstake request should stop valor emission for user", async function () {
    const { ledger, owner, user } = await ledgerFixture();

    await ledger.connect(user).stake(user.address, CHAIN_ID_0, LedgerToken.ORDER, USER_STAKE_AMOUNT);
    await ledger.connect(owner).stake(owner.address, CHAIN_ID_0, LedgerToken.ORDER, USER_STAKE_AMOUNT);

    await waitForEmissionStart(ledger);
    await helpers.time.increase(ONE_DAY_IN_SECONDS);
    // Two users staked equal amount in total, so they should receive the same amount of valor.
    // But they can be a bit greater due to a bit of time pass before checking the valor.
    expect(await ledger.getUserValor(user.address)).to.equal(VALOR_PER_DAY / BigInt(2));
    expect(await ledger.getUserValor(owner.address)).to.equal(VALOR_PER_DAY / BigInt(2));

    expect(await ledger.getTotalValorEmitted()).to.equal(VALOR_PER_DAY);
    expect(await ledger.getTotalValorAmount()).to.equal(VALOR_PER_DAY);

    // Real emission requires active call
    expect(await ledger.getTotalValorEmittedStoreValue()).to.equal(0);

    await ledger.connect(user).createOrderUnstakeRequest(user.address, CHAIN_ID_0, USER_STAKE_AMOUNT);

    // Check that createOrderUnstakeRequest emit valor
    expect(await ledger.getTotalValorEmittedStoreValue()).closeTo(VALOR_PER_DAY, VALOR_CHECK_PRECISION);

    await helpers.time.increase(ONE_DAY_IN_SECONDS);
    // Unstake request should stop valor emission for user, but not for others
    expect(await ledger.getUserValor(user.address)).to.closeTo(VALOR_PER_DAY / BigInt(2), VALOR_CHECK_PRECISION);
    // So, owner should receive all valor emission for the day.
    expect(await ledger.getUserValor(owner.address)).to.closeTo(VALOR_PER_DAY / BigInt(2) + VALOR_PER_DAY, VALOR_CHECK_PRECISION);

    //Cancel unstake request should resume valor emission
    await ledger.connect(user).cancelOrderUnstakeRequest(user.address, CHAIN_ID_0);
    await helpers.time.increase(ONE_DAY_IN_SECONDS);

    // Dayly valor emission should be again divided between two users
    expect(await ledger.getUserValor(user.address)).to.closeTo(VALOR_PER_DAY, VALOR_CHECK_PRECISION);
    expect(await ledger.getUserValor(owner.address)).to.closeTo(VALOR_PER_DAY * BigInt(2), VALOR_CHECK_PRECISION);
  });

  it("users share valor emission according to their stake", async function () {
    const { ledger, owner, user, updater } = await ledgerFixture();

    // $ORDER and es$ORDER should be counted as well
    await ledger.connect(user).stake(user.address, CHAIN_ID_0, LedgerToken.ORDER, USER_STAKE_AMOUNT / BigInt(2));
    await ledger.connect(user).stake(user.address, CHAIN_ID_0, LedgerToken.ESORDER, USER_STAKE_AMOUNT / BigInt(2));
    await ledger.connect(updater).stake(updater.address, CHAIN_ID_0, LedgerToken.ORDER, USER_STAKE_AMOUNT);
    await ledger.connect(owner).stake(owner.address, CHAIN_ID_0, LedgerToken.ESORDER, USER_STAKE_AMOUNT);

    await waitForEmissionStart(ledger);
    await helpers.time.increase(ONE_DAY_IN_SECONDS);
    // Three users staked equal amount in total, so they should receive the same amount of valor.
    // But they can be a bit greater due to a bit of time difference between user stakes.
    expect(await ledger.getUserValor(user.address)).to.closeTo(VALOR_PER_DAY / BigInt(3), VALOR_CHECK_PRECISION);
    expect(await ledger.getUserValor(updater.address)).to.closeTo(VALOR_PER_DAY / BigInt(3), VALOR_CHECK_PRECISION);
    expect(await ledger.getUserValor(owner.address)).to.closeTo(VALOR_PER_DAY / BigInt(3), VALOR_CHECK_PRECISION);
  });

  it("user can make unstake request for orders", async function () {
    const { ledger, user } = await ledgerFixture();

    // User can't create unstake request if they don't have any staked orders
    await expect(ledger.connect(user).createOrderUnstakeRequest(user.address, 0, 1000))
      .to.be.revertedWithCustomError(ledger, "StakingBalanceInsufficient")
      .withArgs(LedgerToken.ORDER);

    const orderStakingAmount = USER_STAKE_AMOUNT;
    const esOrderStakingAmount = USER_STAKE_AMOUNT;
    const orderUnstakingAmount = USER_STAKE_AMOUNT / BigInt(2);
    await makeInitialStake(ledger, CHAIN_ID_0, user, orderStakingAmount, esOrderStakingAmount);

    // Attempt to withdraw before unstaking should fail
    await expect(ledger.connect(user).withdrawOrder(user.address, CHAIN_ID_0)).to.be.revertedWithCustomError(ledger, "NoPendingUnstakeRequest");

    // User can't create unstake request for zero amount
    await expect(ledger.connect(user).createOrderUnstakeRequest(user.address, CHAIN_ID_0, 0)).to.be.revertedWithCustomError(ledger, "AmountIsZero");

    // User can't create unstake request for more than they have
    await expect(ledger.connect(user).createOrderUnstakeRequest(user.address, CHAIN_ID_0, orderStakingAmount + BigInt(1)))
      .to.be.revertedWithCustomError(ledger, "StakingBalanceInsufficient")
      .withArgs(LedgerToken.ORDER);

    // User make unstake request
    const tx1 = await ledger.connect(user).createOrderUnstakeRequest(user.address, CHAIN_ID_0, orderUnstakingAmount);
    const unlockTimestamp = (await helpers.time.latest()) + ONE_WEEK_IN_SECONDS;
    // Check the OrderUnstakeRequested event is emitted correctly
    await expect(tx1).to.emit(ledger, "OrderUnstakeRequested").withArgs(anyValue, CHAIN_ID_0, user.address, orderUnstakingAmount);
    await expect(tx1).to.emit(ledger, "OrderUnstakeAmount").withArgs(user.address, orderUnstakingAmount, unlockTimestamp);

    await checkUserStakingBalance(ledger, user, orderStakingAmount - orderUnstakingAmount, esOrderStakingAmount);
    await checkUserPendingUnstake(ledger, user, orderUnstakingAmount, (await helpers.time.latest()) + 7 * ONE_DAY_IN_SECONDS);

    // Pending unstake should not be available to withdraw
    expect(await ledger.getOrderAvailableToWithdraw(user.address)).to.equal(0);

    // Attempt to withdraw unstaked orders before unlock period should fail
    await expect(ledger.connect(user).withdrawOrder(user.address, CHAIN_ID_0)).to.be.revertedWithCustomError(ledger, "UnlockTimeNotPassedYet");

    // After locking period, user should be able to withdraw orders
    await helpers.time.increase(7 * ONE_DAY_IN_SECONDS);
    expect(await ledger.getOrderAvailableToWithdraw(user.address)).to.equal(orderUnstakingAmount);

    // Now user should be able to withdraw orders
    const tx2 = await ledger.connect(user).withdrawOrder(user.address, CHAIN_ID_0);
    // Check the OrderWithdrawn event is emitted correctly
    await expect(tx2).to.emit(ledger, "OrderWithdrawn").withArgs(anyValue, CHAIN_ID_0, user.address, orderUnstakingAmount);
    await expect(tx2).to.emit(ledger, "OrderUnstakeAmount").withArgs(user.address, 0, 0);
  });

  it("user can cancel order unstake request", async function () {
    const { ledger, orderTokenOft, owner, user, updater, operator } = await ledgerFixture();

    const orderStakingAmount = USER_STAKE_AMOUNT;
    const orderUnstakingAmount = USER_STAKE_AMOUNT / BigInt(2)
    await makeInitialStake(ledger, CHAIN_ID_0, user, orderStakingAmount, BigInt(0));

    // Attempt to cancel order unstake request before making one should fail
    await expect(ledger.connect(user).cancelOrderUnstakeRequest(user.address, CHAIN_ID_0)).to.be.revertedWithCustomError(
      ledger,
      "NoPendingUnstakeRequest"
    );

    await ledger.connect(user).createOrderUnstakeRequest(user.address, CHAIN_ID_0, orderUnstakingAmount);
    const unlockTimestamp = (await helpers.time.latest()) + ONE_WEEK_IN_SECONDS;
    await checkUserStakingBalance(ledger, user, orderStakingAmount - orderUnstakingAmount, BigInt(0));

    // User can cancel order unstake request
    const tx = await ledger.connect(user).cancelOrderUnstakeRequest(user.address, CHAIN_ID_0);
    // Check the OrderUnstakeCancelled event is emitted correctly
    await expect(tx).to.emit(ledger, "OrderUnstakeCancelled").withArgs(anyValue, CHAIN_ID_0, user.address, orderUnstakingAmount);
    await expect(tx).to.emit(ledger, "OrderUnstakeAmount").withArgs(user.address, 0, 0);
    await checkUserStakingBalance(ledger, user, orderStakingAmount, BigInt(0));
    await checkUserPendingUnstake(ledger, user, BigInt(0), 0);

    // Repeated cancel order unstake request should fail
    await expect(ledger.connect(user).cancelOrderUnstakeRequest(user.address, CHAIN_ID_0)).to.be.revertedWithCustomError(
      ledger,
      "NoPendingUnstakeRequest"
    );
  });

  it("user can make unstake and vest request for esOrders", async function () {
    const { ledger, orderTokenOft, owner, user, updater, operator } = await ledgerFixture();

    const orderStakingAmount = USER_STAKE_AMOUNT;
    const esOrderStakingAmount = USER_STAKE_AMOUNT;
    const esOrderVestingAmount = USER_STAKE_AMOUNT / BigInt(2);
    await makeInitialStake(ledger, CHAIN_ID_0, user, orderStakingAmount, esOrderStakingAmount);

    // Unstake and vest 500 esOrders should be done immediately
    const tx1 = await ledger.connect(user).esOrderUnstakeAndVest(user.address, CHAIN_ID_0, esOrderVestingAmount);
    // Check the EsOrderUnstakeAndVest event is emitted correctly
    await expect(tx1).to.emit(ledger, "EsOrderUnstake").withArgs(anyValue, CHAIN_ID_0, user.address, esOrderVestingAmount);
    await expect(tx1).to.emit(ledger, "VestingRequested").withArgs(anyValue, CHAIN_ID_0, user.address, 0, esOrderVestingAmount, anyValue);

    await checkUserStakingBalance(ledger, user, orderStakingAmount, esOrderStakingAmount - esOrderVestingAmount);

    // Check that vesting balance is updated
    const userVestingRequests = await ledger.getUserVestingRequests(user.address);
    expect(userVestingRequests.length).to.equal(1);
    expect(userVestingRequests[0]["requestId"]).to.equal(0);
    expect(userVestingRequests[0]["esOrderAmount"]).to.equal(esOrderVestingAmount);
    expect(await ledger.calculateVestingOrderAmount(user.address, 0)).to.equal(0);
  });

  it("repeated order unstake request increase amount but reset timestamp", async function () {
    const { ledger, orderTokenOft, owner, user, updater, operator } = await ledgerFixture();

    const orderStakingAmount = USER_STAKE_AMOUNT;
    const orderUnstakingAmount1 = USER_STAKE_AMOUNT / BigInt(2);
    const orderUnstakingAmount2 = USER_STAKE_AMOUNT / BigInt(2);
    await makeInitialStake(ledger, CHAIN_ID_0, user, orderStakingAmount, BigInt(0));

    const tx1 = await ledger.connect(user).createOrderUnstakeRequest(user.address, CHAIN_ID_0, orderUnstakingAmount1);
    const unlockTimestamp1 = (await helpers.time.latest()) + 7 * ONE_DAY_IN_SECONDS;
    await expect(tx1).to.emit(ledger, "OrderUnstakeRequested").withArgs(anyValue, CHAIN_ID_0, user.address, orderUnstakingAmount1);
    await expect(tx1).to.emit(ledger, "OrderUnstakeAmount").withArgs(user.address, orderUnstakingAmount1, unlockTimestamp1);
    await checkUserStakingBalance(ledger, user, orderStakingAmount - orderUnstakingAmount1, BigInt(0));
    await checkUserPendingUnstake(ledger, user, orderUnstakingAmount1, (await helpers.time.latest()) + 7 * ONE_DAY_IN_SECONDS);

    // Repeated order unstake request should increase the amount but reset the timestamp
    const tx2 = await ledger.connect(user).createOrderUnstakeRequest(user.address, CHAIN_ID_0, orderUnstakingAmount2);
    const unlockTimestamp2 = (await helpers.time.latest()) + 7 * ONE_DAY_IN_SECONDS;
    await expect(tx2).to.emit(ledger, "OrderUnstakeRequested").withArgs(anyValue, CHAIN_ID_0, user.address, orderUnstakingAmount2);
    await expect(tx2)
      .to.emit(ledger, "OrderUnstakeAmount")
      .withArgs(user.address, orderUnstakingAmount1 + orderUnstakingAmount2, unlockTimestamp2);
    await checkUserStakingBalance(ledger, user, orderStakingAmount - orderUnstakingAmount1 - orderUnstakingAmount2, BigInt(0));
    await checkUserPendingUnstake(
      ledger,
      user,
      orderUnstakingAmount1 + orderUnstakingAmount2,
      (await helpers.time.latest()) + 7 * ONE_DAY_IN_SECONDS
    );
  });

  it("Staking: pause should fail functions, that requires unpaused state", async function () {
    const { ledger, orderTokenOft, owner, user, updater, operator } = await ledgerFixture();

    const orderStakingAmount = USER_STAKE_AMOUNT;

    await ledger.connect(owner).pause();

    await expect(ledger.connect(user).updateValorVars()).to.be.revertedWithCustomError(ledger, "EnforcedPause");
    await expect(ledger.connect(user).stake(user.address, CHAIN_ID_0, LedgerToken.ORDER, orderStakingAmount)).to.be.revertedWithCustomError(
      ledger,
      "EnforcedPause"
    );

    await expect(ledger.connect(user).createOrderUnstakeRequest(user.address, CHAIN_ID_0, orderStakingAmount)).to.be.revertedWithCustomError(
      ledger,
      "EnforcedPause"
    );

    await expect(ledger.connect(user).cancelOrderUnstakeRequest(user.address, CHAIN_ID_0)).to.be.revertedWithCustomError(ledger, "EnforcedPause");
    await expect(ledger.connect(user).withdrawOrder(user.address, CHAIN_ID_0)).to.be.revertedWithCustomError(ledger, "EnforcedPause");
    await expect(ledger.connect(user).esOrderUnstakeAndVest(user.address, CHAIN_ID_0, orderStakingAmount)).to.be.revertedWithCustomError(
      ledger,
      "EnforcedPause"
    );
  });
});
