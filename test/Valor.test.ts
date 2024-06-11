import BN from "bn.js";
import { concat, BytesLike, hexlify as toHex } from "@ethersproject/bytes";
import { ethers } from "hardhat";
import { BigNumber, Contract } from "ethers";
import { expect } from "chai";
import { StandardMerkleTree } from "@openzeppelin/merkle-tree";
import { keccak256 } from "ethereum-cryptography/keccak";
import { hexToBytes, bytesToHex } from "ethereum-cryptography/utils";
import { defaultAbiCoder } from "@ethersproject/abi";
import { anyValue } from "@nomicfoundation/hardhat-chai-matchers/withArgs";
import * as helpers from "@nomicfoundation/hardhat-network-helpers";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import {
  INITIAL_SUPPLY,
  INITIAL_SUPPLY_STR,
  ONE_DAY_IN_SECONDS,
  LedgerToken,
  ledgerFixture,
  VALOR_MAXIMUM_EMISSION,
  VALOR_PER_DAY,
  VALOR_EMISSION_DURATION
} from "./utilities/index";

type UintValueData = {
  r: BytesLike;
  s: BytesLike;
  v: number;
  value: BigInt;
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
      r: "0xe639bdecc62f62dc465f0133cc7d75b9dc603a0c6b5b4d6e978a12f93b0b64b8",
      s: "0x3b95fb93464e57afe793cb212827c57f849074f2d4cf12d8bf0bdb381a560ea6",
      v: 0x1c,
      value: BigInt(123)
    };

    expect(await ledger.connect(owner).dailyUsdcNetFeeRevenue(data1)).to.not.be.reverted;

    // Second example data - should pass
    const data2: UintValueData = {
      r: "0x73e5276c430779afca6ef8b25be6f86690cf1a51e6f74ff46339600b3c58459f",
      s: "0x02ab081f611f281079ad8b7ab62bbb958bc3dc2682389833413cf6f8269bec76",
      v: 0x1b,
      value: BigInt("235236236236236236")
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
    // Now total valor emitted is not updated yet
    expect(await ledger.totalValorEmitted()).to.equal(0);

    await ledger.updateValorVars();
    // Now total valor emitted is updated
    expect(await ledger.totalValorEmitted()).greaterThanOrEqual(VALOR_PER_DAY);

    // Let's stake for VALOR_EMISSION_DURATION
    await helpers.time.increase(VALOR_EMISSION_DURATION);

    await ledger.updateValorVars();
    // Now total valor emitted is capped
    expect(await ledger.totalValorEmitted()).to.equal(VALOR_MAXIMUM_EMISSION);
    expect(await ledger.getUserValor(user.address)).to.equal(VALOR_MAXIMUM_EMISSION);

    // Waiting longer should not increase the total valor emitted
    await helpers.time.increase(VALOR_EMISSION_DURATION);

    await ledger.updateValorVars();
    expect(await ledger.totalValorEmitted()).to.equal(VALOR_MAXIMUM_EMISSION);
    expect(await ledger.getUserValor(user.address)).to.equal(VALOR_MAXIMUM_EMISSION);
  });

  it("only owner can call setTotalUsdcInTreasure", async function () {
    const { ledger, orderTokenOft, owner, user, updater, operator } = await valorFixture();

    await expect(ledger.connect(user).setTotalUsdcInTreasure(100)).to.be.revertedWithCustomError(ledger, "AccessControlUnauthorizedAccount");

    await ledger.connect(owner).setTotalUsdcInTreasure(100);
  });
});
