import { Contract } from "ethers";
import { expect } from "chai";
import { anyValue } from "@nomicfoundation/hardhat-chai-matchers/withArgs";
import * as helpers from "@nomicfoundation/hardhat-network-helpers";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import { ONE_DAY_IN_SECONDS, LedgerToken, ledgerFixture, VALOR_PER_DAY, VALOR_PER_SECOND } from "./utilities/index";

describe("Staking", function () {
  async function stakingFixture() {
    const { ledger, orderTokenOft, owner, user, updater, operator } = await ledgerFixture();
    return { ledger, orderTokenOft, owner, user, updater, operator };
  }

  async function checkUserStakingBalance(ledger: Contract, user: SignerWithAddress, orderBalance: number, esOrderBalance: number) {
    const userStakingBalance = await ledger.getStakingInfo(user.address);
    expect(userStakingBalance["orderBalance"]).to.equal(orderBalance);
    expect(userStakingBalance["esOrderBalance"]).to.equal(esOrderBalance);
    expect(await ledger.userTotalStakingBalance(user.address)).to.equal(orderBalance + esOrderBalance);
  }

  async function checkUserPendingUnstake(ledger: Contract, user: SignerWithAddress, balanceOrder: number, unlockTimestamp: number) {
    const userPendingUnstake2 = await ledger.userPendingUnstake(user.address);
    expect(userPendingUnstake2["balanceOrder"]).to.equal(balanceOrder);
    expect(userPendingUnstake2["unlockTimestamp"]).closeTo(unlockTimestamp, 2);
  }

  async function makeInitialStake(
    ledger: Contract,
    chainId: number,
    user: SignerWithAddress,
    orderStakingAmount: number,
    esOrderStakingAmount: number
  ) {
    if (orderStakingAmount > 0) {
      await ledger.connect(user).stake(user.address, chainId, LedgerToken.ORDER, orderStakingAmount);
    }
    if (esOrderStakingAmount > 0) {
      await ledger.connect(user).stake(user.address, chainId, LedgerToken.ESORDER, esOrderStakingAmount);
    }
    await checkUserStakingBalance(ledger, user, orderStakingAmount, esOrderStakingAmount);
  }

  it("check staking initial state", async function () {
    const { ledger, orderTokenOft, owner, user, updater, operator } = await stakingFixture();

    expect(await ledger.totalStakedAmount()).to.equal(0);
    expect(await helpers.time.latest()).closeTo((await ledger.lastValorUpdateTimestamp()).toNumber(), 2);
    expect(await ledger.accValorPerShareScaled()).to.equal(0);
    expect(await ledger.unstakeLockPeriod()).to.equal(60 * 60 * 24 * 7);
    expect(await ledger.userTotalStakingBalance(user.address)).to.equal(0);
    expect(await ledger.getOrderAvailableToWithdraw(user.address)).to.equal(0);
    expect(await ledger.getUserValor(user.address)).to.equal(0);
  });

  it("user can stake order tokens", async function () {
    const { ledger, orderTokenOft, owner, user, updater, operator } = await stakingFixture();

    const chainId = 0;
    await ledger.connect(user).stake(user.address, chainId, LedgerToken.ORDER, 1000);

    expect(await ledger.totalStakedAmount()).to.equal(1000);
    expect(await ledger.userTotalStakingBalance(user.address)).to.equal(1000);
    expect(await ledger.getOrderAvailableToWithdraw(user.address)).to.equal(0);
    expect(await ledger.getUserValor(user.address)).to.equal(0);
  });

  it("user stake should produce valor", async function () {
    const { ledger, orderTokenOft, owner, user, updater, operator } = await stakingFixture();

    const chainId = 0;
    const tx = await ledger.connect(user).stake(user.address, chainId, LedgerToken.ORDER, 1000);
    // Check the Staked event is emitted correctly
    await expect(tx).to.emit(ledger, "Staked").withArgs(anyValue, chainId, user.address, 1000, LedgerToken.ORDER);

    expect(await ledger.userTotalStakingBalance(user.address)).to.equal(1000);

    await helpers.time.increase(ONE_DAY_IN_SECONDS);
    // Our test valor emission is 1 valor per second.
    // Only one user staked, so user receives all valor emission for the day.
    expect(await ledger.getUserValor(user.address)).to.equal(VALOR_PER_DAY);
  });

  it("unstake request should stop valor emission for user", async function () {
    const { ledger, orderTokenOft, owner, user, updater, operator } = await stakingFixture();

    const chainId = 0;
    const precision = VALOR_PER_SECOND.mul(2);
    await ledger.connect(user).stake(user.address, chainId, LedgerToken.ORDER, 1000);
    await ledger.connect(owner).stake(owner.address, chainId, LedgerToken.ORDER, 1000);

    await helpers.time.increase(ONE_DAY_IN_SECONDS);
    // Our test valor emission is 1 valor per second.
    // Two users staked equal amount in total, so they should receive the same amount of valor.
    // But they can be a bit greater due to a bit of time pass before checking the valor.
    expect(await ledger.getUserValor(user.address)).to.closeTo(VALOR_PER_DAY.div(2), precision);
    expect(await ledger.getUserValor(owner.address)).to.closeTo(VALOR_PER_DAY.div(2), precision);

    await ledger.connect(user).createOrderUnstakeRequest(user.address, chainId, 1000);

    await helpers.time.increase(ONE_DAY_IN_SECONDS);
    // Unstake request should stop valor emission for user, but not for others
    expect(await ledger.getUserValor(user.address)).to.closeTo(VALOR_PER_DAY.div(2), precision);
    // So, owner should receive all valor emission for the day.
    expect(await ledger.getUserValor(owner.address)).to.closeTo(VALOR_PER_DAY.div(2).add(VALOR_PER_DAY), precision);

    //Cancel unstake request should resume valor emission
    await ledger.connect(user).cancelOrderUnstakeRequest(user.address, chainId);
    await helpers.time.increase(ONE_DAY_IN_SECONDS);

    // Dayly valor emission should be again divided between two users
    expect(await ledger.getUserValor(user.address)).to.closeTo(VALOR_PER_DAY, precision);
    expect(await ledger.getUserValor(owner.address)).to.closeTo(VALOR_PER_DAY.mul(2), precision);
  });

  it("users share valor emission according to their stake", async function () {
    const { ledger, orderTokenOft, owner, user, updater, operator } = await stakingFixture();

    const chainId = 0;
    const precision = VALOR_PER_SECOND.mul(3);
    // $ORDER and es$ORDER should be counted as well
    await ledger.connect(user).stake(user.address, chainId, LedgerToken.ORDER, 500);
    await ledger.connect(user).stake(user.address, chainId, LedgerToken.ESORDER, 500);
    await ledger.connect(updater).stake(updater.address, chainId, LedgerToken.ORDER, 1000);
    await ledger.connect(owner).stake(owner.address, chainId, LedgerToken.ESORDER, 1000);

    await helpers.time.increase(ONE_DAY_IN_SECONDS);
    // Our test valor emission is 1 valor per second.
    // Three users staked equal amount in total, so they should receive the same amount of valor.
    // But they can be a bit greater due to a bit of time pass before checking the valor.
    expect(await ledger.getUserValor(user.address)).to.closeTo(VALOR_PER_DAY.div(3), precision);
    expect(await ledger.getUserValor(updater.address)).to.closeTo(VALOR_PER_DAY.div(3), precision);
    expect(await ledger.getUserValor(owner.address)).to.closeTo(VALOR_PER_DAY.div(3), precision);
  });

  it("user can make unstake request for orders", async function () {
    const { ledger, orderTokenOft, owner, user, updater, operator } = await stakingFixture();

    // User can't create unstake request if they don't have any staked orders
    await expect(ledger.connect(user).createOrderUnstakeRequest(user.address, 0, 1000))
      .to.be.revertedWithCustomError(ledger, "StakingBalanceInsufficient")
      .withArgs(LedgerToken.ORDER);

    const chainId = 0;
    const orderStakingAmount = 1000;
    const esOrderStakingAmount = 1000;
    const orderUnstakingAmount = 500;
    await makeInitialStake(ledger, chainId, user, orderStakingAmount, esOrderStakingAmount);

    // Attempt to withdraw before unstaking should fail
    await expect(ledger.connect(user).withdrawOrder(user.address, chainId)).to.be.revertedWithCustomError(ledger, "NoPendingUnstakeRequest");

    // User can't create unstake request for zero amount
    await expect(ledger.connect(user).createOrderUnstakeRequest(user.address, chainId, 0)).to.be.revertedWithCustomError(ledger, "AmountIsZero");

    // User can't create unstake request for more than they have
    await expect(ledger.connect(user).createOrderUnstakeRequest(user.address, chainId, orderStakingAmount + 1))
      .to.be.revertedWithCustomError(ledger, "StakingBalanceInsufficient")
      .withArgs(LedgerToken.ORDER);

    // User make unstake request for 500 orders
    const tx1 = await ledger.connect(user).createOrderUnstakeRequest(user.address, chainId, orderUnstakingAmount);
    const unlockTimestamp = (await helpers.time.latest()) + 7 * ONE_DAY_IN_SECONDS;
    // Check the OrderUnstakeRequested event is emitted correctly
    await expect(tx1).to.emit(ledger, "OrderUnstakeRequested").withArgs(anyValue, chainId, user.address, orderUnstakingAmount, unlockTimestamp);

    await checkUserStakingBalance(ledger, user, orderStakingAmount - orderUnstakingAmount, esOrderStakingAmount);
    await checkUserPendingUnstake(ledger, user, orderUnstakingAmount, (await helpers.time.latest()) + 7 * ONE_DAY_IN_SECONDS);

    // Pending unstake should not be available to withdraw
    expect(await ledger.getOrderAvailableToWithdraw(user.address)).to.equal(0);

    // Attempt to withdraw unstaked orders before unlock period should fail
    await expect(ledger.connect(user).withdrawOrder(user.address, chainId)).to.be.revertedWithCustomError(ledger, "UnlockTimeNotPassedYet");

    // After locking period, user should be able to withdraw orders
    await helpers.time.increase(7 * ONE_DAY_IN_SECONDS);
    expect(await ledger.getOrderAvailableToWithdraw(user.address)).to.equal(orderUnstakingAmount);

    // Now user should be able to withdraw orders
    const tx2 = await ledger.connect(user).withdrawOrder(user.address, chainId);
    // Check the OrderWithdrawn event is emitted correctly
    await expect(tx2).to.emit(ledger, "OrderWithdrawn").withArgs(anyValue, chainId, user.address, orderUnstakingAmount);
  });

  it("user can cancel order unstake request", async function () {
    const { ledger, orderTokenOft, owner, user, updater, operator } = await stakingFixture();

    const chainId = 0;
    const orderStakingAmount = 1000;
    const orderUnstakingAmount = 500;
    await makeInitialStake(ledger, chainId, user, orderStakingAmount, 0);

    // Attempt to cancel order unstake request before making one should fail
    await expect(ledger.connect(user).cancelOrderUnstakeRequest(user.address, chainId)).to.be.revertedWithCustomError(
      ledger,
      "NoPendingUnstakeRequest"
    );

    await ledger.connect(user).createOrderUnstakeRequest(user.address, chainId, orderUnstakingAmount);
    await checkUserStakingBalance(ledger, user, orderStakingAmount - orderUnstakingAmount, 0);

    // User can cancel order unstake request
    const tx = await ledger.connect(user).cancelOrderUnstakeRequest(user.address, chainId);
    // Check the OrderUnstakeCancelled event is emitted correctly
    await expect(tx).to.emit(ledger, "OrderUnstakeCancelled").withArgs(anyValue, chainId, user.address, orderUnstakingAmount);
    await checkUserStakingBalance(ledger, user, orderStakingAmount, 0);
    await checkUserPendingUnstake(ledger, user, 0, 0);

    // Repeated cancel order unstake request should fail
    await expect(ledger.connect(user).cancelOrderUnstakeRequest(user.address, chainId)).to.be.revertedWithCustomError(
      ledger,
      "NoPendingUnstakeRequest"
    );
  });

  it("user can make unstake and vest request for esOrders", async function () {
    const { ledger, orderTokenOft, owner, user, updater, operator } = await stakingFixture();

    const chainId = 0;
    const orderStakingAmount = 1000;
    const esOrderStakingAmount = 1000;
    const esOrderVestingAmount = 500;
    await makeInitialStake(ledger, chainId, user, orderStakingAmount, esOrderStakingAmount);

    // Unstake and vest 500 esOrders should be done immediately
    const tx1 = await ledger.connect(user).esOrderUnstakeAndVest(user.address, chainId, esOrderVestingAmount);
    // Check the EsOrderUnstakeAndVest event is emitted correctly
    await expect(tx1).to.emit(ledger, "EsOrderUnstake").withArgs(anyValue, chainId, user.address, esOrderVestingAmount);
    await expect(tx1).to.emit(ledger, "VestingRequested").withArgs(anyValue, chainId, user.address, 0, esOrderVestingAmount, anyValue);

    await checkUserStakingBalance(ledger, user, orderStakingAmount, esOrderStakingAmount - esOrderVestingAmount);

    // Check that vesting balance is updated
    const userVestingRequests = await ledger.getUserVestingRequests(user.address);
    expect(userVestingRequests.length).to.equal(1);
    expect(userVestingRequests[0]["requestId"]).to.equal(0);
    expect(userVestingRequests[0]["esOrderAmount"]).to.equal(esOrderVestingAmount);
    expect(await ledger.calculateVestingOrderAmount(user.address, 0)).to.equal(0);
  });

  it("repeated order unstake request increase amount but reset timestamp", async function () {
    const { ledger, orderTokenOft, owner, user, updater, operator } = await stakingFixture();

    const chainId = 0;
    const orderStakingAmount = 1000;
    const orderUnstakingAmount1 = 500;
    const orderUnstakingAmount2 = 300;
    await makeInitialStake(ledger, chainId, user, orderStakingAmount, 0);

    await ledger.connect(user).createOrderUnstakeRequest(user.address, chainId, orderUnstakingAmount1);
    await checkUserStakingBalance(ledger, user, orderStakingAmount - orderUnstakingAmount1, 0);
    await checkUserPendingUnstake(ledger, user, orderUnstakingAmount1, (await helpers.time.latest()) + 7 * ONE_DAY_IN_SECONDS);

    // Repeated order unstake request should increase the amount but reset the timestamp
    await ledger.connect(user).createOrderUnstakeRequest(user.address, chainId, orderUnstakingAmount2);
    await checkUserStakingBalance(ledger, user, orderStakingAmount - orderUnstakingAmount1 - orderUnstakingAmount2, 0);
    await checkUserPendingUnstake(
      ledger,
      user,
      orderUnstakingAmount1 + orderUnstakingAmount2,
      (await helpers.time.latest()) + 7 * ONE_DAY_IN_SECONDS
    );
  });
});
