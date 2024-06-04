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
import { INITIAL_SUPPLY, INITIAL_SUPPLY_STR, ONE_DAY_IN_SECONDS, LedgerToken, ledgerFixture, VALOR_MAXIMUM_EMISSION } from "./utilities/index";

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

    const data1: UintValueData = {
      r: "0xe639bdecc62f62dc465f0133cc7d75b9dc603a0c6b5b4d6e978a12f93b0b64b8",
      s: "0x3b95fb93464e57afe793cb212827c57f849074f2d4cf12d8bf0bdb381a560ea6",
      v: 0x1c,
      value: BigInt(123)
    };

    await ledger.connect(owner).dailyUsdcNetFeeRevenue(data1);

    const data2: UintValueData = {
      r: "0x73e5276c430779afca6ef8b25be6f86690cf1a51e6f74ff46339600b3c58459f",
      s: "0x02ab081f611f281079ad8b7ab62bbb958bc3dc2682389833413cf6f8269bec76",
      v: 0x1b,
      value: BigInt("235236236236236236")
    };

    await helpers.time.increaseTo((await helpers.time.latest()) + ONE_DAY_IN_SECONDS);

    await ledger.connect(owner).dailyUsdcNetFeeRevenue(data2);
  });
});
