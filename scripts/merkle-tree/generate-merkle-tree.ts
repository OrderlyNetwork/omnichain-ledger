import { program } from "commander";
import fs from "fs";
import path from "path";
import { parseBalanceMap } from "./parse-balance-map";

(function () {
  program.version("0.0.0").requiredOption("-i, --input <path>", "input JSON file location containing a map of account addresses to string balances");

  program.parse(process.argv);

  const inputPath = program.opts().i || program.opts().input;
  if (!inputPath) return;

  const json = JSON.parse(fs.readFileSync(path.resolve(inputPath), { encoding: "utf8" }));

  if (typeof json !== "object") throw new Error("Invalid JSON");

  const { tree, distributionInfo } = parseBalanceMap(json);

  const outPath = path.resolve(inputPath);
  const outPathParts = outPath.split(".");

  outPathParts.splice(outPathParts.length - 1, 0, "proofs");
  const outPathProofs = outPathParts.join(".");

  outPathParts.splice(outPathParts.length - 2, 1, "standard");
  const outPathStandard = outPathParts.join(".");

  fs.writeFileSync(outPathStandard, JSON.stringify(tree.dump()));
  fs.writeFileSync(outPathProofs, JSON.stringify(distributionInfo, null, 2));
})();
