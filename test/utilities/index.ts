import { deployments, ethers, upgrades } from "hardhat";
import { BigNumberish, ContractFactory } from "ethers";
import { expect } from "chai";
import * as helpers from "@nomicfoundation/hardhat-network-helpers";
import { days } from "@nomicfoundation/hardhat-network-helpers/dist/src/helpers/time/duration";
import { HardhatEthersSigner, SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";

import { LedgerTest } from "../../types/contracts/test";
import { anyValue } from "@nomicfoundation/hardhat-chai-matchers/withArgs";

export const BASE_TEN = 10;
export const INITIAL_SUPPLY = fullTokens(1_000_000);
export const INITIAL_SUPPLY_STR = INITIAL_SUPPLY.toString();
export const TOTAL_SUPPLY = BigInt(2) * INITIAL_SUPPLY;
export const TOTAL_SUPPLY_STR = TOTAL_SUPPLY.toString();
export const ONE_HOUR_IN_SECONDS = 60 * 60;
export const ONE_DAY_IN_SECONDS = ONE_HOUR_IN_SECONDS * 24;
export const ONE_WEEK_IN_SECONDS = ONE_DAY_IN_SECONDS * 7;
export const ONE_YEAR_IN_SECONDS = ONE_DAY_IN_SECONDS * 365;
export const HALF_YEAR_IN_SECONDS = ONE_YEAR_IN_SECONDS / 2;
export const VALOR_MAXIMUM_EMISSION = fullTokens(1_000_000_000);
export const VALOR_EMISSION_DURATION = 200 * 14 * ONE_DAY_IN_SECONDS;
export const VALOR_PER_SECOND = VALOR_MAXIMUM_EMISSION / BigInt(VALOR_EMISSION_DURATION);
export const VALOR_PER_HOUR = VALOR_PER_SECOND * BigInt(ONE_HOUR_IN_SECONDS);
export const VALOR_PER_DAY = VALOR_PER_SECOND * BigInt(ONE_DAY_IN_SECONDS);
export const VALOR_PER_BATCH = VALOR_PER_DAY * BigInt(14);
export const VALOR_TO_USDC_RATE_PRECISION = BigInt(1e27);
// Let's make precision in 2 seconds Valor emission rate for transactions
export const VALOR_CHECK_PRECISION = VALOR_PER_SECOND * BigInt(2);
export const CHAIN_ID_0 = 0;
export const USDC_UPDATER_ADDRESS = "0x6a9961ace9bf0c1b8b98ba11558a4125b1f5ea3f";
export const USER_STAKE_AMOUNT = ethers.parseEther("1000");

// Defaults to e18 using amount * 10^18
export function fullTokens(amount: BigNumberish, decimals = 18): bigint {
  return BigInt(amount) * BigInt(BASE_TEN) ** BigInt(decimals);
}

export function abs(value: BigNumberish): bigint {
  return BigInt(value) >= 0 ? BigInt(value) : -BigInt(value);
}

export function closeTo(value: BigNumberish, target: BigNumberish, precision: BigNumberish): boolean {
  return abs(BigInt(value) - BigInt(target)) <= BigInt(precision);
}

export enum LedgerToken {
  ORDER,
  ESORDER
}

export async function ledgerFixture() {
  const ledgerCF = await ethers.getContractFactory("LedgerTest");
  const orderTokenOftCF = await ethers.getContractFactory("OrderTokenOFT");

  const [owner, user, updater, operator, orderCollector] = await ethers.getSigners();

  // The EndpointV2Mock contract comes from @layerzerolabs/test-devtools-evm-hardhat package
  // and its artifacts are connected as external artifacts to this project
  //
  // Unfortunately, hardhat itself does not yet provide a way of connecting external artifacts
  // so we rely on hardhat-deploy to create a ContractFactory for EndpointV2Mock
  //
  // See https://github.com/NomicFoundation/hardhat/issues/1040
  const eidA = 1;
  const EndpointV2MockArtifact = await deployments.getArtifact("EndpointV2Mock");
  const EndpointV2Mock = new ContractFactory(EndpointV2MockArtifact.abi, EndpointV2MockArtifact.bytecode, owner);
  const mockEndpointA = await EndpointV2Mock.deploy(eidA);
  const mockEndpointAAddress = await mockEndpointA.getAddress();

  const orderTokenOft = await orderTokenOftCF.deploy(owner.address, TOTAL_SUPPLY, mockEndpointAAddress);

  const ledger = (await upgrades.deployProxy(ledgerCF, [owner.address, mockEndpointAAddress, VALOR_PER_SECOND, VALOR_MAXIMUM_EMISSION], {
    kind: "uups"
  })) as unknown as LedgerTest;
  await ledger.connect(owner).grantRole(await ledger.ROOT_UPDATER_ROLE(), updater.address);
  await ledger.connect(owner).setUsdcUpdaterAddress(USDC_UPDATER_ADDRESS);

  // console.log("owner: ", owner.address);
  // console.log("updater: ", updater.address);
  // console.log("ledger: ", ledger.address);

  return { ledger, orderTokenOft, owner, user, updater, operator };
}

// ================ HELPER FUNCTIONS ================

/// Predicate to check event value params
export function amountCloseTo(expectedAmount: BigInt, precision: BigInt) {
  return (_usdcAmount: BigInt) => {
    expect(_usdcAmount).to.be.closeTo(expectedAmount, precision);
    return true;
  };
}

/// Calculate expected user USDC per batch based on user redeem valor and batchId
export async function getExpectedUserUsdcPerBatch(ledger: LedgerTest, userRedeemValor: BigInt, batchId: number) {
  return (
    ((BigInt((await ledger.getBatchInfo(batchId))["fixedValorToUsdcRateScaled"]) / BigInt(1e9)) * BigInt(userRedeemValor.valueOf())) / BigInt(1e18)
  );
}

/// Increase time to the start of last batch day
export async function waitForLastDayOfCurrentBatch(ledger: LedgerTest) {
  const currentBatchId = await ledger.getCurrentBatchId();
  const batch0EndTime = (await ledger.getBatchInfo(currentBatchId))["batchEndTime"];
  await helpers.time.increaseTo(batch0EndTime - BigInt(days(1)));
}

export async function waitForEmissionStart(ledger: LedgerTest) {
  const valorEmissionStart = await ledger.valorEmissionStartTimestamp();
  if ((await helpers.time.latest()) < valorEmissionStart) {
    await helpers.time.increaseTo(valorEmissionStart);
  }
}

/// User mckes a stake and waits for valor emission to start. Check user staking balance and valor emission
export async function userStakedAndWaitForEmissionStart(ledger: LedgerTest, user: HardhatEthersSigner, stakeAmount: BigInt) {
  const tx = await ledger.connect(user).stake(user.address, CHAIN_ID_0, LedgerToken.ORDER, stakeAmount.valueOf());
  // Check the Staked event is emitted correctly
  await expect(tx).to.emit(ledger, "Staked").withArgs(anyValue, CHAIN_ID_0, user.address, stakeAmount.valueOf(), LedgerToken.ORDER);

  expect(await ledger.userTotalStakingBalance(user.address)).to.equal(stakeAmount.valueOf());

  await waitForEmissionStart(ledger);

  expect(await ledger.userTotalStakingBalance(user.address)).to.equal(stakeAmount);
  expect(await ledger.getUserValor(user.address)).to.equal(0);
  expect(await ledger.getTotalValorEmitted()).to.equal(0);
  expect(await ledger.getTotalValorAmount()).to.equal(0);
}

/// User redeem half of collected valor
export async function userRedeemHalhOfUserValor(ledger: LedgerTest, user: SignerWithAddress, chainId: number) {
  const userCollectedValor = await ledger.getUserValor(user.address);
  const userValorToRedeem = userCollectedValor / BigInt(2);
  await ledger.connect(user).redeemValor(user.address, chainId, userValorToRedeem);
  const userLeftValor = await ledger.getUserValor(user.address);
  expect(userLeftValor).to.closeTo(userCollectedValor - userValorToRedeem, VALOR_CHECK_PRECISION);
  return userValorToRedeem;
}

/// Wait time to the end of batch
export async function waitForBatchEnd(ledger: LedgerTest, batchId: number) {
  const batchEndTime = (await ledger.getBatchInfo(batchId))["batchEndTime"];
  if (batchEndTime > (await helpers.time.latest())) {
    await helpers.time.increaseTo(batchEndTime + BigInt(1));
  }
}

/// Provide contract with USDC revenue in amount to set valorToUsdcRate as 2 (scaled my 1e27)
export async function setValorToUsdcRateAsTwo(ledger: LedgerTest, owner: SignerWithAddress) {
  const totalValorAmount = await ledger.getTotalValorAmount();
  const totalUsdcInTreasure = await ledger.totalUsdcInTreasure();
  const usdcNetFeeRevenue = (totalValorAmount + VALOR_PER_SECOND) * BigInt(2) - totalUsdcInTreasure;
  await ledger.connect(owner).dailyUsdcNetFeeRevenueTestNoSignatureCheck(usdcNetFeeRevenue);

  const expectedValorToUsdcRateScaled = BigInt(2) * VALOR_TO_USDC_RATE_PRECISION;
  const valorToUsdcRateScaled = await ledger.valorToUsdcRateScaled();

  // It should be exactly equal, but because of the TS BigInt TWO_SECONDS_PRECISION, it can be a little bit different
  // BigInt(2e27) == 2000000000000000026575110144n instead of 2000000000000000000000000000n
  expect(valorToUsdcRateScaled).to.be.closeTo(expectedValorToUsdcRateScaled, VALOR_CHECK_PRECISION);

  return usdcNetFeeRevenue;
}

/// Calculate valor amount emitted by batch (batch 0 emission is less than 14 days)
export async function calculateValorPerBatch(ledger: LedgerTest, batchId: number) {
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

/// Prepare batch with batchId to be claimed
export async function prepareBatchForClaiming(ledger: LedgerTest, owner: SignerWithAddress, batchId: number) {
  await waitForBatchEnd(ledger, batchId);
  const usdcRevenuePerBatch = await setValorToUsdcRateAsTwo(ledger, owner);

  // Then owner can prepare the batch to be claimed
  await ledger.connect(owner).batchPreparedToClaim(batchId);

  const batchInfoAfter = await ledger.getBatchInfo(batchId);
  expect(batchInfoAfter["claimable"]).to.equal(true);

  const expectedValorToUsdcRateScaled = BigInt(2) * VALOR_TO_USDC_RATE_PRECISION;
  expect(batchInfoAfter["fixedValorToUsdcRateScaled"]).to.closeTo(expectedValorToUsdcRateScaled, VALOR_CHECK_PRECISION);

  const valorPerBatch = await calculateValorPerBatch(ledger, batchId);
  return { usdcRevenuePerBatch, valorPerBatch };
}

export async function checkUserStakingBalance(ledger: LedgerTest, user: SignerWithAddress, orderBalance: BigInt, esOrderBalance: BigInt) {
  const userStakingBalance = await ledger.getStakingInfo(user.address);
  expect(userStakingBalance["orderBalance"]).to.equal(orderBalance);
  expect(userStakingBalance["esOrderBalance"]).to.equal(esOrderBalance);
  expect(await ledger.userTotalStakingBalance(user.address)).to.equal(orderBalance.valueOf() + esOrderBalance.valueOf());
}

export async function checkUserPendingUnstake(ledger: LedgerTest, user: SignerWithAddress, balanceOrder: BigInt, unlockTimestamp: number) {
  const userPendingUnstake2 = await ledger.userPendingUnstake(user.address);
  expect(userPendingUnstake2["balanceOrder"]).to.equal(balanceOrder);
  expect(userPendingUnstake2["unlockTimestamp"]).closeTo(unlockTimestamp, 2);
}
//================ CONTRACT STATES ================
/// Case when just owner stakes and valor emission starts
export async function ownerStakedAndValorEmissionStarted() {
  const { ledger, orderTokenOft, owner, user, updater, operator } = await ledgerFixture();

  // Owner makes a stake to prevent totalStakedAmount be zero when valor emission starts
  await userStakedAndWaitForEmissionStart(ledger, owner, ethers.parseEther("1"));
  return { ledger, orderTokenOft, owner, user, updater, operator };
}

/// Case when user stakes and valor emission starts
export async function userStakedAndValorEmissionStarted() {
  const { ledger, orderTokenOft, owner, user, updater, operator } = await ledgerFixture();

  // User makes a stake to start collecting valor after valor emission started
  await userStakedAndWaitForEmissionStart(ledger, user, USER_STAKE_AMOUNT);
  return { ledger, orderTokenOft, owner, user, updater, operator };
}

/// User made stake and wait 12 days to collect valor.
/// So, now 13 day (1 day for emiiion start + 12 days). One day left to end of batch 0
export async function oneDayBeforeBatch0EndUserCollectedValorFor12Days() {
  const { ledger, orderTokenOft, owner, user, updater, operator } = await userStakedAndValorEmissionStarted();

  const batch0EndTime = (await ledger.getBatchInfo(0))["batchEndTime"];
  await helpers.time.increaseTo(batch0EndTime - BigInt(days(1)));

  const userExpectedCollectedValor = VALOR_PER_DAY * BigInt(13);
  const userCollectedValor = await ledger.getUserValor(user.address);

  expect(userCollectedValor).to.be.closeTo(userExpectedCollectedValor, VALOR_CHECK_PRECISION);
  expect(await ledger.getCurrentBatchId()).to.equal(0);

  return { ledger, orderTokenOft, owner, user, updater, operator, userCollectedValor };
}

/// User redeem half of collected valor and batch 0 finished
export async function userRedeemedAndBatch0Finished() {
  const { ledger, orderTokenOft, owner, user, updater, operator, userCollectedValor } = await oneDayBeforeBatch0EndUserCollectedValorFor12Days();

  const userRedeemValor = await userRedeemHalhOfUserValor(ledger, user, CHAIN_ID_0);

  const batch0Info = await ledger.getBatchInfo(0);
  expect(batch0Info["claimable"]).to.equal(false);
  expect(batch0Info["redeemedValorAmount"]).to.equal(userRedeemValor);
  expect(batch0Info["fixedValorToUsdcRateScaled"]).to.equal(0);
  expect(await ledger.getUserValor(user.address)).to.closeTo(userCollectedValor - userRedeemValor, VALOR_CHECK_PRECISION);

  await helpers.time.increaseTo(batch0Info["batchEndTime"]);
  return { ledger, orderTokenOft, owner, user, updater, operator, userRedeemValor };
}

/// User redeemed half of collected valor and batch 0 prepared for claiming
export async function userRedeemedBatch0PreparedForClaiming() {
  const { ledger, orderTokenOft, owner, user, updater, operator, userRedeemValor } = await userRedeemedAndBatch0Finished();

  const { usdcRevenuePerBatch, valorPerBatch } = await prepareBatchForClaiming(ledger, owner, 0);
  const batch0InfoAfterPrepared = await ledger.getBatchInfo(0);
  expect(batch0InfoAfterPrepared["claimable"]).to.equal(true);

  const batch0UsdcAmount =
    (BigInt(batch0InfoAfterPrepared["redeemedValorAmount"]) * BigInt(batch0InfoAfterPrepared["fixedValorToUsdcRateScaled"])) /
    VALOR_TO_USDC_RATE_PRECISION;
  expect(batch0UsdcAmount).to.closeTo(userRedeemValor * BigInt(2), VALOR_CHECK_PRECISION);

  return { ledger, orderTokenOft, owner, user, updater, operator, userRedeemValor, usdcRevenuePerBatch, valorPerBatch };
}
