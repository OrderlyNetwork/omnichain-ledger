import { Contract, ethers } from "ethers";
import { expect } from "chai";
import { anyValue } from "@nomicfoundation/hardhat-chai-matchers/withArgs";
import * as helpers from "@nomicfoundation/hardhat-network-helpers";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import { ledgerFixture, LedgerToken, VALOR_PER_SECOND, VALOR_TO_USDC_RATE_PRECISION } from "./utilities/index";
import { days } from "@nomicfoundation/hardhat-network-helpers/dist/src/helpers/time/duration";

describe("Revenue", function () {
  async function revenueFixture() {
    const { ledger, orderTokenOft, owner, user, updater, operator } = await ledgerFixture();
    const ownerStakeAmount = ethers.parseEther("1");
    await ledger.connect(owner).stake(owner.address, 0, LedgerToken.ORDER, ownerStakeAmount);
    const valorEmissionstart = await ledger.valorEmissionStartTimestamp();
    helpers.time.increaseTo(valorEmissionstart);
    return { ledger, orderTokenOft, owner, user, updater, operator };
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

    const precision = VALOR_PER_SECOND * BigInt(2);

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

  it("user can redeem valor to the current batch", async function () {
    const { ledger, orderTokenOft, owner, user, updater, operator } = await revenueFixture();

    const chainId = 0;

    // User can't redeem zero amount of valor
    await expect(ledger.connect(user).redeemValor(user.address, chainId, 0)).to.be.revertedWithCustomError(ledger, "RedemptionAmountIsZero");

    // User can't redeem valor if their collected valor is less than the amount they want to redeem
    await expect(ledger.connect(user).redeemValor(user.address, chainId, 1000)).to.be.revertedWithCustomError(
      ledger,
      "AmountIsGreaterThanCollectedValor"
    );

    await ledger.connect(user).setCollectedValor(user.address, 2000);
    await ledger.connect(user).redeemValor(user.address, chainId, 1000);

    expect(await ledger.getCurrentBatchId()).to.equal(0);

    const batch0EndTime = (await ledger.getBatchInfo(0))["batchEndTime"];
    await helpers.time.increaseTo(batch0EndTime + BigInt(1));

    await ledger.connect(user).redeemValor(user.address, chainId, 1000);

    expect(await ledger.getCurrentBatchId()).to.equal(1);
  });

  it("user can claim usdc revenue", async function () {
    const { ledger, orderTokenOft, owner, user, updater, operator } = await revenueFixture();

    const chainId = 0;
    // User can't claim usdc revenue if the batch is not claimable
    await expect(ledger.connect(user).claimUsdcRevenue(user.address, chainId))
      .to.be.revertedWithCustomError(ledger, "NothingToClaim")
      .withArgs(user.address, chainId);

    // Redeem valor to the current batch
    await ledger.connect(user).setCollectedValor(user.address, 2000);
    await ledger.connect(user).redeemValor(user.address, chainId, 1000);

    // User still can't claim usdc revenue if the batch is not claimable
    await expect(ledger.connect(user).claimUsdcRevenue(user.address, chainId))
      .to.be.revertedWithCustomError(ledger, "NothingToClaim")
      .withArgs(user.address, chainId);

    // Unprepared batch has zero fixedValorToUsdcRateScaled, so, USDC amount for the batch is zero
    const usdcAmountForBatchAndChainBefore = (await ledger.getUsdcAmountForBatch(0))[0][1];
    expect(usdcAmountForBatchAndChainBefore).to.equal(0n);

    await prepareBatchForClaiming(ledger, owner, 0);

    expect(await ledger.getTotalValorAmount()).to.equal(1000);
    expect(await ledger.totalUsdcInTreasure()).to.equal(500);

    // Now batch is prepared and have fixedValorToUsdcRateScaled, so, USDC amount for the batch is 500
    const usdcAmountForBatchAndChainAfter = (await ledger.getUsdcAmountForBatch(0))[0][1];
    expect(usdcAmountForBatchAndChainAfter).to.equal(500n);

    const tx = await ledger.connect(user).claimUsdcRevenue(user.address, chainId);
    await expect(tx).to.emit(ledger, "UsdcRevenueClaimed").withArgs(anyValue, chainId, user.address, 500);
  });

  it("user can claim usdc revenue for multiple batches", async function () {
    const { ledger, orderTokenOft, owner, user, updater, operator } = await revenueFixture();

    const chainId = 0;
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
    const { ledger, orderTokenOft, owner, user, updater, operator } = await revenueFixture();

    await ledger.connect(user).setCollectedValor(user.address, 2000);
    await ledger.connect(user).redeemValor(user.address, 0, 1000);
    await ledger.connect(user).redeemValor(user.address, 1, 1000);

    await prepareBatchForClaiming(ledger, owner, 0);

    expect(await ledger.getTotalValorAmount()).to.equal(0);

    const tx = await ledger.connect(user).claimUsdcRevenue(user.address, 0);
    await expect(tx).to.emit(ledger, "UsdcRevenueClaimed").withArgs(anyValue, 0, user.address, 500);

    const tx2 = await ledger.connect(user).claimUsdcRevenue(user.address, 1);
    await expect(tx2).to.emit(ledger, "UsdcRevenueClaimed").withArgs(anyValue, 1, user.address, 500);
  });

  it("user can redeem valor more than once to the same batch", async function () {
    const { ledger, orderTokenOft, owner, user, updater, operator } = await revenueFixture();

    await ledger.connect(user).setCollectedValor(user.address, 2000);
    await ledger.connect(user).redeemValor(user.address, 0, 1000);
    await ledger.connect(user).redeemValor(user.address, 0, 1000);

    expect(await ledger.getUserRedeemedValorAmountForBatchAndChain(user.address, 0, 0)).to.equal(2000);
  });

  it("user should have no more than 2 BatchedRedemptionRequest at the same time", async function () {
    const { ledger, orderTokenOft, owner, user, updater, operator } = await revenueFixture();

    const chainId = 0;
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
    const { ledger, orderTokenOft, owner, user, updater, operator } = await revenueFixture();

    // Batch 0 is created authomatically
    const batch0EndTime = (await ledger.getBatchInfo(0))["batchEndTime"];
    await helpers.time.increaseTo(batch0EndTime + BigInt(1));

    await ledger.connect(owner).setTotalValorAmount(2000);
    await ledger.connect(owner).dailyUsdcNetFeeRevenueTestNoSignatureCheck(1000);

    await ledger.connect(owner).batchPreparedToClaim(0);

    const expectedValorToUsdcRateScaled1 = 500000000000000000000000000n;
    const batch0 = await ledger.getBatchInfo(0);
    expect(batch0["fixedValorToUsdcRateScaled"]).to.equal(expectedValorToUsdcRateScaled1);
    expect(batch0["claimable"]).to.equal(true);

    // Let's move to batch 1
    const batch1EndTime = (await ledger.getBatchInfo(1))["batchEndTime"];
    await helpers.time.increaseTo(batch1EndTime + BigInt(1));

    await ledger.connect(owner).dailyUsdcNetFeeRevenueTestNoSignatureCheck(1000);
    await ledger.connect(owner).batchPreparedToClaim(1);

    const expectedValorToUsdcRateScaled2 = 1000000000000000000000000000n;
    const batch1 = await ledger.getBatchInfo(1);
    expect(batch1["fixedValorToUsdcRateScaled"]).to.equal(expectedValorToUsdcRateScaled2);
    expect(batch1["claimable"]).to.equal(true);
  });

  it("Revenue: pause should fail functions, that requires unpaused state", async function () {
    const { ledger, orderTokenOft, owner, user, updater, operator } = await revenueFixture();

    await ledger.connect(owner).pause();
    await expect(ledger.connect(owner).dailyUsdcNetFeeRevenueTestNoSignatureCheck(1000)).to.be.revertedWithCustomError(ledger, "EnforcedPause");
    await expect(ledger.connect(owner).batchPreparedToClaim(0)).to.be.revertedWithCustomError(ledger, "EnforcedPause");
    await expect(ledger.connect(user).redeemValor(user.address, 0, 1000)).to.be.revertedWithCustomError(ledger, "EnforcedPause");
    await expect(ledger.connect(user).claimUsdcRevenue(user.address, 0)).to.be.revertedWithCustomError(ledger, "EnforcedPause");
  });
});
