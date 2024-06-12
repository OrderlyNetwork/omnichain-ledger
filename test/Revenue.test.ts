import { Contract } from "ethers";
import { expect } from "chai";
import { anyValue } from "@nomicfoundation/hardhat-chai-matchers/withArgs";
import * as helpers from "@nomicfoundation/hardhat-network-helpers";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import { ledgerFixture } from "./utilities/index";

describe("Revenue", function () {
  async function revenueFixture() {
    const { ledger, orderTokenOft, owner, user, updater, operator } = await ledgerFixture();
    return { ledger, orderTokenOft, owner, user, updater, operator };
  }

  async function prepareBatchForClaiming(ledger: Contract, owner: SignerWithAddress, batchId: number) {
    await ledger.connect(owner).setTotalValorAmount(2000);

    const previousTotalUsdcInTreasure = await ledger.totalUsdcInTreasure();
    const dailyUsdcNetFeeRevenue = BigInt(1000);
    const totalValorAmountBefore = await ledger.totalValorAmount();
    // Here split precision to 1e18 and 1e9 to avoid overflow
    const valorToUsdcRateScaled =
      (((previousTotalUsdcInTreasure + dailyUsdcNetFeeRevenue) * BigInt(1e18)) / BigInt(totalValorAmountBefore)) * BigInt(1e9);

    // Owner can update the total USDC in the treasure because he granted TREASURE_UPDATER_ROLE
    const tx = await ledger.connect(owner).dailyUsdcNetFeeRevenueTestNoSignatureCheck(dailyUsdcNetFeeRevenue);
    await expect(tx)
      .to.emit(ledger, "DailyUsdcNetFeeRevenueUpdated")
      .withArgs(
        anyValue,
        dailyUsdcNetFeeRevenue,
        previousTotalUsdcInTreasure + dailyUsdcNetFeeRevenue,
        totalValorAmountBefore,
        valorToUsdcRateScaled
      );

    const batchEndTime = (await ledger.getBatchInfo(batchId))["batchEndTime"];
    if (batchEndTime > (await helpers.time.latest())) {
      await helpers.time.increaseTo(batchEndTime + BigInt(1));
    }

    // Now batch is finished and owner can fix the batch price
    await ledger.connect(owner).fixBatchValorToUsdcRate(batchId);
    // Then owner can prepare the batch to be claimed
    await ledger.connect(owner).batchPreparedToClaim(batchId);
    const batchInfo = await ledger.getBatchInfo(batchId);
    expect(batchInfo["claimable"]).to.equal(true);
    expect(batchInfo["fixedValorToUsdcRateScaled"]).to.equal(valorToUsdcRateScaled);
    const totalValorAmountAfter = Number(await ledger.totalValorAmount());
    expect(totalValorAmountAfter).to.equal(totalValorAmountBefore - batchInfo["redeemedValorAmount"]);
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

    expect(await ledger.getUserRedeemedValorAmountForBatchAndChain(user.address, 0, 0)).to.equal(0);
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
    expect(await ledger.getUserRedeemedValorAmountForBatchAndChain(user.address, 0, chainId)).to.equal(1000);

    const batch0EndTime = (await ledger.getBatchInfo(0))["batchEndTime"];
    await helpers.time.increaseTo(batch0EndTime + BigInt(1));

    await ledger.connect(user).redeemValor(user.address, chainId, 1000);

    expect(await ledger.getCurrentBatchId()).to.equal(1);
    expect(await ledger.getUserRedeemedValorAmountForBatchAndChain(user.address, 0, chainId)).to.equal(1000);
    expect(await ledger.getUserRedeemedValorAmountForBatchAndChain(user.address, 1, chainId)).to.equal(1000);
  });

  it("owner can fix batch price", async function () {
    const { ledger, orderTokenOft, owner, user, updater, operator } = await revenueFixture();

    // User can't fix batch price
    await expect(ledger.connect(user).fixBatchValorToUsdcRate(0)).to.be.revertedWithCustomError(ledger, "AccessControlUnauthorizedAccount");

    // Owner can't fix batch price if the batch is not finished
    await expect(ledger.connect(owner).fixBatchValorToUsdcRate(0)).to.be.revertedWithCustomError(ledger, "BatchIsNotFinished");

    // Test function to avoid long setup
    await ledger.connect(user).setTotalValorAmount(200);
    expect(await ledger.totalValorAmount()).to.equal(200);

    const expectedValorToUsdcRateScaled = 5000000000000000000000000000n;
    // Owner can update the total USDC in the treasure because he granted TREASURE_UPDATER_ROLE
    // And it should set the valor to USDC rate to 5
    const tx = await ledger.connect(owner).dailyUsdcNetFeeRevenueTestNoSignatureCheck(1000);
    await expect(tx).to.emit(ledger, "DailyUsdcNetFeeRevenueUpdated").withArgs(anyValue, 1000, 1000, 200, expectedValorToUsdcRateScaled);

    // Move time to the end of the batch
    const batch0EndTime = (await ledger.getBatchInfo(0))["batchEndTime"];
    await helpers.time.increaseTo(batch0EndTime + BigInt(1));

    // Owner can't make the batch claimable if the batch valor to USDC rate is not set
    await expect(ledger.connect(owner).batchPreparedToClaim(0)).to.be.revertedWithCustomError(ledger, "BatchValorToUsdcRateIsNotFixed");

    await ledger.connect(owner).fixBatchValorToUsdcRate(0);

    const batch0 = await ledger.getBatchInfo(0);
    expect(batch0["fixedValorToUsdcRateScaled"]).to.equal(expectedValorToUsdcRateScaled);
    expect(batch0["claimable"]).to.equal(false);
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

    await prepareBatchForClaiming(ledger, owner, 0);

    expect(await ledger.totalValorAmount()).to.equal(1000);
    expect(await ledger.totalUsdcInTreasure()).to.equal(500);

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
    // const userUsdcForBatch1 =
    //   (BigInt(redeemValorAmountForBatch1) * (BigInt((await ledger.getBatchInfo(1))["fixedValorToUsdcRateScaled"]) / BigInt(1e9))) / BigInt(1e18);

    // expect(await ledger.collectedValor(user.address)).to.equal(0);

    // const tx = await ledger.connect(user).claimUsdcRevenue(user.address, chainId);
    // await expect(tx)
    //   .to.emit(ledger, "UsdcRevenueClaimed")
    //   .withArgs(anyValue, chainId, user.address, userUsdcForBatch0 + userUsdcForBatch1);
  });

  it("user can claim usdc revenue for multiple chains", async function () {
    const { ledger, orderTokenOft, owner, user, updater, operator } = await revenueFixture();

    await ledger.connect(user).setCollectedValor(user.address, 2000);
    await ledger.connect(user).redeemValor(user.address, 0, 1000);
    await ledger.connect(user).redeemValor(user.address, 1, 1000);

    await prepareBatchForClaiming(ledger, owner, 0);

    expect(await ledger.totalValorAmount()).to.equal(0);

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

    await ledger.connect(user).setCollectedValor(user.address, 3000);
    // User redeem valor to the current batch (0)
    await ledger.connect(user).redeemValor(user.address, 0, 1000);
    // So, user should have 1 BatchedRedemptionRequest
    expect(await ledger.nuberOfUsersBatchedRedemptionRequests(user.address)).to.equal(1);

    // Batch 1 comes
    helpers.time.increaseTo((await ledger.getBatchInfo(0))["batchEndTime"] + BigInt(1));
    // User redeem valor to the current batch (1)
    await ledger.connect(user).redeemValor(user.address, 0, 1000);
    // As batch 0 is not claimable yet, it shouldn't be collected, so user should have 2 BatchedRedemptionRequest
    expect(await ledger.nuberOfUsersBatchedRedemptionRequests(user.address)).to.equal(2);

    // In the normal case admin should prepare batch 0 for claiming before batch 2 comes
    await prepareBatchForClaiming(ledger, owner, 0);

    // Let's move to batch 2
    helpers.time.increaseTo((await ledger.getBatchInfo(1))["batchEndTime"] + BigInt(1));
    // User redeem valor to the current batch (2)
    await ledger.connect(user).redeemValor(user.address, 0, 1000);
    // But as batch 0 is claimable, it should be collected during redeeming valor to batch 2
    // So, user should have again 2 BatchedRedemptionRequest:
    // batch 1, that is finished but not claimed yet, and batch 2, that is current
    expect(await ledger.nuberOfUsersBatchedRedemptionRequests(user.address)).to.equal(2);
  });

  it("owner should be able to fix batch price if nobody redeemed valor", async function () {
    const { ledger, orderTokenOft, owner, user, updater, operator } = await revenueFixture();

    await ledger.connect(owner).setTotalValorAmount(2000);
    await ledger.connect(owner).dailyUsdcNetFeeRevenueTestNoSignatureCheck(1000);

    // Batch 0 is created authomatically
    const batch0EndTime = (await ledger.getBatchInfo(0))["batchEndTime"];
    await helpers.time.increaseTo(batch0EndTime + BigInt(1));

    await ledger.connect(owner).fixBatchValorToUsdcRate(0);
    await ledger.connect(owner).batchPreparedToClaim(0);

    const expectedValorToUsdcRateScaled = 500000000000000000000000000n;
    const batch0 = await ledger.getBatchInfo(0);
    expect(batch0["fixedValorToUsdcRateScaled"]).to.equal(expectedValorToUsdcRateScaled);
    expect(batch0["claimable"]).to.equal(true);

    // Let's move to batch 1
    const batch1EndTime = (await ledger.getBatchInfo(1))["batchEndTime"];
    await helpers.time.increaseTo(batch1EndTime + BigInt(1));

    await ledger.connect(owner).fixBatchValorToUsdcRate(1);
    await ledger.connect(owner).batchPreparedToClaim(1);

    const batch1 = await ledger.getBatchInfo(1);
    expect(batch1["fixedValorToUsdcRateScaled"]).to.equal(expectedValorToUsdcRateScaled);
    expect(batch1["claimable"]).to.equal(true);
  });

  it("Revenue: pause should fail functions, that requires unpaused state", async function () {
    const { ledger, orderTokenOft, owner, user, updater, operator } = await revenueFixture();

    await ledger.connect(owner).pause();
    await expect(ledger.connect(owner).fixBatchValorToUsdcRate(0)).to.be.revertedWithCustomError(ledger, "EnforcedPause");
    await expect(ledger.connect(owner).batchPreparedToClaim(0)).to.be.revertedWithCustomError(ledger, "EnforcedPause");
    await expect(ledger.connect(user).redeemValor(user.address, 0, 1000)).to.be.revertedWithCustomError(ledger, "EnforcedPause");
    await expect(ledger.connect(user).claimUsdcRevenue(user.address, 0)).to.be.revertedWithCustomError(ledger, "EnforcedPause");
  });
});
