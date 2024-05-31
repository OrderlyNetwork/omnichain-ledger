import fs from "fs";
import { concat, BytesLike, hexlify as toHex } from "@ethersproject/bytes";
import { Contract } from "ethers";
import { expect } from "chai";
import { StandardMerkleTree } from "@openzeppelin/merkle-tree";
import { keccak256 } from "ethereum-cryptography/keccak";
import { hexToBytes, bytesToHex } from "ethereum-cryptography/utils";
import { defaultAbiCoder } from "@ethersproject/abi";
import { anyValue } from "@nomicfoundation/hardhat-chai-matchers/withArgs";
import * as helpers from "@nomicfoundation/hardhat-network-helpers";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import { INITIAL_SUPPLY, INITIAL_SUPPLY_STR, ONE_DAY_IN_SECONDS, LedgerToken, ledgerFixture } from "./utilities/index";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";

describe("LedgerMerkleDistributor", function () {
  const emptyRoot = "0x0000000000000000000000000000000000000000000000000000000000000000";
  const ipfsCid = encodeIpfsHash("QmS94dN3Tb2vGFtUsDTcDTCDdp8MEWYi5YXZ4goBtFaq2W");

  function compare(a: BytesLike, b: BytesLike): number {
    const diff = BigInt(toHex(a)) - BigInt(toHex(b));
    return diff > 0 ? 1 : diff < 0 ? -1 : 0;
  }

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
    rewardAmount: BigInt,
    proof: string[],
    expectedClaimedAmount?: BigInt
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
      expect(userTotalStakingBalanceAfter).to.be.equal(userTotalStakingBalanceBefore + rewardAmount);
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

  async function checkCeFiProofsFromFile(
    distributor: Contract,
    updater: HardhatEthersSigner,
    user: HardhatEthersSigner,
    distributionId: number,
    cefiProofsFileName: string
  ) {
    const chainId = 1;
    const cefi_merkle_proofs = JSON.parse(fs.readFileSync(cefiProofsFileName, "utf8"));
    const root = cefi_merkle_proofs["root"];
    const startTimestamp = (await helpers.time.latest()) + ONE_DAY_IN_SECONDS;

    // console.log("root: ", root);

    await distributor.connect(updater).createDistribution(distributionId, LedgerToken.ORDER, root, startTimestamp, ipfsCid);
    await helpers.time.increaseTo(startTimestamp + 1);

    let i = 0;
    for (const proof of cefi_merkle_proofs["proofs"]) {
      const claimerAddress = proof["leafValue"]["address"];
      const claimingAmountStr = proof["leafValue"]["amount"];
      const claimingAmountBigInt = BigInt(claimingAmountStr);
      const proofArray = proof["neighbourHashHierarchy"];

      //   console.log("claimerAddress: ", claimerAddress);
      //   console.log("claimingAmountBigInt: ", claimingAmountBigInt);
      //   console.log("proofArray: ", proofArray);

      await expect(distributor.connect(user).claimRewards(distributionId, claimerAddress, chainId, claimingAmountBigInt, proofArray)).to.not.be
        .reverted;
      if (i++ > 100) {
        break;
      }
    }
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
    const distributionId = 1;

    // Root cannot be proposed if distribution is not created
    await expect(distributor.connect(updater).proposeRoot(distributionId, tree.root, startTimestamp, ipfsCid)).to.be.revertedWithCustomError(
      distributor,
      "DistributionNotFound"
    );

    // Create distribution
    await distributor.connect(updater).createDistribution(distributionId, LedgerToken.ESORDER, tree.root, startTimestamp, ipfsCid);

    // User should not be able to propose a root as he has not been granted the ROOT_UPDATER_ROLE
    await expect(distributor.connect(user).proposeRoot(distributionId, tree.root, startTimestamp, ipfsCid)).to.be.revertedWithCustomError(
      distributor,
      "AccessControlUnauthorizedAccount"
    );

    // Updater should be able to propose a root as he has been granted the ROOT_UPDATER_ROLE
    await expect(distributor.connect(updater).proposeRoot(distributionId, tree.root, startTimestamp, ipfsCid)).to.be.revertedWithCustomError(
      distributor,
      "ThisMerkleRootIsAlreadyProposed"
    );

    expect(await distributor.hasPendingRoot(distributionId)).to.be.equal(true);

    const { tree: newTree } = prepareMerkleTree([user.address], [(BigInt(INITIAL_SUPPLY) + BigInt(1)).toString()]);
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

    // console.log("tree.root: ", tree.root);
    // console.log("tree.getProof(0): ", tree.getProof(0));

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
      amountsBigNumber2[0] - amountsBigNumber1[0]
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

  it("should fail if the root is not active", async function () {
    const { orderTokenOft, distributor, user, updater } = await distributorFixture();
    const distributionId = 1;
    const chainId = 1;
    const { tree, amountsBigNumber, startTimestamp, ipfsCid } = await createDistribution(
      LedgerToken.ORDER,
      [user.address],
      ["1000000000"],
      distributor,
      updater,
      distributionId
    );

    await expect(
      distributor.connect(user).claimRewards(distributionId, user.address, chainId, amountsBigNumber[0], tree.getProof(0))
    ).to.be.revertedWithCustomError(distributor, "NoActiveMerkleRoot");
  });

  it("should fail if user not in merkle tree", async function () {
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
    await expect(
      distributor.connect(updater).claimRewards(distributionId, updater.address, chainId, amountsBigNumber[0], tree.getProof(0))
    ).to.be.revertedWithCustomError(distributor, "InvalidMerkleProof");
  });

  it("should fail if user proof is not valid", async function () {
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
    await expect(
      distributor.connect(user).claimRewards(distributionId, user.address, chainId, amountsBigNumber[0] + BigInt(1), tree.getProof(0))
    ).to.be.revertedWithCustomError(distributor, "InvalidMerkleProof");
  });

  it("check that only owner can pause/unpause", async function () {
    const { orderTokenOft, distributor, owner, user, updater } = await distributorFixture();

    // Only owner should be able to pause/unpause
    await expect(distributor.connect(user).pause()).to.be.revertedWithCustomError(distributor, "AccessControlUnauthorizedAccount");
    await expect(distributor.connect(user).unpause()).to.be.revertedWithCustomError(distributor, "AccessControlUnauthorizedAccount");

    // Owner should be able to pause/unpause
    await distributor.connect(owner).pause();
    await distributor.connect(owner).unpause();
  });

  it("pause should fail functions, that requires unpaused state", async function () {
    const { orderTokenOft, distributor, owner, user, updater, operator } = await distributorFixture();
    await distributor.connect(owner).pause();

    const distributionId = 1;
    const chainId = 1;
    const { tree, amountsBigNumber, startTimestamp, ipfsCid } = await createDistribution(
      LedgerToken.ORDER,
      [user.address],
      ["1000000000"],
      distributor,
      updater,
      distributionId
    );
    await helpers.time.increaseTo(startTimestamp + 1);

    await expect(distributor.connect(updater).updateRoot(distributionId)).to.be.revertedWithCustomError(distributor, "EnforcedPause");
    await expect(
      distributor.connect(user).claimRewards(distributionId, user.address, chainId, amountsBigNumber[0], tree.getProof(0))
    ).to.be.revertedWithCustomError(distributor, "EnforcedPause");

    await distributor.connect(owner).unpause();
    await distributor.connect(updater).updateRoot(distributionId);
    await distributor.connect(user).claimRewards(distributionId, user.address, chainId, amountsBigNumber[0], tree.getProof(0));
  });

  it("check pre-calculated root and proof", async function () {
    const { orderTokenOft, distributor, owner, user, updater } = await distributorFixture();
    const distributionId = 1;
    const chainId = 1;
    const root = "0x53bc4e0e5fee341a5efadc8dee7f9a3b2473fdf5669d6dc76cd2d1b878bf981d";
    const startTimestamp = (await helpers.time.latest()) + ONE_DAY_IN_SECONDS;

    await distributor.connect(updater).createDistribution(distributionId, LedgerToken.ORDER, root, startTimestamp, ipfsCid);
    await helpers.time.increaseTo(startTimestamp + 1);

    const claimerAddress = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266";
    const proof = [
      "0xdf6354b3971c117049c8a858663ea0872246715112135016ff08060d47340e87",
      "0x3fb58b77d5c08c8c376180d594601f68ae957d65750a0895151c9a160969a4e6",
      "0x09bc5fd4df3d0b9f5e9010589ee848f55b665ea32e4a7a05e7a053c82707060a"
    ];

    const claimingAmount = BigInt("1000000000000000000");

    expect(await distributor.connect(user).claimRewards(distributionId, claimerAddress, chainId, claimingAmount, proof)).to.not.be.reverted;
  });

  it("check claiming for multiple addresses", async function () {
    const { orderTokenOft, distributor, user, updater } = await distributorFixture();
    const distributionId = 1;
    const { tree, amountsBigNumber } = await proposeAndUpdateRootDistribution(
      LedgerToken.ORDER,
      [
        user.address,
        updater.address,
        user.address,
        updater.address,
        user.address,
        updater.address,
        user.address,
        updater.address,
        user.address,
        updater.address
      ],
      ["1000000000", "2000000000", "3000000000", "4000000000", "5000000000", "6000000000", "7000000000", "8000000000", "9000000000", "10000000000"],
      distributor,
      updater,
      distributionId
    );

    // console.log("tree.root: ", tree.root);
    // console.log("tree.getProof(0): ", tree.getProof(0));

    await claimUserRewardsAndCheckResults(distributor, distributionId, LedgerToken.ORDER, user, amountsBigNumber[0], tree.getProof(0));
    await claimUserRewardsAndCheckResults(distributor, distributionId, LedgerToken.ORDER, updater, amountsBigNumber[1], tree.getProof(1));
  });

  it("check leaf calculation", async function () {
    const address = "0xa0Ee7A142d267C1f36714E4a8F75612F20a79720";
    const amount = BigInt("10000000000000000000");

    const leafHash =
      "0x" + bytesToHex(keccak256(keccak256(hexToBytes(defaultAbiCoder.encode(["address", "uint256"], [address, amount.toString()])))));
    expect(leafHash).to.be.equal("0x3cf24d4ee0659da84e4b7e3691f5ca0e7d0953c4d3d846157b2505645b757dcf");

    const address2 = "0x23618e81E3f5cdF7f54C3d65f7FBc0aBf5B21E8f";
    const amount2 = BigInt("9000000000000000000");

    const leafHash2 =
      "0x" + bytesToHex(keccak256(keccak256(hexToBytes(defaultAbiCoder.encode(["address", "uint256"], [address2, amount2.toString()])))));
    expect(leafHash2).to.be.equal("0xdf6354b3971c117049c8a858663ea0872246715112135016ff08060d47340e87");
  });

  it("check node hash calculation", async function () {
    const hash1String = "0x6041be6862f1a78c25324286b09860e73f19c463a350fda03e2202cbdef54ee4";
    const hash1Bytes = hexToBytes(hash1String);
    const hash2String = "0x3cf24d4ee0659da84e4b7e3691f5ca0e7d0953c4d3d846157b2505645b757dcf";
    const hash2Bytes = hexToBytes(hash2String);

    const nodeHash1String = bytesToHex(keccak256(concat([hash1String, hash2String].sort(compare))));
    // console.log("nodeHash1String: ", nodeHash1String);
    expect(nodeHash1String).to.be.equal("ab98ef8951c536e1e386b139670674cb37c5dff89d72072aed9a32b8476ee00f");

    const nodeHash2String = bytesToHex(keccak256(concat([hash2String, hash1String].sort(compare))));
    expect(nodeHash2String).to.be.equal("ab98ef8951c536e1e386b139670674cb37c5dff89d72072aed9a32b8476ee00f");
    // console.log("nodeHash2String: ", nodeHash2String);

    const nodeHash1Bytes = bytesToHex(keccak256(concat([hash1Bytes, hash2Bytes].sort(compare))));
    expect(nodeHash1Bytes).to.be.equal("ab98ef8951c536e1e386b139670674cb37c5dff89d72072aed9a32b8476ee00f");
    // console.log("nodeHash1Bytes: ", nodeHash1Bytes);

    const nodeHash2Bytes = bytesToHex(keccak256(concat([hash2Bytes, hash1Bytes].sort(compare))));
    expect(nodeHash2Bytes).to.be.equal("ab98ef8951c536e1e386b139670674cb37c5dff89d72072aed9a32b8476ee00f");
    // console.log("nodeHash2Bytes: ", nodeHash2Bytes);
  });

  it("check CeFi root and proof first", async function () {
    const { orderTokenOft, distributor, owner, user, updater } = await distributorFixture();
    const distributionId = 1;
    const chainId = 1;
    const root = "0xed0356e9e77a42df396b19f4ae34c0551e77646876d6d1ad33eb0c6142c84721";
    const startTimestamp = (await helpers.time.latest()) + ONE_DAY_IN_SECONDS;

    await distributor.connect(updater).createDistribution(distributionId, LedgerToken.ORDER, root, startTimestamp, ipfsCid);
    await helpers.time.increaseTo(startTimestamp + 1);

    const claimerAddress1 = "0x23618e81E3f5cdF7f54C3d65f7FBc0aBf5B21E8f";
    const claimingAmount1 = BigInt("9000000000000000000");
    const proof1 = [
      "0xd8b413ffc6023e4aea407df01bac0abcfac6b349db16bb6b2d49e6fa9f834040",
      "0x0ad03fee1ce220098eecf119709aa8533e99532019819fb117a0b01a0212472c",
      "0xcf7d0d4c8b5c18c3788e473dc0cdc256c5f2b01c8eca797ea19ceded9a184c49"
    ];
    await expect(distributor.connect(user).claimRewards(distributionId, claimerAddress1, chainId, claimingAmount1, proof1)).to.not.be.reverted;

    const claimerAddress2 = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266";
    const claimingAmount2 = BigInt("1000000000000000000");
    const proof2 = [
      "0xdf6354b3971c117049c8a858663ea0872246715112135016ff08060d47340e87",
      "0x0ad03fee1ce220098eecf119709aa8533e99532019819fb117a0b01a0212472c",
      "0xcf7d0d4c8b5c18c3788e473dc0cdc256c5f2b01c8eca797ea19ceded9a184c49"
    ];
    await expect(distributor.connect(user).claimRewards(distributionId, claimerAddress2, chainId, claimingAmount2, proof2)).to.not.be.reverted;

    const claimerAddress3 = "0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc";
    const claimingAmount3 = BigInt("6000000000000000000");
    const proof3 = [
      "0xae04af11dc3968a94f29f8d0b4f11c1890c2483a239c5a333545fc73d953bb1d",
      "0x93544216020fd51b6fcaaa9a88420f01d90f6298a4c39c1d20b02653b578eb60",
      "0xcf7d0d4c8b5c18c3788e473dc0cdc256c5f2b01c8eca797ea19ceded9a184c49"
    ];
    await expect(distributor.connect(user).claimRewards(distributionId, claimerAddress3, chainId, claimingAmount3, proof3)).to.not.be.reverted;
  });

  it("check CeFi root and proof from files", async function () {
    const { orderTokenOft, distributor, owner, user, updater } = await distributorFixture();

    await checkCeFiProofsFromFile(distributor, updater, user, 1, "./test/cefi_merkle_proofs_6_leafs.json");
    await checkCeFiProofsFromFile(distributor, updater, user, 2, "./test/cefi_merkle_proofs_11_leafs.json");
    await checkCeFiProofsFromFile(distributor, updater, user, 3, "./test/cefi_merkle_proofs_20k_leafs.json");
  });
});
