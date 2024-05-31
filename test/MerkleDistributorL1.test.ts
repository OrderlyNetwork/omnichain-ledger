import { ethers, upgrades } from "hardhat";
import { BigNumber, Contract } from "ethers";
import { expect } from "chai";
import { StandardMerkleTree } from "@openzeppelin/merkle-tree";
import { anyValue } from "@nomicfoundation/hardhat-chai-matchers/withArgs";
import * as helpers from "@nomicfoundation/hardhat-network-helpers";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import { INITIAL_SUPPLY_STR, ONE_DAY_IN_SECONDS, TOTAL_SUPPLY } from "./utilities/index";

describe("MerkleDistributorL1", function () {
  const emptyRoot = "0x0000000000000000000000000000000000000000000000000000000000000000";
  const someRoot = "0x53bc4e0e5fee341a5efadc8dee7f9a3b2473fdf5669d6dc76cd2d1b878bf981d";

  //   function generateMerkleTreeForNLeafs(n: number) {
  //     const addresses = [];
  //     const amounts = [];
  //     for (let i = 0; i < n; i++) {
  //       const randomAddress = ethers.utils.getAddress(ethers.utils.hexlify(ethers.utils.randomBytes(20)));
  //       addresses.push(randomAddress);
  //       const randomAmount = Math.floor(Math.random() * 1e27) + 1;
  //       amounts.push(randomAmount.toString());
  //     }
  //     const tree = prepareMerkleTree(addresses, amounts);
  //     return { addresses, amounts, tree };
  //   }

  function prepareMerkleTree(addresses: string[], amounts: string[]) {
    const values = addresses.map((address, index) => {
      return [address, amounts[index]];
    });

    // console.log(values);
    const tree = StandardMerkleTree.of(values, ["address", "uint256"]);
    // console.log(JSON.stringify(tree.dump()));

    // Map amounts to get list og BigNumber
    const amountsBigNumber = amounts.map(amount => {
      return BigInt(amount);
    });
    return { tree, amountsBigNumber };
  }

  function encodeIpfsHash(ipfsHash: string) {
    const bs58 = require("bs58");
    return `0x${bs58.decode(ipfsHash).slice(2).toString("hex")}`;
  }

  async function proposeRootDistribution(
    tokenContract: Contract,
    addresses: string[],
    amounts: string[],
    distributor: Contract,
    owner: SignerWithAddress
  ) {
    if (addresses.length < 1) throw new Error("addresses must have at least one element");
    const { tree, amountsBigNumber } = prepareMerkleTree(addresses, amounts);
    const startTimestamp = (await helpers.time.latest()) + ONE_DAY_IN_SECONDS;
    const endTimestamp = startTimestamp + ONE_DAY_IN_SECONDS;
    const ipfsCid = encodeIpfsHash("QmS94dN3Tb2vGFtUsDTcDTCDdp8MEWYi5YXZ4goBtFaq2W");
    await distributor.connect(owner).proposeRoot(tree.root, startTimestamp, endTimestamp, ipfsCid);

    // Calculate total amount of tokens to be distributed
    let totalAmount = BigInt(0);
    amountsBigNumber.forEach(amount => {
      totalAmount = totalAmount + amount;
    });

    await tokenContract.connect(owner).transfer(await distributor.getAddress(), totalAmount);
    return { tree, amountsBigNumber, startTimestamp, endTimestamp, ipfsCid };
  }

  async function proposeAndUpdateRootDistribution(
    tokenContract: Contract,
    addresses: string[],
    amounts: string[],
    distributor: Contract,
    owner: SignerWithAddress
  ) {
    const { tree, amountsBigNumber, startTimestamp, endTimestamp, ipfsCid } = await proposeRootDistribution(
      tokenContract,
      addresses,
      amounts,
      distributor,
      owner
    );
    await helpers.time.increaseTo(startTimestamp + 1);
    await distributor.connect(owner).updateRoot();
    return { tree, amountsBigNumber, startTimestamp, endTimestamp, ipfsCid };
  }

  async function claimUserRewardsAndCheckResults(
    tokenContract: Contract,
    distributor: Contract,
    user: SignerWithAddress,
    rewardAmount: BigNumber,
    proof: string[],
    expectedClaimedAmount?: BigNumber
  ) {
    const distributorAddress = await distributor.getAddress();
    const distributorBalanceBefore = await tokenContract.balanceOf(distributorAddress);
    const userBalanceBefore = await tokenContract.balanceOf(user.address);

    // User should be able to claim tokens
    const tx = await distributor.connect(user).claimRewards(rewardAmount, proof);
    await expect(tx)
      .to.emit(distributor, "RewardsClaimed")
      .withArgs(anyValue, user.address, expectedClaimedAmount ? expectedClaimedAmount : rewardAmount);

    // Check that the user token claimed amount has been updated
    expect(await distributor.getClaimed(user.address)).to.be.equal(rewardAmount);

    // Check that the distributor has transferred the tokens
    expect(await tokenContract.balanceOf(distributorAddress)).to.be.equal(
      distributorBalanceBefore - BigInt(expectedClaimedAmount ? expectedClaimedAmount : rewardAmount)
    );

    // Check that the user has received the tokens
    expect(await tokenContract.balanceOf(user.address)).to.be.equal(
      userBalanceBefore + BigInt(expectedClaimedAmount ? expectedClaimedAmount : rewardAmount)
    );
  }

  async function checkActualRoot(
    distributor: Contract,
    tree: StandardMerkleTree<string[]>,
    startTimestamp: number,
    endTimestamp: number,
    ipfsCid: string
  ) {
    const {
      merkleRoot: actualMerkleRoot,
      startTimestamp: actualStartTimestamp,
      endTimestamp: actualEndTimestamp,
      ipfsCid: actualIpfsCid
    } = await distributor.getActualRoot();
    expect(actualMerkleRoot).to.be.equal(tree.root);
    expect(actualStartTimestamp).to.be.equal(startTimestamp);
    expect(actualEndTimestamp).to.be.equal(endTimestamp);
    expect(actualIpfsCid).to.be.equal(ipfsCid);
  }

  async function checkProposedRoot(
    distributor: Contract,
    tree: StandardMerkleTree<string[]>,
    startTimestamp: number,
    endTimestamp: number,
    ipfsCid: string
  ) {
    const {
      merkleRoot: proposedMerkleRoot,
      startTimestamp: proposedStartTimestamp,
      endTimestamp: proposedEndTimestamp,
      ipfsCid: proposedIpfsCid
    } = await distributor.getProposedRoot();
    expect(proposedMerkleRoot).to.be.equal(tree.root);
    expect(proposedStartTimestamp).to.be.equal(startTimestamp);
    expect(proposedEndTimestamp).to.be.equal(endTimestamp);
    expect(proposedIpfsCid).to.be.equal(ipfsCid);
  }

  async function distributorFixture() {
    const orderTokenCF = await ethers.getContractFactory("OrderToken");
    const distributorCF = await ethers.getContractFactory("MerkleDistributorL1");

    const [owner, user] = await ethers.getSigners();

    const orderToken = await orderTokenCF.connect(owner).deploy(TOTAL_SUPPLY);

    const distributor = await upgrades.deployProxy(distributorCF, [owner.address, await orderToken.getAddress()], { kind: "uups" });

    return { orderToken, distributor, owner, user };
  }

  it("should have correct setup after deployment", async function () {
    const { distributor, user } = await distributorFixture();
    expect((await distributor.getActualRoot()).merkleRoot).to.be.equal(emptyRoot);
    expect((await distributor.getProposedRoot()).merkleRoot).to.be.equal(emptyRoot);
    expect(await distributor.getClaimed(user.address)).to.be.equal(0);
  });

  it("should allow to propose a new root", async function () {
    const { distributor, owner, user } = await distributorFixture();
    const { tree } = prepareMerkleTree([user.address], [INITIAL_SUPPLY_STR]);
    const startTimestamp = (await helpers.time.latest()) + ONE_DAY_IN_SECONDS;
    const endTimestamp = startTimestamp + ONE_DAY_IN_SECONDS;
    const ipfsCid = encodeIpfsHash("QmS94dN3Tb2vGFtUsDTcDTCDdp8MEWYi5YXZ4goBtFaq2W");

    // User should not be able to propose a root as he has not been granted the ROOT_UPDATER_ROLE
    await expect(distributor.connect(user).proposeRoot(tree.root, startTimestamp, endTimestamp, ipfsCid)).to.be.revertedWithCustomError(
      distributor,
      "OwnableUnauthorizedAccount"
    );

    // Updater should be able to propose a root as he has been granted the ROOT_UPDATER_ROLE
    await expect(distributor.connect(owner).proposeRoot(tree.root, startTimestamp, endTimestamp, ipfsCid))
      .to.emit(distributor, "RootProposed")
      .withArgs(anyValue, tree.root, startTimestamp, endTimestamp, ipfsCid);

    expect(await distributor.hasPendingRoot()).to.be.equal(true);

    // Check that the proposed root is correct
    await checkProposedRoot(distributor, tree, startTimestamp, endTimestamp, ipfsCid);

    // Check that the active root is still the default one
    expect((await distributor.getActualRoot()).merkleRoot).to.be.equal(emptyRoot);
  });

  it("should fail proposing same root twice", async function () {
    const { orderToken, distributor, owner, user } = await distributorFixture();
    const { tree, startTimestamp, endTimestamp, ipfsCid } = await proposeRootDistribution(
      orderToken,
      [user.address],
      [INITIAL_SUPPLY_STR],
      distributor,
      owner
    );

    await expect(distributor.connect(owner).proposeRoot(tree.root, startTimestamp, endTimestamp, ipfsCid)).to.be.revertedWithCustomError(
      distributor,
      "ThisMerkleRootIsAlreadyProposed"
    );
  });

  it("should allow to update a proposed root if it differs from already proposed one", async function () {
    const { orderToken, distributor, owner, user } = await distributorFixture();
    const { startTimestamp, endTimestamp, ipfsCid } = await proposeRootDistribution(
      orderToken,
      [user.address],
      [INITIAL_SUPPLY_STR],
      distributor,
      owner
    );

    const { tree: newTree } = prepareMerkleTree([user.address], ["2000000000"]);

    // Different root should be allowed to be proposed
    await expect(distributor.connect(owner).proposeRoot(newTree.root, startTimestamp, endTimestamp, ipfsCid))
      .to.emit(distributor, "RootProposed")
      .withArgs(anyValue, newTree.root, startTimestamp, endTimestamp, ipfsCid);

    await checkProposedRoot(distributor, newTree, startTimestamp, endTimestamp, ipfsCid);

    // Different startTimestamp should be allowed to be proposed
    await expect(distributor.connect(owner).proposeRoot(newTree.root, startTimestamp + 1, endTimestamp, ipfsCid))
      .to.emit(distributor, "RootProposed")
      .withArgs(anyValue, newTree.root, startTimestamp + 1, endTimestamp, ipfsCid);

    await checkProposedRoot(distributor, newTree, startTimestamp + 1, endTimestamp, ipfsCid);

    // Updated ipfsCid should give possibility to update the root
    const newIpfsCid = encodeIpfsHash("QmYNQJoKGNHTpPxCBPh9KkDpaExgd2duMa3aF6ytMpHdao");
    await expect(distributor.connect(owner).proposeRoot(newTree.root, startTimestamp + 1, endTimestamp, newIpfsCid))
      .to.emit(distributor, "RootProposed")
      .withArgs(anyValue, newTree.root, startTimestamp + 1, endTimestamp, newIpfsCid);

    await checkProposedRoot(distributor, newTree, startTimestamp + 1, endTimestamp, newIpfsCid);
  });

  it("should propogate the proposed root to the active one during proposing new one if startTimestamp has passed", async function () {
    const { orderToken, distributor, owner, user } = await distributorFixture();
    const { tree, startTimestamp, endTimestamp, ipfsCid } = await proposeRootDistribution(
      orderToken,
      [user.address],
      [INITIAL_SUPPLY_STR],
      distributor,
      owner
    );

    await helpers.time.increaseTo(startTimestamp + 1);

    const newStartTimestamp = (await helpers.time.latest()) + ONE_DAY_IN_SECONDS;
    const newEndTimestamp = newStartTimestamp + ONE_DAY_IN_SECONDS;
    const { tree: newTree } = prepareMerkleTree([user.address], ["2000000000"]);
    await expect(distributor.connect(owner).proposeRoot(newTree.root, newStartTimestamp, newEndTimestamp, ipfsCid))
      .to.emit(distributor, "RootProposed")
      .withArgs(anyValue, newTree.root, newStartTimestamp, newEndTimestamp, ipfsCid);

    await checkActualRoot(distributor, tree, startTimestamp, endTimestamp, ipfsCid);
    await checkProposedRoot(distributor, newTree, newStartTimestamp, newEndTimestamp, ipfsCid);
  });

  it("should allow to activate a proposed root after startTimestamp has passed", async function () {
    const { orderToken, distributor, owner, user } = await distributorFixture();
    const { tree, startTimestamp, endTimestamp, ipfsCid } = await proposeRootDistribution(
      orderToken,
      [user.address],
      [INITIAL_SUPPLY_STR],
      distributor,
      owner
    );

    // Proposed root cannot be activated before startTimestamp
    expect(await distributor.canUpdateRoot()).to.be.equal(false);
    await expect(distributor.connect(user).updateRoot()).to.be.revertedWithCustomError(distributor, "CannotUpdateRoot");

    // Proposed root can be activated after startTimestamp
    await helpers.time.increaseTo(startTimestamp + 1);
    expect(await distributor.canUpdateRoot()).to.be.equal(true);
    await expect(distributor.connect(user).updateRoot())
      .to.emit(distributor, "RootUpdated")
      .withArgs(anyValue, tree.root, startTimestamp, endTimestamp, ipfsCid);

    // Check that the active root is now the proposed one
    await checkActualRoot(distributor, tree, startTimestamp, endTimestamp, ipfsCid);

    // Check that the proposed root is now the default one
    expect((await distributor.getProposedRoot()).merkleRoot).to.be.equal(emptyRoot);
  });

  it("should allow to claim tokens", async function () {
    const { orderToken, distributor, owner, user } = await distributorFixture();
    const { tree, amountsBigNumber } = await proposeAndUpdateRootDistribution(orderToken, [user.address], ["1000000000"], distributor, owner);

    await claimUserRewardsAndCheckResults(orderToken, distributor, user, amountsBigNumber[0], tree.getProof(0));
  });

  it("repeat claim should transfer nothing", async function () {
    const { orderToken, distributor, owner, user } = await distributorFixture();
    const { tree, amountsBigNumber } = await proposeAndUpdateRootDistribution(orderToken, [user.address], ["1000000000"], distributor, owner);
    const distributorAddress = await distributor.getAddress();

    await claimUserRewardsAndCheckResults(orderToken, distributor, user, amountsBigNumber[0], tree.getProof(0));

    const distributorBalanceBefore = await orderToken.balanceOf(distributorAddress);
    const userBalanceBefore = await orderToken.balanceOf(user.address);

    // Repeat claim should transfer nothing and not emit events
    const tx2 = await distributor.connect(user).claimRewards(amountsBigNumber[0], tree.getProof(0));
    await expect(tx2).to.not.emit(distributor, "RewardsClaimed");

    // Check that the user token claimed amount has not changed
    expect(await distributor.getClaimed(user.address)).to.be.equal(amountsBigNumber[0]);

    // Check that the distributor balance has not changed
    expect(await orderToken.balanceOf(distributorAddress)).to.be.equal(distributorBalanceBefore);

    // Check that the user balance has not changed
    expect(await orderToken.balanceOf(user.address)).to.be.equal(userBalanceBefore);
  });

  it("should allow to claim tokens for multiple addresses", async function () {
    const { orderToken, distributor, owner, user } = await distributorFixture();
    const { tree, amountsBigNumber } = await proposeAndUpdateRootDistribution(
      orderToken,
      [user.address, owner.address],
      ["1000000000", "2000000000"],
      distributor,
      owner
    );
    await claimUserRewardsAndCheckResults(orderToken, distributor, user, amountsBigNumber[0], tree.getProof(0));
    await claimUserRewardsAndCheckResults(orderToken, distributor, owner, amountsBigNumber[1], tree.getProof(1));
  });

  it("should allow to repeatedly claim tokens after root has been updated", async function () {
    const { orderToken, distributor, owner, user } = await distributorFixture();
    const { tree: tree1, amountsBigNumber: amountsBigNumber1 } = await proposeAndUpdateRootDistribution(
      orderToken,
      [user.address],
      ["1000000000"],
      distributor,
      owner
    );

    await claimUserRewardsAndCheckResults(
      orderToken,
      distributor,
      user,
      amountsBigNumber1[0],
      tree1.getProof([user.address, amountsBigNumber1[0].toString()])
    );

    const { tree: tree2, amountsBigNumber: amountsBigNumber2 } = await proposeAndUpdateRootDistribution(
      orderToken,
      [user.address],
      ["3000000000"],
      distributor,
      owner
    );

    await claimUserRewardsAndCheckResults(
      orderToken,
      distributor,
      user,
      amountsBigNumber2[0],
      tree2.getProof(0),
      amountsBigNumber2[0] - BigInt(amountsBigNumber1[0])
    );
  });

  it("should update root after claiming if startTimestamp has passed", async function () {
    const { orderToken, distributor, owner, user } = await distributorFixture();

    // Create first distribution
    await proposeRootDistribution(orderToken, [user.address], ["1000000000"], distributor, owner);

    // Create second distribution
    const { tree: tree2, amountsBigNumber: amountsBigNumber2 } = await proposeAndUpdateRootDistribution(
      orderToken,
      [user.address],
      ["3000000000"],
      distributor,
      owner
    );

    const userBalanceBefore = await orderToken.balanceOf(user.address);

    // Claim user's reward from the active root, the pending root will be promoted during the claim
    const tx = await distributor.connect(user).claimRewards(amountsBigNumber2[0], tree2.getProof(0));
    await expect(tx).to.emit(distributor, "RewardsClaimed").withArgs(anyValue, user.address, amountsBigNumber2[0]);

    // Check that the user token claimed amount has been updated
    expect(await distributor.getClaimed(user.address)).to.be.equal(amountsBigNumber2[0]);

    // Check that the user has received the tokens
    expect(await orderToken.balanceOf(user.address)).to.be.equal(userBalanceBefore + BigInt(amountsBigNumber2[0]));
  });

  it("should fail if the root is not active", async function () {
    const { orderToken, distributor, owner, user } = await distributorFixture();
    const { tree, amountsBigNumber } = await proposeRootDistribution(orderToken, [user.address], ["1000000000"], distributor, owner);
    await expect(distributor.connect(user).claimRewards(amountsBigNumber[0], tree.getProof(0))).to.be.revertedWithCustomError(
      distributor,
      "NoActiveMerkleRoot"
    );
  });

  it("should fail if user not in merkle tree", async function () {
    const { orderToken, distributor, owner, user } = await distributorFixture();
    const { tree, amountsBigNumber } = await proposeAndUpdateRootDistribution(orderToken, [user.address], ["1000000000"], distributor, owner);
    await expect(distributor.connect(owner).claimRewards(amountsBigNumber[0], tree.getProof(0))).to.be.revertedWithCustomError(
      distributor,
      "InvalidMerkleProof"
    );
  });

  it("should fail if user proof is not valid", async function () {
    const { orderToken, distributor, owner, user } = await distributorFixture();
    const { tree, amountsBigNumber } = await proposeAndUpdateRootDistribution(orderToken, [user.address], ["1000000000"], distributor, owner);
    await expect(distributor.connect(user).claimRewards(amountsBigNumber[0] + BigInt(1), tree.getProof(0))).to.be.revertedWithCustomError(
      distributor,
      "InvalidMerkleProof"
    );
  });

  it("check that only owner can pause/unpause", async function () {
    const { distributor, owner, user } = await distributorFixture();

    // Only owner should be able to pause/unpause
    await expect(distributor.connect(user).pause()).to.be.revertedWithCustomError(distributor, "OwnableUnauthorizedAccount");
    await expect(distributor.connect(user).unpause()).to.be.revertedWithCustomError(distributor, "OwnableUnauthorizedAccount");

    // Owner should be able to pause/unpause
    await distributor.connect(owner).pause();
    await distributor.connect(owner).unpause();
  });

  it("pause should fail functions, that requires unpaused state", async function () {
    const { orderToken, distributor, owner, user } = await distributorFixture();
    await distributor.connect(owner).pause();

    const { tree, amountsBigNumber, startTimestamp } = await proposeRootDistribution(orderToken, [user.address], ["1000000000"], distributor, owner);
    await helpers.time.increaseTo(startTimestamp + 1);
    await expect(distributor.connect(owner).updateRoot()).to.be.revertedWithCustomError(distributor, "EnforcedPause");
    await expect(distributor.connect(user).claimRewards(amountsBigNumber[0], tree.getProof(0))).to.be.revertedWithCustomError(
      distributor,
      "EnforcedPause"
    );
    await distributor.connect(owner).unpause();
    await distributor.connect(owner).updateRoot();
    await distributor.connect(user).claimRewards(amountsBigNumber[0], tree.getProof(0));
  });

  it("endTimestamp should be greater than startTimestamp", async function () {
    const { distributor, owner } = await distributorFixture();
    const startTimestamp = (await helpers.time.latest()) + ONE_DAY_IN_SECONDS;
    const endTimestamp = startTimestamp - 1;
    const ipfsCid = encodeIpfsHash("QmS94dN3Tb2vGFtUsDTcDTCDdp8MEWYi5YXZ4goBtFaq2W");
    await expect(distributor.connect(owner).proposeRoot(someRoot, startTimestamp, endTimestamp, ipfsCid)).to.be.revertedWithCustomError(
      distributor,
      "InvalidEndTimestamp"
    );
  });

  it("startTimestamp should be greater than current time", async function () {
    const { distributor, owner } = await distributorFixture();
    const startTimestamp = (await helpers.time.latest()) - 1;
    const endTimestamp = startTimestamp + ONE_DAY_IN_SECONDS;
    const ipfsCid = encodeIpfsHash("QmS94dN3Tb2vGFtUsDTcDTCDdp8MEWYi5YXZ4goBtFaq2W");
    await expect(distributor.connect(owner).proposeRoot(someRoot, startTimestamp, endTimestamp, ipfsCid)).to.be.revertedWithCustomError(
      distributor,
      "StartTimestampIsInThePast"
    );
  });

  it("endTimestamp can be zero", async function () {
    const { distributor, owner } = await distributorFixture();
    const startTimestamp = (await helpers.time.latest()) + ONE_DAY_IN_SECONDS;
    const endTimestamp = 0;
    const ipfsCid = encodeIpfsHash("QmS94dN3Tb2vGFtUsDTcDTCDdp8MEWYi5YXZ4goBtFaq2W");
    await distributor.connect(owner).proposeRoot(someRoot, startTimestamp, endTimestamp, ipfsCid);
  });

  it("can claim if endTimestamp is zero", async function () {
    const { orderToken, distributor, owner, user } = await distributorFixture();
    const { tree, amountsBigNumber } = prepareMerkleTree([user.address], ["1000000000"]);
    const startTimestamp = (await helpers.time.latest()) + ONE_DAY_IN_SECONDS;
    const endTimestamp = 0;
    const ipfsCid = encodeIpfsHash("QmS94dN3Tb2vGFtUsDTcDTCDdp8MEWYi5YXZ4goBtFaq2W");
    const distributorAddress = await distributor.getAddress();

    await distributor.connect(owner).proposeRoot(tree.root, startTimestamp, endTimestamp, ipfsCid);
    await orderToken.connect(owner).transfer(distributorAddress, amountsBigNumber[0]);
    await helpers.time.increaseTo(startTimestamp + 1);

    const distributorBalanceBefore = await orderToken.balanceOf(distributorAddress);
    const userBalanceBefore = await orderToken.balanceOf(user.address);

    await distributor.connect(user).claimRewards(amountsBigNumber[0], tree.getProof(0));

    // Check that the user token claimed amount has been updated
    expect(await distributor.getClaimed(user.address)).to.be.equal(amountsBigNumber[0]);

    // Check that the distributor has transferred the tokens
    expect(await orderToken.balanceOf(distributorAddress)).to.be.equal(distributorBalanceBefore - amountsBigNumber[0]);

    // Check that withdraw impossible if endTimestamp is zero
    await expect(distributor.connect(owner).withdraw()).to.be.revertedWithCustomError(distributor, "DistributionStillActive");
  });

  it("cannot claim if endTimestamp has passed", async function () {
    const { orderToken, distributor, owner, user } = await distributorFixture();
    const { tree, amountsBigNumber } = await proposeAndUpdateRootDistribution(orderToken, [user.address], ["1000000000"], distributor, owner);
    await helpers.time.increaseTo((await helpers.time.latest()) + ONE_DAY_IN_SECONDS * 2);
    await expect(distributor.connect(owner).claimRewards(amountsBigNumber[0], tree.getProof(0))).to.be.revertedWithCustomError(
      distributor,
      "DistributionHasEnded"
    );
  });

  it("can not withdraw if endTimestamp has not passed", async function () {
    const { orderToken, distributor, owner, user } = await distributorFixture();
    orderToken.connect(owner).transfer(await distributor.getAddress(), "10000000000");
    const { tree, amountsBigNumber } = await proposeAndUpdateRootDistribution(orderToken, [user.address], ["1000000000"], distributor, owner);
    await expect(distributor.connect(owner).withdraw()).to.be.revertedWithCustomError(distributor, "DistributionStillActive");
  });

  it("can withdraw if endTimestamp has passed", async function () {
    const { orderToken, distributor, owner, user } = await distributorFixture();
    const distributorAddress = await distributor.getAddress();
    orderToken.connect(owner).transfer(distributorAddress, "10000000000");
    const { tree, amountsBigNumber } = await proposeAndUpdateRootDistribution(orderToken, [user.address], ["1000000000"], distributor, owner);
    await helpers.time.increaseTo((await helpers.time.latest()) + ONE_DAY_IN_SECONDS * 2);

    const distributorBalanceBefore = await orderToken.balanceOf(distributorAddress);
    const ownerBalanceBefore = await orderToken.balanceOf(owner.address);

    await distributor.connect(owner).withdraw();

    // Check that the distributor has transferred the tokens
    expect(await orderToken.balanceOf(distributorAddress)).to.be.equal(0);

    // Check that the owner has received the tokens
    expect(await orderToken.balanceOf(owner.address)).to.be.equal(ownerBalanceBefore + distributorBalanceBefore);
  });

  //   it("check different number of leafs", async function () {
  //     const { orderToken, distributor, owner, user } = await distributorFixture();
  //     const { addresses, amountsBigNumber, tree } = generateMerkleTreeForNLeafs(10);
  //     await proposeAndUpdateRootDistribution(orderToken, addresses, amountsBigNumber, distributor, owner);

  //     for (let i = 0; i < addresses.length; i++) {
  //       await claimUserRewardsAndCheckResults(orderToken, distributor, user, tree.amountsBigNumber[i], tree.tree.getProof(i));
  //     }
  //   });
});
