import { Artifact, HardhatRuntimeEnvironment } from "hardhat/types";
import { Deployment } from "hardhat-deploy/types";

export async function deployContract(hre: HardhatRuntimeEnvironment, name: string, args: any[], proxy?: "proxyInit" | "proxyNoInit") {
  const { deployments, getNamedAccounts } = hre;
  const { deploy } = deployments;
  const { deployer } = await getNamedAccounts();

  const baseDeployArgs = {
    from: deployer,
    log: true,
    autoMine: hre.network.tags.test,
    deterministicDeployment: hre.ethers.encodeBytes32String(process.env.DETERMINISTIC_DEPLOYMENT_SALT || "deterministicDeploymentSalt")
  };

  let contract;
  try {
    contract =
      proxy === "proxyInit"
        ? await deploy(name, {
            ...baseDeployArgs,
            proxy: {
              owner: deployer,
              proxyContract: "UUPS",
              execute: {
                init: {
                  methodName: "initialize",
                  args: args
                }
              },
              upgradeFunction: {
                methodName: "upgradeToAndCall",
                upgradeArgs: ["{implementation}", "{data}"]
              }
            }
          })
        : proxy === "proxyNoInit"
          ? await deploy(name, {
              ...baseDeployArgs,
              proxy: {
                owner: deployer,
                proxyContract: "UUPS",
                upgradeFunction: {
                  methodName: "upgradeToAndCall",
                  upgradeArgs: ["{implementation}", "0x"]
                }
              }
            })
          : await deploy(name, {
              ...baseDeployArgs,
              args: args
            });
  } catch (e) {
    console.log(e);
  }

  return contract;
}

export async function verifyContractByHardhat(hre: HardhatRuntimeEnvironment, name: string, contract: Deployment, proxy?: boolean) {
  const artifact: Artifact = await hre.deployments.getArtifact(name);
  const contractFullyQualifiedName = artifact.sourceName + ":" + artifact.contractName;

  if (hre.network.name !== "hardhat") {
    try {
      const timeoutVerificationPromise = new Promise((_, reject) => {
        setTimeout(() => {
          reject(new Error("Verification timed out"));
        }, 100000);
      });

      console.log(
        "yarn hardhat verify --contract",
        contractFullyQualifiedName,
        "--network",
        hre.network.name,
        contract.address,
        proxy === true || contract.args === undefined ? "" : contract.args.join("")
      );

      await Promise.race([
        hre.run("verify:verify", {
          address: contract.address,
          constructorArguments: proxy === true ? [] : contract.args ?? [],
          contract: contractFullyQualifiedName
        }),
        timeoutVerificationPromise
      ]);
    } catch (e) {
      if (typeof e === "string") {
        console.log(e.toUpperCase()); // works, `e` narrowed to string
      } else if (e instanceof Error) {
        console.log(e.message); // works, `e` narrowed to Error
      }
    }
  }
}
