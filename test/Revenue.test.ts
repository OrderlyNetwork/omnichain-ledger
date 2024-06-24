import { expect } from "chai";
import { anyValue } from "@nomicfoundation/hardhat-chai-matchers/withArgs";
import * as helpers from "@nomicfoundation/hardhat-network-helpers";
import { days } from "@nomicfoundation/hardhat-network-helpers/dist/src/helpers/time/duration";

import {
  ledgerFixture,
  amountCloseTo,
  getExpectedUserUsdcPerBatch,
  waitForLastDayOfCurrentBatch,
  userStakedAndWaitForEmissionStart,
  ownerStakedAndValorEmissionStarted,
  userStakedAndValorEmissionStarted,
  userRedeemHalhOfUserValor,
  userRedeemedAndBatch0Finished,
  userRedeemedBatch0PreparedForClaiming,
  prepareBatchForClaiming,
  VALOR_PER_DAY,
  VALOR_PER_SECOND,
  VALOR_CHECK_PRECISION,
  USER_STAKE_AMOUNT,
  CHAIN_ID_0
} from "./utilities/index";
import {} from "./utilities/index";

describe("Revenue", function () {
  it("check revenue initial state", async function () {
    const { ledger } = await ledgerFixture();

    expect(await ledger.getCurrentBatchId()).to.equal(0);
    const batch0Info = await ledger.getBatchInfo(0);
    const batch0StartTime = batch0Info["batchStartTime"];
    const batch0EndTime = batch0Info["batchEndTime"];
    expect(batch0EndTime - batch0StartTime).to.equal(60 * 60 * 24 * 14);
    const batch1Info = await ledger.getBatchInfo(1);
    const batch1StartTime = batch1Info["batchStartTime"];
    expect(batch1StartTime - batch0EndTime).to.equal(0);

    const batch0 = await ledger.getBatchInfo(0);
    expect(batch0["claimable"]).to.equal(false);
    expect(batch0["redeemedValorAmount"]).to.equal(0);
    expect(batch0["fixedValorToUsdcRateScaled"]).to.equal(0);

    const batch0ChainedValorAmount = await ledger.getBatchChainedValorAmount(0);
    expect(batch0ChainedValorAmount).to.deep.equal([]);

    expect(await ledger.getUsdcAmountForBatch(0)).to.deep.equal([]);
  });

  it("check that Valor emission started after valorEmissionStartTimestamp", async function () {
    const { ledger, owner, user } = await ledgerFixture();

    await ledger.connect(owner).setValorEmissionStartTimestamp((await helpers.time.latest()) + days(2));

    await userStakedAndWaitForEmissionStart(ledger, user, USER_STAKE_AMOUNT);

    await helpers.time.increaseTo((await helpers.time.latest()) + days(1));

    expect(await ledger.getUserValor(user.address)).to.be.closeTo(VALOR_PER_DAY, VALOR_CHECK_PRECISION);
    expect(await ledger.getTotalValorEmitted()).to.be.closeTo(VALOR_PER_DAY, VALOR_CHECK_PRECISION);
    expect(await ledger.getTotalValorAmount()).to.be.closeTo(VALOR_PER_DAY, VALOR_CHECK_PRECISION);
  });

  it("redeem valor unsuccessful cases", async function () {
    const { ledger, user } = await ownerStakedAndValorEmissionStarted();

    // User can't redeem zero amount of valor
    await expect(ledger.connect(user).redeemValor(user.address, CHAIN_ID_0, 0)).to.be.revertedWithCustomError(ledger, "RedemptionAmountIsZero");

    // User can't redeem valor if their collected valor is less than the amount they want to redeem
    await expect(ledger.connect(user).redeemValor(user.address, CHAIN_ID_0, 1000)).to.be.revertedWithCustomError(
      ledger,
      "AmountIsGreaterThanCollectedValor"
    );
  });

  it("user can redeem valor to the current batch", async function () {
    const { ledger, user } = await userRedeemedBatch0PreparedForClaiming();

    expect(await ledger.getCurrentBatchId()).to.equal(1);
    const userValor = await ledger.getUserValor(user.address);
    await ledger.connect(user).redeemValor(user.address, CHAIN_ID_0, userValor);
  });

  it("claim usdc revenue unsuccessful cases", async function () {
    const { ledger, user } = await userRedeemedAndBatch0Finished();

    // User can't claim usdc revenue if the batch is not claimable
    await expect(ledger.connect(user).claimUsdcRevenue(user.address, CHAIN_ID_0)).to.be.revertedWithCustomError(ledger, "NothingToClaim");
  });

  it("user can claim usdc revenue", async function () {
    const { ledger, user, userRedeemValor } = await userRedeemedBatch0PreparedForClaiming();

    const userUsdcRevenueForBatch0 = await getExpectedUserUsdcPerBatch(ledger, userRedeemValor, 0);
    const usdcAmountForBatch0 = (await ledger.getUsdcAmountForBatch(0))[0][1];

    expect(userUsdcRevenueForBatch0).to.be.closeTo(usdcAmountForBatch0, VALOR_CHECK_PRECISION);

    const tx = await ledger.connect(user).claimUsdcRevenue(user.address, CHAIN_ID_0);
    await expect(tx)
      .to.emit(ledger, "UsdcRevenueClaimed")
      .withArgs(anyValue, CHAIN_ID_0, user.address, amountCloseTo(userUsdcRevenueForBatch0, VALOR_CHECK_PRECISION));
  });

  it("user can claim usdc revenue for multiple batches", async function () {
    const { ledger, owner, user, userRedeemValor: userRedeemValorForBatch0 } = await userRedeemedBatch0PreparedForClaiming();
    const userExpectedUsdcRevenueForBatch0 = await getExpectedUserUsdcPerBatch(ledger, userRedeemValorForBatch0, 0);

    const userRedeemValorForBatch1 = await userRedeemHalhOfUserValor(ledger, user, CHAIN_ID_0);
    await prepareBatchForClaiming(ledger, owner, 1);
    const userExpectedUsdcRevenueForBatch1 = await getExpectedUserUsdcPerBatch(ledger, userRedeemValorForBatch1, 1);

    const userRedeemValorForBatch2 = await userRedeemHalhOfUserValor(ledger, user, CHAIN_ID_0);
    await prepareBatchForClaiming(ledger, owner, 2);
    const userExpectedUsdcRevenueForBatch2 = await getExpectedUserUsdcPerBatch(ledger, userRedeemValorForBatch2, 2);

    const tx = await ledger.connect(user).claimUsdcRevenue(user.address, CHAIN_ID_0);

    await expect(tx)
      .to.emit(ledger, "UsdcRevenueClaimed")
      .withArgs(
        anyValue,
        CHAIN_ID_0,
        user.address,
        amountCloseTo(userExpectedUsdcRevenueForBatch0 + userExpectedUsdcRevenueForBatch1 + userExpectedUsdcRevenueForBatch2, VALOR_CHECK_PRECISION)
      );
  });

  it("user can claim usdc revenue for multiple chains", async function () {
    const { ledger, owner, user } = await userStakedAndValorEmissionStarted();

    await waitForLastDayOfCurrentBatch(ledger);
    const userRedeemValorForChain0 = await userRedeemHalhOfUserValor(ledger, user, 0);
    const userRedeemValorForChain1 = await userRedeemHalhOfUserValor(ledger, user, 1);
    await prepareBatchForClaiming(ledger, owner, 0);

    const userExpectedUsdcRevenueForChain0 = await getExpectedUserUsdcPerBatch(ledger, userRedeemValorForChain0, 0);
    const tx = await ledger.connect(user).claimUsdcRevenue(user.address, 0);
    await expect(tx)
      .to.emit(ledger, "UsdcRevenueClaimed")
      .withArgs(anyValue, 0, user.address, amountCloseTo(userExpectedUsdcRevenueForChain0, VALOR_CHECK_PRECISION));

    const userExpectedUsdcRevenueForChain1 = await getExpectedUserUsdcPerBatch(ledger, userRedeemValorForChain1, 0);
    const tx2 = await ledger.connect(user).claimUsdcRevenue(user.address, 1);
    await expect(tx2)
      .to.emit(ledger, "UsdcRevenueClaimed")
      .withArgs(anyValue, 1, user.address, amountCloseTo(userExpectedUsdcRevenueForChain1, VALOR_CHECK_PRECISION));
  });

  it("user can redeem valor more than once to the same batch", async function () {
    const { ledger, owner, user } = await userStakedAndValorEmissionStarted();

    await waitForLastDayOfCurrentBatch(ledger);
    const userRedeemValor1 = await userRedeemHalhOfUserValor(ledger, user, CHAIN_ID_0);
    const userRedeemValor2 = await userRedeemHalhOfUserValor(ledger, user, CHAIN_ID_0);
    await prepareBatchForClaiming(ledger, owner, 0);

    expect(await ledger.getUserRedeemedValorAmountForBatchAndChain(user.address, 0, CHAIN_ID_0)).to.equal(userRedeemValor1 + userRedeemValor2);
    const userExpectedUsdcRevenueForChain0 = await getExpectedUserUsdcPerBatch(ledger, userRedeemValor1 + userRedeemValor2, 0);
    const tx2 = await ledger.connect(user).claimUsdcRevenue(user.address, CHAIN_ID_0);
    await expect(tx2)
      .to.emit(ledger, "UsdcRevenueClaimed")
      .withArgs(anyValue, CHAIN_ID_0, user.address, amountCloseTo(userExpectedUsdcRevenueForChain0, VALOR_CHECK_PRECISION));
  });

  it("user should have no more than 2 BatchedRedemptionRequest at the same time", async function () {
    const { ledger, owner, user } = await userStakedAndValorEmissionStarted();

    await waitForLastDayOfCurrentBatch(ledger);
    // User redeem valor to the current batch (0)
    const userRedeemValorForBatch0 = await userRedeemHalhOfUserValor(ledger, user, CHAIN_ID_0);
    // So, user should have 1 BatchedRedemptionRequest
    expect(await ledger.nuberOfUsersBatchedRedemptionRequests(user.address)).to.equal(1);

    // Batch 1 comes
    await helpers.time.increaseTo((await ledger.getBatchInfo(0))["batchEndTime"] + BigInt(1));
    // Assure that batch 1 started
    expect(await ledger.getCurrentBatchId()).to.equal(1);
    // User redeem valor to the current batch (1)
    const userRedeemValorForBatch1 = await userRedeemHalhOfUserValor(ledger, user, CHAIN_ID_0);
    // As batch 0 is not claimable yet, it shouldn't be collected, so user should have 2 BatchedRedemptionRequest
    expect(await ledger.nuberOfUsersBatchedRedemptionRequests(user.address)).to.equal(2);

    // In the normal case admin should prepare batch 0 for claiming before batch 2 comes
    await prepareBatchForClaiming(ledger, owner, 0);

    // Let's move to batch 2
    await helpers.time.increaseTo((await ledger.getBatchInfo(1))["batchEndTime"] + BigInt(1));
    // Assure that batch 2 started
    expect(await ledger.getCurrentBatchId()).to.equal(2);
    // User redeem valor to the current batch (2)
    const userRedeemValorForBatch2 = await userRedeemHalhOfUserValor(ledger, user, CHAIN_ID_0);
    // But as batch 0 is claimable, it should be collected during redeeming valor to batch 2
    // So, user should have again 2 BatchedRedemptionRequest:
    // batch 1, that is finished but not claimed yet, and batch 2, that is current
    expect(await ledger.nuberOfUsersBatchedRedemptionRequests(user.address)).to.equal(2);

    await prepareBatchForClaiming(ledger, owner, 1);

    // Let's move to batch 3
    await helpers.time.increaseTo((await ledger.getBatchInfo(2))["batchEndTime"] + BigInt(1));
    // Assure that batch 3 started
    expect(await ledger.getCurrentBatchId()).to.equal(3);

    await prepareBatchForClaiming(ledger, owner, 2);

    const userExpectedUsdcRevenueForBatch0 = await getExpectedUserUsdcPerBatch(ledger, userRedeemValorForBatch0, 0);
    const userExpectedUsdcRevenueForBatch1 = await getExpectedUserUsdcPerBatch(ledger, userRedeemValorForBatch1, 1);
    const userExpectedUsdcRevenueForBatch2 = await getExpectedUserUsdcPerBatch(ledger, userRedeemValorForBatch2, 2);
    const userxpectedUsdcForClaim = userExpectedUsdcRevenueForBatch0 + userExpectedUsdcRevenueForBatch1 + userExpectedUsdcRevenueForBatch2;

    const tx = await ledger.connect(user).claimUsdcRevenue(user.address, CHAIN_ID_0);
    await expect(tx)
      .to.emit(ledger, "UsdcRevenueClaimed")
      .withArgs(anyValue, CHAIN_ID_0, user.address, amountCloseTo(userxpectedUsdcForClaim, VALOR_CHECK_PRECISION));

    // All requests should be collected and claimed
    expect(await ledger.nuberOfUsersBatchedRedemptionRequests(user.address)).to.equal(0);
  });

  it("owner should be able to fix batch price if nobody redeemed valor", async function () {
    const { ledger, owner } = await ownerStakedAndValorEmissionStarted();

    // Batch 0 is created authomatically
    await helpers.time.increaseTo((await ledger.getBatchInfo(0))["batchEndTime"] + BigInt(1));

    const usdcRevenueForBatch0 = ((await ledger.getTotalValorAmount()) + VALOR_PER_SECOND) / BigInt(2);
    await ledger.connect(owner).dailyUsdcNetFeeRevenueTestNoSignatureCheck(usdcRevenueForBatch0);

    await ledger.connect(owner).batchPreparedToClaim(0);

    const expectedValorToUsdcRateScaled1 = 500000000000000000000000000n;
    const batchInfo0 = await ledger.getBatchInfo(0);
    expect(batchInfo0["fixedValorToUsdcRateScaled"]).to.closeTo(expectedValorToUsdcRateScaled1, VALOR_CHECK_PRECISION);
    expect(batchInfo0["claimable"]).to.equal(true);

    // Let's move to batch 1
    await helpers.time.increaseTo((await ledger.getBatchInfo(1))["batchEndTime"] + BigInt(1));

    const usdcRevenueForBatch1 = (await ledger.getTotalValorAmount()) + VALOR_PER_SECOND - usdcRevenueForBatch0;
    await ledger.connect(owner).dailyUsdcNetFeeRevenueTestNoSignatureCheck(usdcRevenueForBatch1);
    await ledger.connect(owner).batchPreparedToClaim(1);

    const expectedValorToUsdcRateScaled2 = 1000000000000000000000000000n;
    const batchInfo1 = await ledger.getBatchInfo(1);

    expect(batchInfo1["fixedValorToUsdcRateScaled"]).to.closeTo(expectedValorToUsdcRateScaled2, VALOR_CHECK_PRECISION);
    expect(batchInfo1["claimable"]).to.equal(true);
  });

  it("Revenue: pause should fail functions, that requires unpaused state", async function () {
    const { ledger, owner, user } = await ownerStakedAndValorEmissionStarted();

    await ledger.connect(owner).pause();
    await expect(ledger.connect(owner).dailyUsdcNetFeeRevenueTestNoSignatureCheck(1000)).to.be.revertedWithCustomError(ledger, "EnforcedPause");
    await expect(ledger.connect(owner).batchPreparedToClaim(0)).to.be.revertedWithCustomError(ledger, "EnforcedPause");
    await expect(ledger.connect(user).redeemValor(user.address, 0, 1000)).to.be.revertedWithCustomError(ledger, "EnforcedPause");
    await expect(ledger.connect(user).claimUsdcRevenue(user.address, 0)).to.be.revertedWithCustomError(ledger, "EnforcedPause");
  });
});
