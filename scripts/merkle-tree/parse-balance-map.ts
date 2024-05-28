import BN from "bn.js";
import { StandardMerkleTree } from "@openzeppelin/merkle-tree";
import fs from "fs";

export interface MerkleDistributorInfo {
  merkleRoot: string;
  tokenTotal: string;
  claims: {
    [account: string]: {
      amount: string;
      proof: string[];
      flags?: {
        [flag: string]: boolean;
      };
    };
  };
}

export type BalanceFormat = { address: string; earnings: string; reasons: string };

export function parseBalanceMap(balances: BalanceFormat[]): { tree: StandardMerkleTree<string[]>; distributionInfo: MerkleDistributorInfo } {
  const dataByAddress = balances.reduce<{
    [address: string]: { amount: BN; flags?: { [flag: string]: boolean } };
  }>((memo, { address: account, earnings, reasons }) => {
    if (memo[account]) throw new Error(`Duplicate address: ${account}`);
    const parsedNum = new BN(earnings);
    if (parsedNum.lte(new BN(0))) throw new Error(`Invalid amount for account: ${account}`);

    const flags = {
      // isSOCKS: reasons.includes('socks'),
      // isLP: reasons.includes('lp'),
      // isUser: reasons.includes('user'),
    };

    memo[account] = { amount: parsedNum, ...(reasons === "" ? {} : { flags }) };
    return memo;
  }, {});

  const pairs = Object.keys(dataByAddress).map(address => [address, dataByAddress[address].amount.toString()]);

  const tree = StandardMerkleTree.of(pairs, ["address", "uint256"]);

  // generate claims
  const claims = Object.keys(dataByAddress).reduce<{
    [address: string]: { amount: string; proof: string[]; flags?: { [flag: string]: boolean } };
  }>((memo, address) => {
    const { amount, flags } = dataByAddress[address];
    memo[address] = {
      amount: amount.toString(),
      proof: tree.getProof([address, amount.toString()]).map(proof => proof.substring(2)),
      ...(flags ? { flags } : {})
    };
    return memo;
  }, {});

  const tokenTotal: BN = pairs.reduce((memo, [, amount]) => memo.add(new BN(amount)), new BN(0));

  return {
    tree,
    distributionInfo: {
      merkleRoot: tree.root,
      tokenTotal: tokenTotal.toString(),
      claims
    }
  };
}
