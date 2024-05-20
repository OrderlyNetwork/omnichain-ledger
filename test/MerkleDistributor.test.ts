import { ethers } from "hardhat";
import { BigNumber, Contract } from "ethers";
import { expect } from "chai";
import { StandardMerkleTree } from "@openzeppelin/merkle-tree";
import { anyValue } from "@nomicfoundation/hardhat-chai-matchers/withArgs";
import * as helpers from "@nomicfoundation/hardhat-network-helpers";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import { INITIAL_SUPPLY, INITIAL_SUPPLY_STR, ONE_DAY_IN_SECONDS, LedgerToken, ledgerFixture } from "./utilities/index";

describe("LedgerMerkleDistributor", function () {
  const emptyRoot = "0x0000000000000000000000000000000000000000000000000000000000000000";

  function prepareMerkleTree(addresses: string[], amounts: string[]) {
    const values = addresses.map((address, index) => {
      return [address, amounts[index]];
    });

    // console.log(values);
    const tree = StandardMerkleTree.of(values, ["address", "uint256"]);
    // console.log(JSON.stringify(tree.dump()));

    // Map amounts to get list og BigNumber
    const amountsBigNumber = amounts.map(amount => {
      return ethers.BigNumber.from(amount);
    });
    return { tree, amountsBigNumber };
  }

  function encodeIpfsHash(ipfsHash: string) {
    const bs58 = require("bs58");
    return `0x${bs58.decode(ipfsHash).slice(2).toString("hex")}`;
  }

  async function createDistribution(
    token: LedgerToken,
    addresses: string[],
    amounts: string[],
    distributor: Contract,
    updater: SignerWithAddress,
    distributionId: number
  ) {
    if (addresses.length < 1) throw new Error("addresses must have at least one element");
    const { tree, amountsBigNumber } = prepareMerkleTree(addresses, amounts);
    const startTimestamp = (await helpers.time.latest()) + ONE_DAY_IN_SECONDS;
    const ipfsCid = encodeIpfsHash("QmS94dN3Tb2vGFtUsDTcDTCDdp8MEWYi5YXZ4goBtFaq2W");
    await distributor.connect(updater).createDistribution(distributionId, token, tree.root, startTimestamp, ipfsCid);
    return { tree, amountsBigNumber, startTimestamp, ipfsCid };
  }

  async function proposeAndUpdateRootDistribution(
    token: LedgerToken,
    addresses: string[],
    amounts: string[],
    distributor: Contract,
    updater: SignerWithAddress,
    distributionId: number
  ) {
    const { tree, amountsBigNumber, startTimestamp, ipfsCid } = await createDistribution(
      token,
      addresses,
      amounts,
      distributor,
      updater,
      distributionId
    );
    await helpers.time.increaseTo(startTimestamp + 1);
    await distributor.connect(updater).updateRoot(distributionId);
    return { tree, amountsBigNumber, startTimestamp, ipfsCid };
  }

  async function proposeAndUpdateNewRootForDistribution(
    addresses: string[],
    amounts: string[],
    distributor: Contract,
    updater: SignerWithAddress,
    distributionId: number
  ) {
    const { tree: tree2, amountsBigNumber: amountsBigNumber2 } = prepareMerkleTree(addresses, amounts);
    const newStartTimestamp = (await helpers.time.latest()) + ONE_DAY_IN_SECONDS;
    const newIpfsCid = encodeIpfsHash("QmYNQJoKGNHTpPxCBPh9KkDpaExgd2duMa3aF6ytMpHdao");
    await expect(distributor.connect(updater).proposeRoot(distributionId, tree2.root, newStartTimestamp, newIpfsCid))
      .to.emit(distributor, "RootProposed")
      .withArgs(anyValue, distributionId, tree2.root, newStartTimestamp, newIpfsCid);
    await helpers.time.increaseTo(newStartTimestamp + 1);
    await distributor.connect(updater).updateRoot(distributionId);
    return { tree: tree2, amountsBigNumber: amountsBigNumber2, startTimestamp: newStartTimestamp, ipfsCid: newIpfsCid };
  }

  async function claimUserRewardsAndCheckResults(
    distributor: Contract,
    distributionId: number,
    token: LedgerToken,
    user: SignerWithAddress,
    rewardAmount: BigNumber,
    proof: string[],
    expectedClaimedAmount?: BigNumber
  ) {
    const userTotalStakingBalanceBefore = await distributor.userTotalStakingBalance(user.address);

    // User should be able to claim tokens
    // Here chainId is hardcoded as 1.
    const tx = await distributor.connect(user).claimRewards(distributionId, user.address, 1, rewardAmount, proof);
    await expect(tx)
      .to.emit(distributor, "RewardsClaimed")
      .withArgs(anyValue, 1, distributionId, user.address, expectedClaimedAmount ? expectedClaimedAmount : rewardAmount, token);

    const userTotalStakingBalanceAfter = await distributor.userTotalStakingBalance(user.address);
    if (token === LedgerToken.ESORDER) {
      // Check that claimed amount has been staked
      expect(userTotalStakingBalanceAfter).to.be.equal(userTotalStakingBalanceBefore.add(rewardAmount));
    } else if (token === LedgerToken.ORDER) {
      // Check that claimed amount has not been staked
      expect(userTotalStakingBalanceAfter).to.be.equal(userTotalStakingBalanceBefore);
    }
  }

  async function checkDistribution(
    distributor: Contract,
    distributionId: number,
    token: LedgerToken,
    tree: StandardMerkleTree<string[]>,
    startTimestamp: number,
    ipfsCid: string
  ) {
    const {
      token: actualToken,
      merkleRoot: actualMerkleRoot,
      startTimestamp: actualStartTimestamp,
      ipfsCid: actualIpfsCid
    } = await distributor.getDistribution(distributionId);
    expect(actualToken).to.be.equal(token);
    expect(actualMerkleRoot).to.be.equal(tree.root);
    expect(actualStartTimestamp).to.be.equal(startTimestamp);
    expect(actualIpfsCid).to.be.equal(ipfsCid);
  }

  async function checkProposedRoot(
    distributor: Contract,
    distributionId: number,
    tree: StandardMerkleTree<string[]>,
    startTimestamp: number,
    ipfsCid: string
  ) {
    const {
      merkleRoot: proposedMerkleRoot,
      startTimestamp: proposedStartTimestamp,
      ipfsCid: proposedIpfsCid
    } = await distributor.getProposedRoot(distributionId);
    expect(proposedMerkleRoot).to.be.equal(tree.root);
    expect(startTimestamp).to.be.equal(startTimestamp);
    expect(proposedIpfsCid).to.be.equal(ipfsCid);
  }

  async function distributorFixture() {
    const { ledger: distributor, orderTokenOft, owner, user, updater, operator } = await ledgerFixture();
    return { distributor, orderTokenOft, owner, user, updater, operator };
  }

  it("should have correct setup after deployment", async function () {
    const { distributor, user } = await distributorFixture();

    const distributionId = 1;
    expect((await distributor.getDistribution(distributionId)).merkleRoot).to.be.equal(emptyRoot);
    expect((await distributor.getProposedRoot(distributionId)).merkleRoot).to.be.equal(emptyRoot);
    expect(await distributor.getClaimed(distributionId, user.address)).to.be.equal(0);
  });

  it("should allow to propose a new root", async function () {
    const { distributor, orderTokenOft, owner, user, updater } = await distributorFixture();
    const { tree } = prepareMerkleTree([user.address], [INITIAL_SUPPLY_STR]);
    const startTimestamp = (await helpers.time.latest()) + ONE_DAY_IN_SECONDS;
    const ipfsCid = encodeIpfsHash("QmS94dN3Tb2vGFtUsDTcDTCDdp8MEWYi5YXZ4goBtFaq2W");
    const distributionId = 1;

    // Root cannot be proposed if distribution is not created
    await expect(distributor.connect(updater).proposeRoot(distributionId, tree.root, startTimestamp, ipfsCid)).to.be.revertedWithCustomError(
      distributor,
      "DistributionNotFound"
    );

    // Create distribution
    await distributor.connect(updater).createDistribution(distributionId, LedgerToken.ESORDER, tree.root, startTimestamp, ipfsCid);

    // Owner should not be able to propose a root as he has not been granted the ROOT_UPDATER_ROLE
    await expect(distributor.connect(owner).proposeRoot(distributionId, tree.root, startTimestamp, ipfsCid)).to.be.revertedWith(
      /AccessControl: account .* is missing role .*/
    );

    // Updater should be able to propose a root as he has been granted the ROOT_UPDATER_ROLE
    await expect(distributor.connect(updater).proposeRoot(distributionId, tree.root, startTimestamp, ipfsCid)).to.be.revertedWithCustomError(
      distributor,
      "ThisMerkleRootIsAlreadyProposed"
    );

    expect(await distributor.hasPendingRoot(distributionId)).to.be.equal(true);

    const { tree: newTree } = prepareMerkleTree([user.address], [INITIAL_SUPPLY.add(1).toString()]);
    const newStartTimestamp = startTimestamp + ONE_DAY_IN_SECONDS;
    const newIpfsCid = encodeIpfsHash("QmYNQJoKGNHTpPxCBPh9KkDpaExgd2duMa3aF6ytMpHdao");
    await expect(distributor.connect(updater).proposeRoot(distributionId, newTree.root, newStartTimestamp, newIpfsCid))
      .to.emit(distributor, "RootProposed")
      .withArgs(anyValue, distributionId, newTree.root, newStartTimestamp, newIpfsCid);

    // Check that the proposed root is correct
    await checkProposedRoot(distributor, distributionId, newTree, newStartTimestamp, newIpfsCid);

    // Check that the active root is still the default one
    expect((await distributor.getDistribution(distributionId)).merkleRoot).to.be.equal(emptyRoot);
  });

  it("should fail proposing same root twice", async function () {
    const { orderTokenOft, distributor, user, updater } = await distributorFixture();
    const distributionId = 1;
    const { tree, amountsBigNumber, startTimestamp, ipfsCid } = await createDistribution(
      LedgerToken.ORDER,
      [user.address],
      [INITIAL_SUPPLY_STR],
      distributor,
      updater,
      distributionId
    );

    await expect(distributor.connect(updater).proposeRoot(distributionId, tree.root, startTimestamp, ipfsCid)).to.be.revertedWithCustomError(
      distributor,
      "ThisMerkleRootIsAlreadyProposed"
    );
  });

  it("should allow to update a proposed root if it differs from already proposed one", async function () {
    const { orderTokenOft, distributor, user, updater } = await distributorFixture();
    const distributionId = 1;
    const { tree, amountsBigNumber, startTimestamp, ipfsCid } = await createDistribution(
      LedgerToken.ORDER,
      [user.address],
      [INITIAL_SUPPLY_STR],
      distributor,
      updater,
      distributionId
    );

    const { tree: newTree, amountsBigNumber: newAmountsBigNumber } = prepareMerkleTree([user.address], ["2000000000"]);

    await expect(distributor.connect(updater).proposeRoot(distributionId, newTree.root, startTimestamp, ipfsCid))
      .to.emit(distributor, "RootProposed")
      .withArgs(anyValue, distributionId, newTree.root, startTimestamp, ipfsCid);

    await checkProposedRoot(distributor, distributionId, newTree, startTimestamp, ipfsCid);

    await expect(distributor.connect(updater).proposeRoot(distributionId, newTree.root, startTimestamp + 1, ipfsCid))
      .to.emit(distributor, "RootProposed")
      .withArgs(anyValue, distributionId, newTree.root, startTimestamp + 1, ipfsCid);

    await checkProposedRoot(distributor, distributionId, newTree, startTimestamp + 1, ipfsCid);

    const newIpfsCid = encodeIpfsHash("QmYNQJoKGNHTpPxCBPh9KkDpaExgd2duMa3aF6ytMpHdao");
    await expect(distributor.connect(updater).proposeRoot(distributionId, newTree.root, startTimestamp + 1, newIpfsCid))
      .to.emit(distributor, "RootProposed")
      .withArgs(anyValue, distributionId, newTree.root, startTimestamp + 1, newIpfsCid);

    await checkProposedRoot(distributor, distributionId, newTree, startTimestamp, newIpfsCid);
  });

  it("should propogate the proposed root to the active one during proposing new one if startTimestamp has passed", async function () {
    const { orderTokenOft, distributor, user, updater } = await distributorFixture();
    const distributionId = 1;
    const { tree, startTimestamp, ipfsCid } = await createDistribution(
      LedgerToken.ORDER,
      [user.address],
      [INITIAL_SUPPLY_STR],
      distributor,
      updater,
      distributionId
    );

    await helpers.time.increaseTo(startTimestamp + 1);

    const newStartTimestamp = (await helpers.time.latest()) + ONE_DAY_IN_SECONDS;
    const { tree: newTree } = prepareMerkleTree([user.address], ["2000000000"]);
    await expect(distributor.connect(updater).proposeRoot(distributionId, newTree.root, newStartTimestamp, ipfsCid))
      .to.emit(distributor, "RootProposed")
      .withArgs(anyValue, distributionId, newTree.root, newStartTimestamp, ipfsCid);

    await checkDistribution(distributor, distributionId, LedgerToken.ORDER, tree, startTimestamp, ipfsCid);
    await checkProposedRoot(distributor, distributionId, newTree, newStartTimestamp, ipfsCid);
  });

  it("should allow to activate a proposed root after startTimestamp has passed", async function () {
    const { orderTokenOft, distributor, user, updater } = await distributorFixture();
    const distributionId = 1;
    const { tree, startTimestamp, ipfsCid } = await createDistribution(
      LedgerToken.ORDER,
      [user.address],
      [INITIAL_SUPPLY_STR],
      distributor,
      updater,
      distributionId
    );

    // Proposed root cannot be activated before startTimestamp
    expect(await distributor.canUpdateRoot(distributionId)).to.be.equal(false);
    await expect(distributor.connect(user).updateRoot(distributionId)).to.be.revertedWithCustomError(distributor, "CannotUpdateRoot");

    // Proposed root can be activated after startTimestamp
    await helpers.time.increaseTo(startTimestamp + 1);
    expect(await distributor.canUpdateRoot(distributionId)).to.be.equal(true);
    await expect(distributor.connect(user).updateRoot(distributionId))
      .to.emit(distributor, "RootUpdated")
      .withArgs(anyValue, distributionId, tree.root, startTimestamp, ipfsCid);

    // Check that the active root is now the proposed one
    await checkDistribution(distributor, distributionId, LedgerToken.ORDER, tree, startTimestamp, ipfsCid);

    // Check that the proposed root is now the default one
    expect((await distributor.getProposedRoot(distributionId)).merkleRoot).to.be.equal(emptyRoot);
  });

  it("should allow to claim tokens", async function () {
    const { orderTokenOft, distributor, user, updater } = await distributorFixture();
    const distributionId = 1;
    const { tree, amountsBigNumber } = await proposeAndUpdateRootDistribution(
      LedgerToken.ORDER,
      [user.address],
      ["1000000000"],
      distributor,
      updater,
      distributionId
    );

    await claimUserRewardsAndCheckResults(distributor, distributionId, LedgerToken.ORDER, user, amountsBigNumber[0], tree.getProof(0));
  });

  it("repeat claim should transfer nothing", async function () {
    const { orderTokenOft, distributor, user, updater } = await distributorFixture();
    const distributionId = 1;
    const chainId = 1;
    const { tree, amountsBigNumber } = await proposeAndUpdateRootDistribution(
      LedgerToken.ORDER,
      [user.address],
      ["1000000000"],
      distributor,
      updater,
      distributionId
    );

    await claimUserRewardsAndCheckResults(distributor, distributionId, LedgerToken.ORDER, user, amountsBigNumber[0], tree.getProof(0));

    // Repeat claim should transfer nothing and not emit events
    const tx2 = await distributor.connect(user).claimRewards(distributionId, user.address, chainId, amountsBigNumber[0], tree.getProof(0));
    await expect(tx2).to.not.emit(distributor, "RewardsClaimed");
  });

  it("should allow to claim tokens for multiple addresses", async function () {
    const { orderTokenOft, distributor, user, updater } = await distributorFixture();
    const distributionId = 1;
    const { tree, amountsBigNumber } = await proposeAndUpdateRootDistribution(
      LedgerToken.ORDER,
      [user.address, updater.address],
      ["1000000000", "2000000000"],
      distributor,
      updater,
      distributionId
    );
    await claimUserRewardsAndCheckResults(distributor, distributionId, LedgerToken.ORDER, user, amountsBigNumber[0], tree.getProof(0));
    await claimUserRewardsAndCheckResults(distributor, distributionId, LedgerToken.ORDER, updater, amountsBigNumber[1], tree.getProof(1));
  });

  it("should allow to claim tokens for multiple addresses in multiple roots", async function () {
    const { orderTokenOft, distributor, user, updater } = await distributorFixture();
    const distributionId1 = 1;
    const { tree, amountsBigNumber: orderAmounts1 } = await proposeAndUpdateRootDistribution(
      LedgerToken.ORDER,
      [user.address, updater.address],
      ["1000000000", "2000000000"],
      distributor,
      updater,
      distributionId1
    );

    const distributionId2 = 2;
    const { tree: tree2, amountsBigNumber: orderAmounts2 } = await proposeAndUpdateRootDistribution(
      LedgerToken.ORDER,
      [updater.address, user.address],
      ["3000000000", "4000000000"],
      distributor,
      updater,
      distributionId2
    );

    await claimUserRewardsAndCheckResults(distributor, distributionId1, LedgerToken.ORDER, user, orderAmounts1[0], tree.getProof(0));
    await claimUserRewardsAndCheckResults(distributor, distributionId1, LedgerToken.ORDER, updater, orderAmounts1[1], tree.getProof(1));
    await claimUserRewardsAndCheckResults(distributor, distributionId2, LedgerToken.ORDER, updater, orderAmounts2[0], tree2.getProof(0));
    await claimUserRewardsAndCheckResults(distributor, distributionId2, LedgerToken.ORDER, user, orderAmounts2[1], tree2.getProof(1));
  });

  it("should allow to repeatedly claim tokens after root has been updated", async function () {
    const { orderTokenOft, distributor, user, updater } = await distributorFixture();
    const distributionId = 1;
    const {
      tree: tree1,
      amountsBigNumber: amountsBigNumber1,
      startTimestamp: startTimestamp1
    } = await proposeAndUpdateRootDistribution(LedgerToken.ORDER, [user.address], ["1000000000"], distributor, updater, distributionId);

    await claimUserRewardsAndCheckResults(
      distributor,
      distributionId,
      LedgerToken.ORDER,
      user,
      amountsBigNumber1[0],
      tree1.getProof([user.address, amountsBigNumber1[0].toString()])
    );

    const { tree: tree2, amountsBigNumber: amountsBigNumber2 } = await proposeAndUpdateNewRootForDistribution(
      [user.address],
      ["3000000000"],
      distributor,
      updater,
      distributionId
    );

    await claimUserRewardsAndCheckResults(
      distributor,
      distributionId,
      LedgerToken.ORDER,
      user,
      amountsBigNumber2[0],
      tree2.getProof([user.address, amountsBigNumber2[0].toString()]),
      amountsBigNumber2[0].sub(amountsBigNumber1[0])
    );
  });

  it("should update root after claiming if startTimestamp has passed", async function () {
    const { orderTokenOft, distributor, user, updater } = await distributorFixture();

    const distributionId = 1;
    const chainId = 1;
    // Create first distribution
    await createDistribution(LedgerToken.ORDER, [user.address], ["1000000000"], distributor, updater, distributionId);

    const { tree: tree2, amountsBigNumber: amountsBigNumber2 } = await proposeAndUpdateNewRootForDistribution(
      [user.address],
      ["3000000000"],
      distributor,
      updater,
      distributionId
    );

    // Claim user's reward from the active root, the pending root will be promoted during the claim
    const tx = await distributor.connect(user).claimRewards(distributionId, user.address, chainId, amountsBigNumber2[0], tree2.getProof(0));
    await expect(tx)
      .to.emit(distributor, "RewardsClaimed")
      .withArgs(anyValue, chainId, distributionId, user.address, amountsBigNumber2[0], LedgerToken.ORDER);

    // Check that the user token claimed amount has been updated
    expect(await distributor.getClaimed(distributionId, user.address)).to.be.equal(amountsBigNumber2[0]);
  });

  it("should stake tokens when claiming ESORDER tokens", async function () {
    const { orderTokenOft, distributor, user, updater } = await distributorFixture();
    const distributionId = 1;
    const { tree, amountsBigNumber } = await proposeAndUpdateRootDistribution(
      LedgerToken.ESORDER,
      [user.address],
      ["1000000000"],
      distributor,
      updater,
      distributionId
    );

    await claimUserRewardsAndCheckResults(distributor, distributionId, LedgerToken.ESORDER, user, amountsBigNumber[0], tree.getProof(0));
  });

  it("should NOT stake tokens when claiming ORDER tokens", async function () {
    const { orderTokenOft, distributor, user, updater } = await distributorFixture();
    const distributionId = 1;
    const { tree, amountsBigNumber } = await proposeAndUpdateRootDistribution(
      LedgerToken.ORDER,
      [user.address],
      ["1000000000"],
      distributor,
      updater,
      distributionId
    );

    await claimUserRewardsAndCheckResults(distributor, distributionId, LedgerToken.ORDER, user, amountsBigNumber[0], tree.getProof(0));
  });

  // it("should allow to claim tokens for user by operator", async function () {
  //     const { orderTokenOft, distributor, user, updater, operator } = await distributorFixture();
  //     const { tree, amountsBigNumber } = await proposeAndUpdateRootDistribution([user.address], ["1000000000"], distributor, updater, orderToken);

  //     const userBalanceBefore = await orderToken.balanceOf(user.address);
  //     const tokenTotalSupplyBefore = await orderToken.totalSupply();

  //     // Operator should be able to claim tokens for user
  //     const tx = await distributor.connect(operator).claimRewardsFor(user.address, orderToken.address, amountsBigNumber[0], tree.getProof(0));
  //     await expect(tx).to.emit(distributor, "RewardsClaimed").withArgs(anyValue, orderToken.address, user.address, amountsBigNumber[0]);

  //     // Check that the user token claimed amount has been updated
  //     expect(await distributor.getClaimed(orderToken.address, user.address)).to.be.equal(amountsBigNumber[0]);

  //     // Check that the user has received the tokens
  //     expect(await orderToken.balanceOf(user.address)).to.be.equal(userBalanceBefore.add(amountsBigNumber[0]));

  //     // Check that the total supply has been updated
  //     expect(await orderToken.totalSupply()).to.be.equal(tokenTotalSupplyBefore.add(amountsBigNumber[0]));
  // });

  // it("should allow to claim tokens for user by another user if alwaysAllowClaimsFor is set", async function () {
  //     const { orderTokenOft, distributor, user, updater, operator } = await distributorFixture();
  //     const { tree, amountsBigNumber } = await proposeAndUpdateRootDistribution([user.address], ["1000000000"], distributor, updater, orderToken);

  //     // Check, that updater cannot claim tokens for user without alwaysAllowClaimsFor set
  //     await expect(distributor.connect(updater).claimRewardsFor(user.address, orderToken.address, amountsBigNumber[0], tree.getProof(0)))
  //         .to.be.revertedWithCustomError(distributor, "NoPermissionsToClaimForThisUser")
  //         .withArgs(user.address);

  //     // Set alwaysAllowClaimsFor for user
  //     await distributor.connect(user).setAlwaysAllowClaimsFor(true);

  //     const userBalanceBefore = await orderToken.balanceOf(user.address);
  //     const tokenTotalSupplyBefore = await orderToken.totalSupply();

  //     // User should be able to claim tokens for another user if alwaysAllowClaimsFor is set
  //     const tx = await distributor.connect(updater).claimRewardsFor(user.address, orderToken.address, amountsBigNumber[0], tree.getProof(0));
  //     await expect(tx).to.emit(distributor, "RewardsClaimed").withArgs(anyValue, orderToken.address, user.address, amountsBigNumber[0]);

  //     // Check that the user token claimed amount has been updated
  //     expect(await distributor.getClaimed(orderToken.address, user.address)).to.be.equal(amountsBigNumber[0]);

  //     // Check that the user has received the tokens
  //     expect(await orderToken.balanceOf(user.address)).to.be.equal(userBalanceBefore.add(amountsBigNumber[0]));

  //     // Check that the total supply has been updated
  //     expect(await orderToken.totalSupply()).to.be.equal(tokenTotalSupplyBefore.add(amountsBigNumber[0]));

  //     // Unset alwaysAllowClaimsFor for user
  //     await distributor.connect(user).setAlwaysAllowClaimsFor(false);

  //     // Check, that updater cannot claim tokens for user after alwaysAllowClaimsFor has been unset
  //     await expect(distributor.connect(updater).claimRewardsFor(user.address, orderToken.address, amountsBigNumber[0], tree.getProof(0)))
  //         .to.be.revertedWithCustomError(distributor, "NoPermissionsToClaimForThisUser")
  //         .withArgs(user.address);
  // });

  // it("should fail if the root is not active", async function () {
  //     const { orderTokenOft, distributor, user, updater } = await distributorFixture();
  //     const { tree, amountsBigNumber } = await proposeRootDistribution([user.address], ["1000000000"], distributor, updater, orderToken);
  //     await expect(distributor.connect(user).claimRewards(orderToken.address, amountsBigNumber[0], tree.getProof(0)))
  //         .to.be.revertedWithCustomError(distributor, "NoActiveMerkleRoot")
  //         .withArgs(orderToken.address);
  // });

  // it("should fail if user not in merkle tree", async function () {
  //     const { orderTokenOft, distributor, user, updater } = await distributorFixture();
  //     const { tree, amountsBigNumber } = await proposeAndUpdateRootDistribution([user.address], ["1000000000"], distributor, updater, orderToken);
  //     await expect(distributor.connect(updater).claimRewards(orderToken.address, amountsBigNumber[0], tree.getProof(0))).to.be.revertedWithCustomError(
  //         distributor,
  //         "InvalidMerkleProof"
  //     );
  // });

  // it("should fail if user proof is not valid", async function () {
  //     const { orderTokenOft, distributor, user, updater } = await distributorFixture();
  //     const { tree, amountsBigNumber } = await proposeAndUpdateRootDistribution([user.address], ["1000000000"], distributor, updater, orderToken);
  //     await expect(
  //         distributor.connect(user).claimRewards(orderToken.address, amountsBigNumber[0].add(1), tree.getProof(0))
  //     ).to.be.revertedWithCustomError(distributor, "InvalidMerkleProof");
  // });

  // it("should fail if token cannot be minted", async function () {
  //     const { orderTokenOft, distributor, owner, user, updater } = await distributorFixture();

  //     orderToken.connect(owner).revokeRole(await orderToken.MINTER_ROLE(), distributor.address);
  //     const { tree, amountsBigNumber } = await proposeAndUpdateRootDistribution([user.address], ["1000000000"], distributor, updater, orderToken);
  //     await expect(distributor.connect(user).claimRewards(orderToken.address, amountsBigNumber[0], tree.getProof(0))).to.be.revertedWith(
  //         /AccessControl: account .* is missing role .*/
  //     );

  //     orderToken.connect(owner).grantRole(await orderToken.MINTER_ROLE(), distributor.address);
  //     orderToken.connect(owner).grantRole(await orderToken.MINTER_ROLE(), owner.address);
  //     orderToken.connect(owner).mint(owner.address, TOTAL_SUPPLY);
  //     await expect(distributor.connect(user).claimRewards(orderToken.address, amountsBigNumber[0], tree.getProof(0)))
  //         .to.be.revertedWithCustomError(distributor, "TokenCannotBeMinted")
  //         .withArgs(orderToken.address);
  // });

  // it("check that only owner can pause/unpause", async function () {
  //     const { orderTokenOft, distributor, owner, user, updater } = await distributorFixture();

  //     // Only owner should be able to pause/unpause
  //     await expect(distributor.connect(user).pause()).to.be.revertedWith(/AccessControl: account .* is missing role .*/);
  //     await expect(distributor.connect(user).unpause()).to.be.revertedWith(/AccessControl: account .* is missing role .*/);

  //     // Owner should be able to pause/unpause
  //     await distributor.connect(owner).pause();
  //     await distributor.connect(owner).unpause();
  // });

  // it("pause should fail functions, that requires unpaused state", async function () {
  //     const { orderTokenOft, distributor, owner, user, updater, operator } = await distributorFixture();
  //     await distributor.connect(owner).pause();

  //     const { tree, amountsBigNumber, startTimestamp } = await proposeRootDistribution(
  //         [user.address],
  //         ["1000000000"],
  //         distributor,
  //         updater,
  //         orderToken
  //     );
  //     await helpers.time.increaseTo(startTimestamp + 1);
  //     await expect(distributor.connect(updater).updateRoot(orderToken.address)).to.be.revertedWith("Pausable: paused");
  //     await expect(distributor.connect(user).claimRewards(orderToken.address, amountsBigNumber[0], tree.getProof(0))).to.be.revertedWith(
  //         "Pausable: paused"
  //     );
  //     await expect(
  //         distributor.connect(operator).claimRewardsFor(user.address, orderToken.address, amountsBigNumber[0], tree.getProof(0))
  //     ).to.be.revertedWith("Pausable: paused");

  //     await distributor.connect(owner).unpause();
  //     await distributor.connect(updater).updateRoot(orderToken.address);
  //     await distributor.connect(user).claimRewards(orderToken.address, amountsBigNumber[0], tree.getProof(0));
  //     await distributor.connect(operator).claimRewardsFor(user.address, orderToken.address, amountsBigNumber[0], tree.getProof(0));
  // });
});
