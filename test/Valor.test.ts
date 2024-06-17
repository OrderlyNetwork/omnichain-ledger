import { BytesLike } from "@ethersproject/bytes";
import { expect } from "chai";
import { anyValue } from "@nomicfoundation/hardhat-chai-matchers/withArgs";
import * as helpers from "@nomicfoundation/hardhat-network-helpers";
import { ONE_DAY_IN_SECONDS, LedgerToken, ledgerFixture, VALOR_MAXIMUM_EMISSION, VALOR_PER_DAY, VALOR_EMISSION_DURATION } from "./utilities/index";

type UintValueData = {
  r: BytesLike;
  s: BytesLike;
  v: number;
  value: BigInt;
  timestamp: BigInt;
};

describe("Valor", function () {
  const usdcUpdaterAddress = "0x6a9961ace9bf0c1b8b98ba11558a4125b1f5ea3f";

  async function valorFixture() {
    const { ledger, orderTokenOft, owner, user, updater, operator } = await ledgerFixture();

    ledger.connect(owner).setUsdcUpdaterAddress(usdcUpdaterAddress);

    return { ledger, orderTokenOft, owner, user, updater, operator };
  }

  it("should have correct setup after deployment", async function () {
    const { ledger, user } = await valorFixture();

    expect(await ledger.maximumValorEmission()).to.equal(VALOR_MAXIMUM_EMISSION);
  });

  it("should verify signature", async function () {
    const { ledger, owner, user } = await valorFixture();

    // Example data from here:
    // https://wootraders.atlassian.net/wiki/spaces/ORDER/pages/632750296/Cefi+upload+revenue#Testdata

    // First example data - should pass
    const data1: UintValueData = {
      r: "0xb36e897ecb9be3fc7fe47da85ef8129be40097d7552b53ffafabca96a6b8fa5b",
      s: "0x6fcecb8b834164bcda8ed0e37ed7e180c9764433d99e56b5f507a5db14f8f48a",
      v: 0x1b,
      value: BigInt(123),
      timestamp: BigInt(1718072319590)
    };

    expect(await ledger.connect(owner).dailyUsdcNetFeeRevenue(data1)).to.not.be.reverted;

    // Second example data - should pass
    const data2: UintValueData = {
      r: "0xa4155dce45b643e9979ba6089635b46351cd2da5e447189eedcd89e01629fcec",
      s: "0x779fe7ace0df903c50ae3141f661f1b53ab8d99b567520d971ca67da1273c77f",
      v: 0x1b,
      value: BigInt("235236236236236236"),
      timestamp: BigInt(1710000000000)
    };

    // Move time forward by one day to allow sequential dailyUsdcNetFeeRevenue call
    await helpers.time.increaseTo((await helpers.time.latest()) + ONE_DAY_IN_SECONDS);

    expect(await ledger.connect(owner).dailyUsdcNetFeeRevenue(data2)).to.not.be.reverted;

    // Change test data to fail
    data2.value += BigInt(1);

    // Move time forward by one day to allow sequential dailyUsdcNetFeeRevenue call
    await helpers.time.increaseTo((await helpers.time.latest()) + ONE_DAY_IN_SECONDS);
    await expect(ledger.connect(owner).dailyUsdcNetFeeRevenue(data2)).to.be.revertedWithCustomError(ledger, "InvalidSignature");
  });

  it("valor emission should be capped", async function () {
    const { ledger, orderTokenOft, owner, user, updater, operator } = await valorFixture();

    const chainId = 0;
    const tx = await ledger.connect(user).stake(user.address, chainId, LedgerToken.ORDER, 1000);
    // Check the Staked event is emitted correctly
    await expect(tx).to.emit(ledger, "Staked").withArgs(anyValue, chainId, user.address, 1000, LedgerToken.ORDER);

    expect(await ledger.userTotalStakingBalance(user.address)).to.equal(1000);

    await helpers.time.increase(ONE_DAY_IN_SECONDS);
    // Only one user staked, so user receives all valor emission for the day.
    expect(await ledger.getUserValor(user.address)).greaterThanOrEqual(VALOR_PER_DAY);
    expect(await ledger.getTotalValorEmitted()).greaterThanOrEqual(VALOR_PER_DAY);

    await ledger.updateValorVars();
    // Now total valor emitted is updated
    expect(await ledger.getTotalValorEmitted()).greaterThanOrEqual(VALOR_PER_DAY);

    // Let's stake for VALOR_EMISSION_DURATION
    await helpers.time.increase(VALOR_EMISSION_DURATION);

    await ledger.updateValorVars();
    // Now total valor emitted is capped
    expect(await ledger.getTotalValorEmitted()).to.equal(VALOR_MAXIMUM_EMISSION);
    expect(await ledger.getUserValor(user.address)).to.equal(VALOR_MAXIMUM_EMISSION);

    // Waiting longer should not increase the total valor emitted
    await helpers.time.increase(VALOR_EMISSION_DURATION);

    await ledger.updateValorVars();
    expect(await ledger.getTotalValorEmitted()).to.equal(VALOR_MAXIMUM_EMISSION);
    expect(await ledger.getUserValor(user.address)).to.equal(VALOR_MAXIMUM_EMISSION);
  });

  it("only owner can call setTotalUsdcInTreasure", async function () {
    const { ledger, orderTokenOft, owner, user, updater, operator } = await valorFixture();

    await expect(ledger.connect(user).setTotalUsdcInTreasure(100)).to.be.revertedWithCustomError(ledger, "AccessControlUnauthorizedAccount");

    await ledger.connect(owner).setTotalUsdcInTreasure(100);
  });

  it("Valor: pause should fail functions, that requires unpaused state", async function () {
    const { ledger, orderTokenOft, owner, user, updater, operator } = await valorFixture();

    await ledger.connect(owner).pause();

    const data1: UintValueData = {
      r: "0xb36e897ecb9be3fc7fe47da85ef8129be40097d7552b53ffafabca96a6b8fa5b",
      s: "0x6fcecb8b834164bcda8ed0e37ed7e180c9764433d99e56b5f507a5db14f8f48a",
      v: 0x1b,
      value: BigInt(123),
      timestamp: BigInt(1718072319590)
    };

    await expect(ledger.connect(owner).setUsdcUpdaterAddress(usdcUpdaterAddress)).to.be.revertedWithCustomError(ledger, "EnforcedPause");
    await expect(ledger.connect(owner).dailyUsdcNetFeeRevenue(data1)).to.be.revertedWithCustomError(ledger, "EnforcedPause");
    await expect(ledger.connect(owner).setTotalUsdcInTreasure(100)).to.be.revertedWithCustomError(ledger, "EnforcedPause");
  });
});
