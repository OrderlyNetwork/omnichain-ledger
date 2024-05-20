import { deployments, ethers, upgrades } from "hardhat";
import { BigNumber, Contract, ContractFactory } from "ethers";
import { expect } from "chai";
import { anyValue } from "@nomicfoundation/hardhat-chai-matchers/withArgs";
import * as helpers from "@nomicfoundation/hardhat-network-helpers";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import { INITIAL_SUPPLY, INITIAL_SUPPLY_STR, ONE_DAY_IN_SECONDS, LedgerToken, ledgerFixture } from "./utilities/index";

describe("Staking", function () {
  async function stakingFixture() {
    const { ledger, orderTokenOft, owner, user, updater, operator } = await ledgerFixture();
    return { ledger, orderTokenOft, owner, user, updater, operator };
  }

  it("check staking initial state", async function () {
    const { ledger, orderTokenOft, owner, user, updater, operator } = await stakingFixture();

    expect(await ledger.totalStakedAmount()).to.equal(0);
    expect(await helpers.time.latest()).closeTo((await ledger.lastValorUpdateTimestamp()).toNumber(), 2);
    expect(await ledger.accValorPerShareScaled()).to.equal(0);
    expect(await ledger.unstakeLockPeriod()).to.equal(60 * 60 * 24 * 7);
    expect(await ledger.userTotalStakingBalance(user.address)).to.equal(0);
    expect(await ledger.getOrderAvailableToWithdraw(user.address)).to.equal(0);
    expect(await ledger.getUserValor(user.address)).to.equal(0);
  });

  it("user can stake order tokens", async function () {
    const { ledger, orderTokenOft, owner, user, updater, operator } = await stakingFixture();

    const chainId = 0;

    await ledger.connect(user).stake(user.address, chainId, LedgerToken.ORDER, 1000);

    expect(await ledger.totalStakedAmount()).to.equal(1000);
    expect(await ledger.userTotalStakingBalance(user.address)).to.equal(1000);
    expect(await ledger.getOrderAvailableToWithdraw(user.address)).to.equal(0);
    expect(await ledger.getUserValor(user.address)).to.equal(0);
  });
});
