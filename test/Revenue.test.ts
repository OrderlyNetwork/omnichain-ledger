import { deployments, ethers, upgrades } from "hardhat";
import { BigNumber, Contract, ContractFactory } from "ethers";
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

    // Owner can update the total USDC in the treasure because he granted TREASURE_UPDATER_ROLE
    const tx = await ledger.connect(owner).setTotalUsdcInTreasure(1000);
    await expect(tx).to.emit(ledger, "ValorToUsdcRateUdated").withArgs(500000000000000000n);

    const batchEndTime = (await ledger.getBatchEndTime(batchId)).toNumber();
    await helpers.time.increaseTo(batchEndTime + 1);

    // Now batch is finished and owner can fix the batch price
    await ledger.connect(owner).fixBatchValorToUsdcRate(batchId);
    // Then owner can prepare the batch to be claimed
    await ledger.connect(owner).batchPreparedToClaim(batchId);
  }

  it("check revenue initial state", async function () {
    const { ledger, orderTokenOft, owner, user, updater, operator } = await revenueFixture();

    expect(await ledger.getCurrentBatchId()).to.equal(0);
    const batch0StartTime = await ledger.getBatchStartTime(0);
    const batch0EndTime = await ledger.getBatchEndTime(0);
    expect(batch0EndTime - batch0StartTime).to.equal(60 * 60 * 24 * 14);
    const batch1StartTime = await ledger.getBatchStartTime(1);
    expect(batch1StartTime - batch0EndTime).to.equal(0);

    expect(await ledger.isBatchFinished(0)).to.equal(false);

    const batch0 = await ledger.getBatch(0);
    expect(batch0["claimable"]).to.equal(false);
    expect(batch0["redeemedValorAmount"]).to.equal(0);
    expect(batch0["fixedValorToUsdcRateScaled"]).to.equal(0);
    expect(batch0["chainedValorAmount"]).to.deep.equal([]);

    expect(await ledger.getUsdcAmountForBatch(0)).to.deep.equal([]);

    expect(await ledger.getUserRedeemedValorAmountForBatchAndChain(user.address, 0, 0)).to.equal(0);

    await expect(ledger.getBatch(1)).to.be.revertedWithCustomError(ledger, "BatchIsNotCreatedYet");
  });

  it("user can redeem valor to the current batch", async function () {
    const { ledger, orderTokenOft, owner, user, updater, operator } = await revenueFixture();

    // User can't redeem valor if their collected valor is less than the amount they want to redeem
    await expect(ledger.connect(user).redeemValor(user.address, 0, 1000)).to.be.revertedWithCustomError(ledger, "AmountIsGreaterThanCollectedValor");

    const chainId = 0;
    await ledger.connect(user).setCollectedValor(user.address, 2000);
    await ledger.connect(user).redeemValor(user.address, chainId, 1000);

    expect(await ledger.getCurrentBatchId()).to.equal(0);
    expect(await ledger.getUserRedeemedValorAmountForBatchAndChain(user.address, 0, chainId)).to.equal(1000);

    const batch0EndTime = (await ledger.getBatchEndTime(0)).toNumber();
    await helpers.time.increaseTo(batch0EndTime + 1);

    await ledger.connect(user).redeemValor(user.address, chainId, 1000);

    expect(await ledger.getCurrentBatchId()).to.equal(1);
    expect(await ledger.getUserRedeemedValorAmountForBatchAndChain(user.address, 0, chainId)).to.equal(1000);
    expect(await ledger.getUserRedeemedValorAmountForBatchAndChain(user.address, 1, chainId)).to.equal(1000);
  });

  it("owner can fix batch price", async function () {
    const { ledger, orderTokenOft, owner, user, updater, operator } = await revenueFixture();

    // User can't fix batch price
    await expect(ledger.connect(user).fixBatchValorToUsdcRate(0)).to.be.revertedWith(/AccessControl: account .* is missing role .*/);

    // Owner can't fix batch price if the batch is not finished
    await expect(ledger.connect(owner).fixBatchValorToUsdcRate(0)).to.be.revertedWithCustomError(ledger, "BatchIsNotFinished");

    // Test function to avoid long setup
    await ledger.connect(user).setTotalValorAmount(200);
    expect(await ledger.totalValorAmount()).to.equal(200);

    // Owner can update the total USDC in the treasure because he granted TREASURE_UPDATER_ROLE
    // And it should set the valor to USDC rate to 5
    const tx = await ledger.connect(owner).setTotalUsdcInTreasure(1000);
    await expect(tx).to.emit(ledger, "ValorToUsdcRateUdated").withArgs(5000000000000000000n);

    // Move time to the end of the batch
    const batch0EndTime = (await ledger.getBatchEndTime(0)).toNumber();
    await helpers.time.increaseTo(batch0EndTime + 1);

    // Now batch is finished and owner can fix the batch price
    expect(await ledger.isBatchFinished(0)).to.be.equal(true);
    await ledger.connect(owner).fixBatchValorToUsdcRate(0);

    const batch0 = await ledger.getBatch(0);
    expect(batch0["fixedValorToUsdcRateScaled"]).to.equal(5000000000000000000n);
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
    await ledger.connect(user).setCollectedValor(user.address, 2000);
    await ledger.connect(user).redeemValor(user.address, chainId, 1000);

    await prepareBatchForClaiming(ledger, owner, 0);

    await ledger.connect(user).redeemValor(user.address, chainId, 1000);

    await prepareBatchForClaiming(ledger, owner, 1);

    expect(await ledger.totalValorAmount()).to.equal(1000);

    const tx = await ledger.connect(user).claimUsdcRevenue(user.address, chainId);
    await expect(tx).to.emit(ledger, "UsdcRevenueClaimed").withArgs(anyValue, chainId, user.address, 1000);
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
});
