import { Contract, ethers } from "ethers";
import { expect } from "chai";
import { anyValue } from "@nomicfoundation/hardhat-chai-matchers/withArgs";
import * as helpers from "@nomicfoundation/hardhat-network-helpers";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import { ledgerFixture, LedgerToken, VALOR_PER_DAY, VALOR_PER_SECOND, VALOR_TO_USDC_RATE_PRECISION } from "./utilities/index";
import { days } from "@nomicfoundation/hardhat-network-helpers/dist/src/helpers/time/duration";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";

describe("Revenue", function () {
  const chainId = 0;
  // Let's make precision in 2 seconds Valor emission rate for transactions
  const precision = VALOR_PER_SECOND * BigInt(2);
  const VALOR_TO_USDC_RATE_PRECISION = BigInt(1e27);
  const USER_STAKE_AMOUNT = ethers.parseEther("1000");

  async function revenueFixture() {
    const { ledger, orderTokenOft, owner, user, updater, operator } = await ledgerFixture();
    return { ledger, orderTokenOft, owner, user, updater, operator };
  }

  async function stakeWaitForEmissionStartAndCheckBalance(ledger: Contract, user: HardhatEthersSigner, stakeAmount: BigInt) {
    await ledger.connect(user).stake(user.address, chainId, LedgerToken.ORDER, stakeAmount);
    const valorEmissionstart = await ledger.valorEmissionStartTimestamp();
    helpers.time.increaseTo(valorEmissionstart);

    expect(await ledger.userTotalStakingBalance(user.address)).to.equal(stakeAmount);
    expect(await ledger.getUserValor(user.address)).to.equal(0);
    expect(await ledger.getTotalValorEmitted()).to.equal(0);
    expect(await ledger.getTotalValorAmount()).to.equal(0);
  }

  async function ownerStakedAndValorEmissionStarted() {
    const { ledger, orderTokenOft, owner, user, updater, operator } = await revenueFixture();

    // Owner makes a stake to prevent totalStakedAmount be zero when valor emission starts
    await stakeWaitForEmissionStartAndCheckBalance(ledger, owner, ethers.parseEther("1"));
    return { ledger, orderTokenOft, owner, user, updater, operator };
  }

  async function userStakedAndValorEmissionStarted() {
    const { ledger, orderTokenOft, owner, user, updater, operator } = await revenueFixture();

    // User makes a stake to start collecting valor after valor emission started
    await stakeWaitForEmissionStartAndCheckBalance(ledger, user, USER_STAKE_AMOUNT);
    return { ledger, orderTokenOft, owner, user, updater, operator };
  }

  async function oneDayBeforeBatch0EndUserCollectedValorFor12Days() {
    const { ledger, orderTokenOft, owner, user, updater, operator } = await userStakedAndValorEmissionStarted();

    const batch0EndTime = (await ledger.getBatchInfo(0))["batchEndTime"];
    await helpers.time.increaseTo(batch0EndTime - BigInt(days(1)));

    const userExpectedCollectedValor = VALOR_PER_DAY * BigInt(12);

    expect(await ledger.getUserValor(user.address)).to.be.closeTo(userExpectedCollectedValor, precision);
    expect(await ledger.getCurrentBatchId()).to.equal(0);

    return { ledger, orderTokenOft, owner, user, updater, operator, userCollectedValor: userExpectedCollectedValor };
  }

  async function userRedeemedBatch0Finished() {
    const { ledger, orderTokenOft, owner, user, updater, operator, userCollectedValor } = await oneDayBeforeBatch0EndUserCollectedValorFor12Days();

    const userRedeemValor = userCollectedValor / BigInt(2);
    await ledger.connect(user).redeemValor(user.address, chainId, userRedeemValor);
    const userLeftValor = await ledger.getUserValor(user.address);
    expect(userLeftValor).to.closeTo(userCollectedValor - userRedeemValor, precision);

    const batch0Info = await ledger.getBatchInfo(0);
    expect(batch0Info["claimable"]).to.equal(false);
    expect(batch0Info["redeemedValorAmount"]).to.equal(userRedeemValor);
    expect(batch0Info["fixedValorToUsdcRateScaled"]).to.equal(0);
    expect(await ledger.getUserValor(user.address)).to.closeTo(userCollectedValor - userRedeemValor, precision);

    await helpers.time.increaseTo(batch0Info["batchEndTime"]);
    return { ledger, orderTokenOft, owner, user, updater, operator, userRedeemValor };
  }

  async function userRedeemedBatch0PreparedForClaiming() {
    const { ledger, orderTokenOft, owner, user, updater, operator, userRedeemValor } = await userRedeemedBatch0Finished();

    const totalValorAmount = await ledger.getTotalValorAmount();
    const usdcNetFeeRevenueForBatch0 = (totalValorAmount + VALOR_PER_SECOND) * BigInt(2);
    await ledger.connect(owner).dailyUsdcNetFeeRevenueTestNoSignatureCheck(usdcNetFeeRevenueForBatch0);

    const batch0InfoBeforePrepared = await ledger.getBatchInfo(0);
    expect(batch0InfoBeforePrepared["claimable"]).to.equal(false);
    const expectedValorToUsdcRateScaled = BigInt(2) * VALOR_TO_USDC_RATE_PRECISION;
    expect(batch0InfoBeforePrepared["fixedValorToUsdcRateScaled"]).to.be.closeTo(expectedValorToUsdcRateScaled, precision);

    const { usdcRevenuePerBatch, valorPerBatch } = await prepareBatchForClaiming(ledger, owner, 0);
    const batch0InfoAfterPrepared = await ledger.getBatchInfo(0);
    expect(batch0InfoAfterPrepared["claimable"]).to.equal(true);

    const batch0UsdcAmount =
      (BigInt(batch0InfoAfterPrepared["redeemedValorAmount"]) * BigInt(batch0InfoAfterPrepared["fixedValorToUsdcRateScaled"])) /
      VALOR_TO_USDC_RATE_PRECISION;
    expect(batch0UsdcAmount).to.closeTo(userRedeemValor * BigInt(2), precision);

    return { ledger, orderTokenOft, owner, user, updater, operator, userRedeemValor, usdcRevenuePerBatch, valorPerBatch };
  }

  async function prepareBatchForClaiming(ledger: Contract, owner: SignerWithAddress, batchId: number) {
    const previousTotalUsdcInTreasure = await ledger.totalUsdcInTreasure();

    const batchLengthInSeconds = BigInt(60 * 60 * 24 * 14);
    const valorPerBatch = (await ledger.valorPerSecond()) * batchLengthInSeconds;
    // Lets USDC revenue be as twice as valor revenue
    const usdcRevenuePerBatch = valorPerBatch * BigInt(2);
    const totalUsdcInTreasure = previousTotalUsdcInTreasure + usdcRevenuePerBatch;

    const totalValorAmountBefore = await ledger.getTotalValorAmount();

    const batchEndTime = (await ledger.getBatchInfo(batchId))["batchEndTime"];
    const timeDiff = BigInt(batchEndTime) - BigInt(await helpers.time.latest());
    if (batchEndTime > (await helpers.time.latest())) {
      await helpers.time.increaseTo(batchEndTime + BigInt(1));
    }

    const totalValorAmount = totalValorAmountBefore + (await ledger.valorPerSecond()) * timeDiff;
    const valorToUsdcRateScaled = (BigInt(totalUsdcInTreasure) * VALOR_TO_USDC_RATE_PRECISION) / BigInt(totalValorAmount);

    const precision = VALOR_PER_SECOND * BigInt(4);

    // Owner can update the total USDC in the treasure because he granted TREASURE_UPDATER_ROLE
    // This also fix the valor to USDC rate for previous finished batch
    const tx = await ledger.connect(owner).dailyUsdcNetFeeRevenueTestNoSignatureCheck(usdcRevenuePerBatch);
    await expect(tx).to.emit(ledger, "DailyUsdcNetFeeRevenueUpdated");

    expect(await ledger.totalUsdcInTreasure()).to.equal(totalUsdcInTreasure);
    expect(await ledger.getTotalValorAmount()).to.closeTo(totalValorAmount, precision);

    // Then owner can prepare the batch to be claimed
    await ledger.connect(owner).batchPreparedToClaim(batchId);
    const batchInfo = await ledger.getBatchInfo(batchId);
    expect(batchInfo["claimable"]).to.equal(true);
    expect(batchInfo["fixedValorToUsdcRateScaled"]).to.closeTo(valorToUsdcRateScaled, precision * precision);
    const totalValorAmountAfter = await ledger.getTotalValorAmount();
    expect(totalValorAmountAfter).to.closeTo(totalValorAmount - batchInfo["redeemedValorAmount"], precision * BigInt(2));
    return { usdcRevenuePerBatch, valorPerBatch };
  }

  it("check revenue initial state", async function () {
    const { ledger, orderTokenOft, owner, user, updater, operator } = await revenueFixture();

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
    const { ledger, orderTokenOft, owner, user, updater, operator } = await revenueFixture();

    await ledger.connect(owner).setValorEmissionStartTimestamp((await helpers.time.latest()) + days(2));

    await stakeWaitForEmissionStartAndCheckBalance(ledger, user, USER_STAKE_AMOUNT);

    await helpers.time.increaseTo((await helpers.time.latest()) + days(1));

    expect(await ledger.getUserValor(user.address)).to.be.closeTo(VALOR_PER_DAY, precision);
    expect(await ledger.getTotalValorEmitted()).to.be.closeTo(VALOR_PER_DAY, precision);
    expect(await ledger.getTotalValorAmount()).to.be.closeTo(VALOR_PER_DAY, precision);
  });

  it("redeem valor unsuccessful cases", async function () {
    const { ledger, orderTokenOft, owner, user, updater, operator } = await ownerStakedAndValorEmissionStarted();

    // User can't redeem zero amount of valor
    await expect(ledger.connect(user).redeemValor(user.address, chainId, 0)).to.be.revertedWithCustomError(ledger, "RedemptionAmountIsZero");

    // User can't redeem valor if their collected valor is less than the amount they want to redeem
    await expect(ledger.connect(user).redeemValor(user.address, chainId, 1000)).to.be.revertedWithCustomError(
      ledger,
      "AmountIsGreaterThanCollectedValor"
    );
  });

  it("user can redeem valor to the current batch", async function () {
    const { ledger, orderTokenOft, owner, user, updater, operator } = await userRedeemedBatch0PreparedForClaiming();

    expect(await ledger.getCurrentBatchId()).to.equal(1);
    const userValor = await ledger.getUserValor(user.address);
    await ledger.connect(user).redeemValor(user.address, chainId, userValor);
  });

  it("claim usdc revenue unsuccessful cases", async function () {
    const { ledger, orderTokenOft, owner, user, updater, operator } = await userRedeemedBatch0Finished();

    // User can't claim usdc revenue if the batch is not claimable
    await expect(ledger.connect(user).claimUsdcRevenue(user.address, chainId)).to.be.revertedWithCustomError(ledger, "NothingToClaim");
  });

  it("user can claim usdc revenue", async function () {
    const { ledger, orderTokenOft, owner, user, updater, operator } = await userRedeemedBatch0PreparedForClaiming();

    const batch0Info = await ledger.getBatchInfo(0);
    const userUsdcRevenue =
      (BigInt(batch0Info["redeemedValorAmount"]) * BigInt(batch0Info["fixedValorToUsdcRateScaled"])) / VALOR_TO_USDC_RATE_PRECISION;

    const usdcAmountForBatch0 = (await ledger.getUsdcAmountForBatch(0))[0][1];

    // For TS precision lost we can't compare them directly but they should be very close
    expect(userUsdcRevenue).to.be.closeTo(usdcAmountForBatch0, precision);

    const tx = await ledger.connect(user).claimUsdcRevenue(user.address, chainId);
    await expect(tx).to.emit(ledger, "UsdcRevenueClaimed").withArgs(anyValue, chainId, user.address, usdcAmountForBatch0);
  });

  it("user can claim usdc revenue for multiple batches", async function () {
    const { ledger, orderTokenOft, owner, user, updater, operator } = await ownerStakedAndValorEmissionStarted();

    const userTotalValorAmount = 2000;
    const redeemValorAmountForBatch0 = 1000;
    const redeemValorAmountForBatch1 = 1000;
    await ledger.connect(user).setCollectedValor(user.address, userTotalValorAmount);
    expect(await ledger.collectedValor(user.address)).to.equal(userTotalValorAmount);

    await ledger.connect(user).redeemValor(user.address, chainId, redeemValorAmountForBatch0);
    expect(await ledger.collectedValor(user.address)).to.equal(userTotalValorAmount - redeemValorAmountForBatch0);

    await prepareBatchForClaiming(ledger, owner, 0);
    const userUsdcForBatch0 =
      (BigInt(redeemValorAmountForBatch0) * (BigInt((await ledger.getBatchInfo(0))["fixedValorToUsdcRateScaled"]) / BigInt(1e9))) / BigInt(1e18);

    await ledger.connect(user).redeemValor(user.address, chainId, redeemValorAmountForBatch1);
    expect(await ledger.collectedValor(user.address)).to.equal(userTotalValorAmount - redeemValorAmountForBatch0 - redeemValorAmountForBatch1);

    await prepareBatchForClaiming(ledger, owner, 1);
    const userUsdcForBatch1 =
      (BigInt(redeemValorAmountForBatch1) * (BigInt((await ledger.getBatchInfo(1))["fixedValorToUsdcRateScaled"]) / BigInt(1e9))) / BigInt(1e18);

    expect(await ledger.collectedValor(user.address)).to.equal(0);

    const tx = await ledger.connect(user).claimUsdcRevenue(user.address, chainId);
    await expect(tx)
      .to.emit(ledger, "UsdcRevenueClaimed")
      .withArgs(anyValue, chainId, user.address, userUsdcForBatch0 + userUsdcForBatch1);
  });

  it("user can claim usdc revenue for multiple chains", async function () {
    const { ledger, orderTokenOft, owner, user, updater, operator } = await ownerStakedAndValorEmissionStarted();

    await ledger.connect(user).setCollectedValor(user.address, 2000);
    await ledger.connect(user).redeemValor(user.address, 0, 1000);
    await ledger.connect(user).redeemValor(user.address, 1, 1000);

    await prepareBatchForClaiming(ledger, owner, 0);

    const usdcAmountForBatchAndChain0 = (await ledger.getUsdcAmountForBatch(0))[0][1];
    const tx = await ledger.connect(user).claimUsdcRevenue(user.address, 0);
    await expect(tx).to.emit(ledger, "UsdcRevenueClaimed").withArgs(anyValue, 0, user.address, usdcAmountForBatchAndChain0);

    const usdcAmountForBatchAndChain1 = (await ledger.getUsdcAmountForBatch(0))[1][1];
    const tx2 = await ledger.connect(user).claimUsdcRevenue(user.address, 1);
    await expect(tx2).to.emit(ledger, "UsdcRevenueClaimed").withArgs(anyValue, 1, user.address, usdcAmountForBatchAndChain1);
  });

  it("user can redeem valor more than once to the same batch", async function () {
    const { ledger, orderTokenOft, owner, user, updater, operator } = await ownerStakedAndValorEmissionStarted();

    await ledger.connect(user).setCollectedValor(user.address, 2000);
    await ledger.connect(user).redeemValor(user.address, 0, 1000);
    await ledger.connect(user).redeemValor(user.address, 0, 1000);

    expect(await ledger.getUserRedeemedValorAmountForBatchAndChain(user.address, 0, 0)).to.equal(2000);
  });

  it("user should have no more than 2 BatchedRedemptionRequest at the same time", async function () {
    const { ledger, orderTokenOft, owner, user, updater, operator } = await ownerStakedAndValorEmissionStarted();

    await ledger.connect(user).setCollectedValor(user.address, 3000);
    // User redeem valor to the current batch (0)
    await ledger.connect(user).redeemValor(user.address, chainId, 1000);
    // So, user should have 1 BatchedRedemptionRequest
    expect(await ledger.nuberOfUsersBatchedRedemptionRequests(user.address)).to.equal(1);

    // Batch 1 comes
    await helpers.time.increaseTo((await ledger.getBatchInfo(0))["batchEndTime"] + BigInt(1));
    // User redeem valor to the current batch (1)
    await ledger.connect(user).redeemValor(user.address, chainId, 1000);
    // As batch 0 is not claimable yet, it shouldn't be collected, so user should have 2 BatchedRedemptionRequest
    expect(await ledger.nuberOfUsersBatchedRedemptionRequests(user.address)).to.equal(2);

    // In the normal case admin should prepare batch 0 for claiming before batch 2 comes
    await prepareBatchForClaiming(ledger, owner, 0);

    // Let's move to batch 2
    await helpers.time.increaseTo((await ledger.getBatchInfo(1))["batchEndTime"] + BigInt(1));
    // User redeem valor to the current batch (2)
    await ledger.connect(user).redeemValor(user.address, chainId, 1000);
    // But as batch 0 is claimable, it should be collected during redeeming valor to batch 2
    // So, user should have again 2 BatchedRedemptionRequest:
    // batch 1, that is finished but not claimed yet, and batch 2, that is current
    expect(await ledger.nuberOfUsersBatchedRedemptionRequests(user.address)).to.equal(2);

    await prepareBatchForClaiming(ledger, owner, 1);

    // Let's move to batch 3
    await helpers.time.increaseTo((await ledger.getBatchInfo(2))["batchEndTime"] + BigInt(1));

    await prepareBatchForClaiming(ledger, owner, 2);

    const userUsdcForClaim =
      (BigInt(1000) * (BigInt((await ledger.getBatchInfo(0))["fixedValorToUsdcRateScaled"]) / BigInt(1e9))) / BigInt(1e18) +
      (BigInt(1000) * (BigInt((await ledger.getBatchInfo(1))["fixedValorToUsdcRateScaled"]) / BigInt(1e9))) / BigInt(1e18) +
      (BigInt(1000) * (BigInt((await ledger.getBatchInfo(2))["fixedValorToUsdcRateScaled"]) / BigInt(1e9))) / BigInt(1e18);

    const tx = await ledger.connect(user).claimUsdcRevenue(user.address, chainId);
    await expect(tx).to.emit(ledger, "UsdcRevenueClaimed").withArgs(anyValue, chainId, user.address, userUsdcForClaim);

    // All requests should be collected and claimed
    expect(await ledger.nuberOfUsersBatchedRedemptionRequests(user.address)).to.equal(0);
  });

  it("owner should be able to fix batch price if nobody redeemed valor", async function () {
    const { ledger, orderTokenOft, owner, user, updater, operator } = await ownerStakedAndValorEmissionStarted();

    // Batch 0 is created authomatically
    const batch0EndTime = (await ledger.getBatchInfo(0))["batchEndTime"];
    await helpers.time.increaseTo(batch0EndTime + BigInt(1));

    const usdcRevenueForBatch0 = (await ledger.getTotalValorAmount()) / BigInt(2);
    await ledger.connect(owner).dailyUsdcNetFeeRevenueTestNoSignatureCheck(usdcRevenueForBatch0);

    await ledger.connect(owner).batchPreparedToClaim(0);

    const precision = VALOR_PER_SECOND * BigInt(100);

    const expectedValorToUsdcRateScaled1 = 500000000000000000000000000n;
    const batch0 = await ledger.getBatchInfo(0);
    expect(batch0["fixedValorToUsdcRateScaled"]).to.closeTo(expectedValorToUsdcRateScaled1, precision * BigInt(2));
    expect(batch0["claimable"]).to.equal(true);

    // Let's move to batch 1
    const batch1EndTime = (await ledger.getBatchInfo(1))["batchEndTime"];
    await helpers.time.increaseTo(batch1EndTime + BigInt(1));

    const usdcRevenueForBatch1 = (await ledger.getTotalValorAmount()) - usdcRevenueForBatch0;
    await ledger.connect(owner).dailyUsdcNetFeeRevenueTestNoSignatureCheck(usdcRevenueForBatch1);
    await ledger.connect(owner).batchPreparedToClaim(1);

    const expectedValorToUsdcRateScaled2 = 1000000000000000000000000000n;
    const batch1 = await ledger.getBatchInfo(1);
    expect(batch1["fixedValorToUsdcRateScaled"]).to.closeTo(expectedValorToUsdcRateScaled2, precision * BigInt(2));
    expect(batch1["claimable"]).to.equal(true);
  });

  it("Revenue: pause should fail functions, that requires unpaused state", async function () {
    const { ledger, orderTokenOft, owner, user, updater, operator } = await ownerStakedAndValorEmissionStarted();

    await ledger.connect(owner).pause();
    await expect(ledger.connect(owner).dailyUsdcNetFeeRevenueTestNoSignatureCheck(1000)).to.be.revertedWithCustomError(ledger, "EnforcedPause");
    await expect(ledger.connect(owner).batchPreparedToClaim(0)).to.be.revertedWithCustomError(ledger, "EnforcedPause");
    await expect(ledger.connect(user).redeemValor(user.address, 0, 1000)).to.be.revertedWithCustomError(ledger, "EnforcedPause");
    await expect(ledger.connect(user).claimUsdcRevenue(user.address, 0)).to.be.revertedWithCustomError(ledger, "EnforcedPause");
  });
});
