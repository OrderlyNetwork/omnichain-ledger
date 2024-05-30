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

describe("Valor", function () {
  async function valorFixture() {
    const { ledger: distributor, orderTokenOft, owner, user, updater, operator } = await ledgerFixture();
    return { distributor, orderTokenOft, owner, user, updater, operator };
  }

  it("should have correct setup after deployment", async function () {
    const { distributor, user } = await valorFixture();

    expect(await distributor.maximumValorEmission()).to.equal(VALOR_MAXIMUM_EMISSION);
  });
});
