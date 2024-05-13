import { BigNumber, BigNumberish } from "ethers";
const { ethers } = require("hardhat");

export const BASE_TEN = 10;
export const INITIAL_SUPPLY = fullTokens(1_000_000);
export const INITIAL_SUPPLY_STR = INITIAL_SUPPLY.toString();
export const TOTAL_SUPPLY = INITIAL_SUPPLY.mul(2);
export const TOTAL_SUPPLY_STR = TOTAL_SUPPLY.toString();
export const ONE_HOUR_IN_SECONDS = 60 * 60;
export const ONE_DAY_IN_SECONDS = ONE_HOUR_IN_SECONDS * 24;
export const ONE_WEEK_IN_SECONDS = ONE_DAY_IN_SECONDS * 7;
export const ONE_YEAR_IN_SECONDS = ONE_DAY_IN_SECONDS * 365;
export const HALF_YEAR_IN_SECONDS = ONE_YEAR_IN_SECONDS / 2;

// Defaults to e18 using amount * 10^18
export function fullTokens(amount: BigNumberish, decimals = 18): BigNumber {
  return BigNumber.from(amount).mul(BigNumber.from(BASE_TEN).pow(decimals));
}

export function closeTo(value: BigNumberish, target: BigNumberish, precision: BigNumberish): boolean {
  return BigNumber.from(value).sub(target).abs().lte(precision);
}

export enum LedgerToken {
  ORDER,
  ESORDER
}
