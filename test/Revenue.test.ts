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

  function amountCloseTo(expectedAmount: BigInt, precision: BigInt) {
    return (_usdcAmount: BigInt) => {
      expect(_usdcAmount).to.be.closeTo(expectedAmount, precision);
      return true;
    };
  }

  async function getExpectedUserUsdcPerBatch(ledger: Contract, userRedeemValor: BigInt, batchId: number) {
    return (
      ((BigInt((await ledger.getBatchInfo(batchId))["fixedValorToUsdcRateScaled"]) / BigInt(1e9)) * BigInt(userRedeemValor.valueOf())) / BigInt(1e18)
    );
  }

  async function waitForLastBatchDay(ledger: Contract) {
    const currentBatchId = await ledger.getCurrentBatchId();
    const batch0EndTime = (await ledger.getBatchInfo(currentBatchId))["batchEndTime"];
    await helpers.time.increaseTo(batch0EndTime - BigInt(days(1)));
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
    const userCollectedValor = await ledger.getUserValor(user.address);

    expect(userCollectedValor).to.be.closeTo(userExpectedCollectedValor, precision);
    expect(await ledger.getCurrentBatchId()).to.equal(0);

    return { ledger, orderTokenOft, owner, user, updater, operator, userCollectedValor };
  }

  async function userRedeemHalhOfUserValor(ledger: Contract, user: SignerWithAddress, chainId: number) {
    const userCollectedValor = await ledger.getUserValor(user.address);
    const userValorToRedeem = userCollectedValor / BigInt(2);
    await ledger.connect(user).redeemValor(user.address, chainId, userValorToRedeem);
    const userLeftValor = await ledger.getUserValor(user.address);
    expect(userLeftValor).to.closeTo(userCollectedValor - userValorToRedeem, precision);
    return userValorToRedeem;
  }

  async function userRedeemedBatch0Finished() {
    const { ledger, orderTokenOft, owner, user, updater, operator, userCollectedValor } = await oneDayBeforeBatch0EndUserCollectedValorFor12Days();

    const userRedeemValor = await userRedeemHalhOfUserValor(ledger, user, chainId);

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

    const { usdcRevenuePerBatch, valorPerBatch } = await prepareBatchForClaiming(ledger, owner, 0);
    const batch0InfoAfterPrepared = await ledger.getBatchInfo(0);
    expect(batch0InfoAfterPrepared["claimable"]).to.equal(true);

    const batch0UsdcAmount =
      (BigInt(batch0InfoAfterPrepared["redeemedValorAmount"]) * BigInt(batch0InfoAfterPrepared["fixedValorToUsdcRateScaled"])) /
      VALOR_TO_USDC_RATE_PRECISION;
    expect(batch0UsdcAmount).to.closeTo(userRedeemValor * BigInt(2), precision);

    return { ledger, orderTokenOft, owner, user, updater, operator, userRedeemValor, usdcRevenuePerBatch, valorPerBatch };
  }

  async function waitForBatchEnd(ledger: Contract, batchId: number) {
    const batchEndTime = (await ledger.getBatchInfo(batchId))["batchEndTime"];
    if (batchEndTime > (await helpers.time.latest())) {
      await helpers.time.increaseTo(batchEndTime + BigInt(1));
    }
  }

  async function setValorToUsdcRateAsTwo(ledger: Contract, owner: SignerWithAddress) {
    const totalValorAmount = await ledger.getTotalValorAmount();
    const totalUsdcInTreasure = await ledger.totalUsdcInTreasure();
    const usdcNetFeeRevenue = (totalValorAmount + VALOR_PER_SECOND) * BigInt(2) - totalUsdcInTreasure;
    await ledger.connect(owner).dailyUsdcNetFeeRevenueTestNoSignatureCheck(usdcNetFeeRevenue);

    const expectedValorToUsdcRateScaled = BigInt(2) * VALOR_TO_USDC_RATE_PRECISION;
    const valorToUsdcRateScaled = await ledger.valorToUsdcRateScaled();

    // It should be exactly equal, but because of the TS BigInt precision, it can be a little bit different
    // BigInt(2e27) == 2000000000000000026575110144n instead of 2000000000000000000000000000n
    expect(valorToUsdcRateScaled).to.be.closeTo(expectedValorToUsdcRateScaled, precision);

    return usdcNetFeeRevenue;
  }

  async function calculateValorPerBatch(ledger: Contract, batchId: number) {
    const batchInfo = await ledger.getBatchInfo(batchId);
    const valorEmissionStartTimestamp = await ledger.valorEmissionStartTimestamp();
    const batchStartTimestamp = batchInfo["batchStartTime"];
    const batchEndTimestamp = batchInfo["batchEndTime"];
    const valorEmissionLengthInSeconds =
      batchStartTimestamp < valorEmissionStartTimestamp
        ? BigInt(batchEndTimestamp - valorEmissionStartTimestamp)
        : BigInt(batchEndTimestamp - batchStartTimestamp);
    return VALOR_PER_SECOND * valorEmissionLengthInSeconds;
  }

  async function prepareBatchForClaiming(ledger: Contract, owner: SignerWithAddress, batchId: number) {
    await waitForBatchEnd(ledger, batchId);
    const usdcRevenuePerBatch = await setValorToUsdcRateAsTwo(ledger, owner);

    // Then owner can prepare the batch to be claimed
    await ledger.connect(owner).batchPreparedToClaim(batchId);

    const batchInfoAfter = await ledger.getBatchInfo(batchId);
    expect(batchInfoAfter["claimable"]).to.equal(true);

    const expectedValorToUsdcRateScaled = BigInt(2) * VALOR_TO_USDC_RATE_PRECISION;
    expect(batchInfoAfter["fixedValorToUsdcRateScaled"]).to.closeTo(expectedValorToUsdcRateScaled, precision);

    const valorPerBatch = await calculateValorPerBatch(ledger, batchId);
    return { usdcRevenuePerBatch, valorPerBatch };
  }

  it("check revenue initial state", async function () {
    const { ledger } = await revenueFixture();

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
    const { ledger, owner, user } = await revenueFixture();

    await ledger.connect(owner).setValorEmissionStartTimestamp((await helpers.time.latest()) + days(2));

    await stakeWaitForEmissionStartAndCheckBalance(ledger, user, USER_STAKE_AMOUNT);

    await helpers.time.increaseTo((await helpers.time.latest()) + days(1));

    expect(await ledger.getUserValor(user.address)).to.be.closeTo(VALOR_PER_DAY, precision);
    expect(await ledger.getTotalValorEmitted()).to.be.closeTo(VALOR_PER_DAY, precision);
    expect(await ledger.getTotalValorAmount()).to.be.closeTo(VALOR_PER_DAY, precision);
  });

  it("redeem valor unsuccessful cases", async function () {
    const { ledger, user } = await ownerStakedAndValorEmissionStarted();

    // User can't redeem zero amount of valor
    await expect(ledger.connect(user).redeemValor(user.address, chainId, 0)).to.be.revertedWithCustomError(ledger, "RedemptionAmountIsZero");

    // User can't redeem valor if their collected valor is less than the amount they want to redeem
    await expect(ledger.connect(user).redeemValor(user.address, chainId, 1000)).to.be.revertedWithCustomError(
      ledger,
      "AmountIsGreaterThanCollectedValor"
    );
  });

  it("user can redeem valor to the current batch", async function () {
    const { ledger, user } = await userRedeemedBatch0PreparedForClaiming();

    expect(await ledger.getCurrentBatchId()).to.equal(1);
    const userValor = await ledger.getUserValor(user.address);
    await ledger.connect(user).redeemValor(user.address, chainId, userValor);
  });

  it("claim usdc revenue unsuccessful cases", async function () {
    const { ledger, user } = await userRedeemedBatch0Finished();

    // User can't claim usdc revenue if the batch is not claimable
    await expect(ledger.connect(user).claimUsdcRevenue(user.address, chainId)).to.be.revertedWithCustomError(ledger, "NothingToClaim");
  });

  it("user can claim usdc revenue", async function () {
    const { ledger, user, userRedeemValor } = await userRedeemedBatch0PreparedForClaiming();

    const userUsdcRevenueForBatch0 = await getExpectedUserUsdcPerBatch(ledger, userRedeemValor, 0);
    const usdcAmountForBatch0 = (await ledger.getUsdcAmountForBatch(0))[0][1];

    expect(userUsdcRevenueForBatch0).to.be.closeTo(usdcAmountForBatch0, precision);

    const tx = await ledger.connect(user).claimUsdcRevenue(user.address, chainId);
    await expect(tx)
      .to.emit(ledger, "UsdcRevenueClaimed")
      .withArgs(anyValue, chainId, user.address, amountCloseTo(userUsdcRevenueForBatch0, precision));
  });

  it("user can claim usdc revenue for multiple batches", async function () {
    const { ledger, owner, user, userRedeemValor: userRedeemValorForBatch0 } = await userRedeemedBatch0PreparedForClaiming();
    const userExpectedUsdcRevenueForBatch0 = await getExpectedUserUsdcPerBatch(ledger, userRedeemValorForBatch0, 0);

    const userRedeemValorForBatch1 = await userRedeemHalhOfUserValor(ledger, user, chainId);
    await prepareBatchForClaiming(ledger, owner, 1);
    const userExpectedUsdcRevenueForBatch1 = await getExpectedUserUsdcPerBatch(ledger, userRedeemValorForBatch1, 1);

    const userRedeemValorForBatch2 = await userRedeemHalhOfUserValor(ledger, user, chainId);
    await prepareBatchForClaiming(ledger, owner, 2);
    const userExpectedUsdcRevenueForBatch2 = await getExpectedUserUsdcPerBatch(ledger, userRedeemValorForBatch2, 2);

    const tx = await ledger.connect(user).claimUsdcRevenue(user.address, chainId);

    await expect(tx)
      .to.emit(ledger, "UsdcRevenueClaimed")
      .withArgs(
        anyValue,
        chainId,
        user.address,
        amountCloseTo(userExpectedUsdcRevenueForBatch0 + userExpectedUsdcRevenueForBatch1 + userExpectedUsdcRevenueForBatch2, precision)
      );
  });

  it("user can claim usdc revenue for multiple chains", async function () {
    const { ledger, owner, user } = await userStakedAndValorEmissionStarted();

    await waitForLastBatchDay(ledger);
    const userRedeemValorForChain0 = await userRedeemHalhOfUserValor(ledger, user, 0);
    const userRedeemValorForChain1 = await userRedeemHalhOfUserValor(ledger, user, 1);
    await prepareBatchForClaiming(ledger, owner, 0);

    const userExpectedUsdcRevenueForChain0 = await getExpectedUserUsdcPerBatch(ledger, userRedeemValorForChain0, 0);
    const tx = await ledger.connect(user).claimUsdcRevenue(user.address, 0);
    await expect(tx)
      .to.emit(ledger, "UsdcRevenueClaimed")
      .withArgs(anyValue, 0, user.address, amountCloseTo(userExpectedUsdcRevenueForChain0, precision));

    const userExpectedUsdcRevenueForChain1 = await getExpectedUserUsdcPerBatch(ledger, userRedeemValorForChain1, 0);
    const tx2 = await ledger.connect(user).claimUsdcRevenue(user.address, 1);
    await expect(tx2)
      .to.emit(ledger, "UsdcRevenueClaimed")
      .withArgs(anyValue, 1, user.address, amountCloseTo(userExpectedUsdcRevenueForChain1, precision));
  });

  it("user can redeem valor more than once to the same batch", async function () {
    const { ledger, owner, user } = await userStakedAndValorEmissionStarted();

    await waitForLastBatchDay(ledger);
    const userRedeemValor1 = await userRedeemHalhOfUserValor(ledger, user, chainId);
    const userRedeemValor2 = await userRedeemHalhOfUserValor(ledger, user, chainId);
    await prepareBatchForClaiming(ledger, owner, 0);

    expect(await ledger.getUserRedeemedValorAmountForBatchAndChain(user.address, 0, chainId)).to.equal(userRedeemValor1 + userRedeemValor2);
    const userExpectedUsdcRevenueForChain0 = await getExpectedUserUsdcPerBatch(ledger, userRedeemValor1 + userRedeemValor2, 0);
    const tx2 = await ledger.connect(user).claimUsdcRevenue(user.address, chainId);
    await expect(tx2)
      .to.emit(ledger, "UsdcRevenueClaimed")
      .withArgs(anyValue, chainId, user.address, amountCloseTo(userExpectedUsdcRevenueForChain0, precision));
  });

  it("user should have no more than 2 BatchedRedemptionRequest at the same time", async function () {
    const { ledger, owner, user } = await userStakedAndValorEmissionStarted();

    await waitForLastBatchDay(ledger);
    // User redeem valor to the current batch (0)
    const userRedeemValorForBatch0 = await userRedeemHalhOfUserValor(ledger, user, chainId);
    // So, user should have 1 BatchedRedemptionRequest
    expect(await ledger.nuberOfUsersBatchedRedemptionRequests(user.address)).to.equal(1);

    // Batch 1 comes
    await helpers.time.increaseTo((await ledger.getBatchInfo(0))["batchEndTime"] + BigInt(1));
    // Assure that batch 1 started
    expect(await ledger.getCurrentBatchId()).to.equal(1);
    // User redeem valor to the current batch (1)
    const userRedeemValorForBatch1 = await userRedeemHalhOfUserValor(ledger, user, chainId);
    // As batch 0 is not claimable yet, it shouldn't be collected, so user should have 2 BatchedRedemptionRequest
    expect(await ledger.nuberOfUsersBatchedRedemptionRequests(user.address)).to.equal(2);

    // In the normal case admin should prepare batch 0 for claiming before batch 2 comes
    await prepareBatchForClaiming(ledger, owner, 0);

    // Let's move to batch 2
    await helpers.time.increaseTo((await ledger.getBatchInfo(1))["batchEndTime"] + BigInt(1));
    // Assure that batch 2 started
    expect(await ledger.getCurrentBatchId()).to.equal(2);
    // User redeem valor to the current batch (2)
    const userRedeemValorForBatch2 = await userRedeemHalhOfUserValor(ledger, user, chainId);
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

    const tx = await ledger.connect(user).claimUsdcRevenue(user.address, chainId);
    await expect(tx)
      .to.emit(ledger, "UsdcRevenueClaimed")
      .withArgs(anyValue, chainId, user.address, amountCloseTo(userxpectedUsdcForClaim, precision));

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
    expect(batchInfo0["fixedValorToUsdcRateScaled"]).to.closeTo(expectedValorToUsdcRateScaled1, precision);
    expect(batchInfo0["claimable"]).to.equal(true);

    // Let's move to batch 1
    await helpers.time.increaseTo((await ledger.getBatchInfo(1))["batchEndTime"] + BigInt(1));

    const usdcRevenueForBatch1 = (await ledger.getTotalValorAmount()) + VALOR_PER_SECOND - usdcRevenueForBatch0;
    await ledger.connect(owner).dailyUsdcNetFeeRevenueTestNoSignatureCheck(usdcRevenueForBatch1);
    await ledger.connect(owner).batchPreparedToClaim(1);

    const expectedValorToUsdcRateScaled2 = 1000000000000000000000000000n;
    const batchInfo1 = await ledger.getBatchInfo(1);

    expect(batchInfo1["fixedValorToUsdcRateScaled"]).to.closeTo(expectedValorToUsdcRateScaled2, precision);
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
