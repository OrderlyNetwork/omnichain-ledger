# Omnichain Ledger contract

## Specifications:

https://wootraders.atlassian.net/wiki/spaces/ORDER/pages/566526155/Omnichain+Contract+Interactions

## Quick start:

> **NOTE:** Before using any other commands, started from `yarn` please run:
>
> - Install dependencies
>
> ```shell
> yarn
> ```

- Compile contracts

```shell
yarn build
```

## Tests:

- Hardhat tests

```shell
yarn test
```
## Deployment:

### Before deployment:
Project use .env file for storing environment variables. You can create .env file using .env.example as a template.

#### Env variables for deployment:
- For signing deployment transactions you can set PRIVATE_KEY or MNEMONIC for separate chain (preferred if set) or `COMMON_PRIVATE_KEY` or `COMMON_MNEMONIC` for all chains.
- Project use deterministic deployment with salt. It means that repeateed deployment with the same salt will upgrade contract's implementation, but leave the same proxy address. Set `DETERMINISTIC_DEPLOYMENT_SALT` with already used salt to upgrade contract's implementation or set new salt to deploy new proxy contract. Rule for salt value: env_nameContractVersion. Example: "dev100" for dev environment and contract version 1.0.0, "staging101" for staging environment and contract version 1.0.1. Commit used salt name in commit message for deployment updates.
- Set `MDL1_ORDER_TOKEN_ADDRESS` to provide MerkleDistributorL1 contract with ORDER token address.

#### Deployment scripts and deployment artifacts:
Contracts can be deployed by scripts, that are stored in `scripts\deploy` folder. There are special scripts for separate contracts deployment:
- `001_deploy_ledger_contract.ts` - for OmnichainLedgerV1 and OmnichainLedgerTestV1 contract (difference is in constructor parameters: OmnichainLedgerTestV1 setup for minutes periods instead of days in OmnichainLedgerV1)
- `002_deploy_mdl1_contract.ts` - for MerkleDistributorL1 contract

Contracts deployed by scripts to the specified network. Separate contracts can be deployed to the particular networks. For example:
- OmnichainLedger deployed to the `orderlySepolia` network.
- MerkleDistributorL1 deployed to the `sepolia' (Ethereum Sepolia) network.

Deployment artifacts stored in `deployments` folder in subfolder with network name. For example `deployments/orderlySepolia`. It is created after successful deployment.
Also there are several environments: `dev`, `qa`, `staging`. However, for different environments contracts deployed to the same network. To store deployment artifacts for different environments, you have to rename deployment artifacts folder, adding environment name. For example, for `dev` environment deployment artifacts folder will be `deployments/orderlySepolia_dev`.

If you going to upgrade implementation contract, leave the same proxy address, you have to rename deployment artifacts folder back to the original name and set DETERMINISTIC_DEPLOYMENT_SALT to the same salt value for deployment. For example, to upgrade dev environment contract with version 1.0.1, you have to rename `deployments/orderlySepolia_dev` to `deployments/orderlySepolia` and set DETERMINISTIC_DEPLOYMENT_SALT to "dev101".

If you going to deploy new proxy contract, you have to set new salt value to the DETERMINISTIC_DEPLOYMENT_SALT for deployment. For example, to deploy new dev environment contract with version 1.0.2, you have to set DETERMINISTIC_DEPLOYMENT_SALT to "dev102". After successful deployment rename deployment artifacts folder to `deployments/orderlySepolia_dev` and commit it, mentionign new salt value in commit message.

Deployment scripts also verify contract's implementation after deployment. There are two methods for contract verification, that works better for different chains:
- verify-hardhat
- verify-etherscan - default one
If verification step is failed for some reason, please change (uncomment) verification method in the `scripts/tasks/deploy_to.ts` and repeat deployment command. If contract successfully deployed to the specified network with currently set salt, it will not re-deploy contract again, but only verify it.

### MerkleDistributorL1 deployment:
- Set `COMMON_PRIVATE_KEY` or `COMMON_MNEMONIC` in .env file (see above part for details)
- Set `DETERMINISTIC_DEPLOYMENT_SALT` in .env file (see above for details)
- Set `MDL1_ORDER_TOKEN_ADDRESS` in .env file to provide MerkleDistributorL1 contract with ORDER token address.
- Make call:
```shell
yarn deploy-to sepolia
```
- Rename deployment artifacts folder (see above for details) and commit changes with mentioning salt value in commit message.

### OmnichainLedgerV1 deployment:
- Set `COMMON_PRIVATE_KEY` or `COMMON_MNEMONIC` in .env file (see above part for details)
- Set `DETERMINISTIC_DEPLOYMENT_SALT` in .env file (see above for details)
- Set `OCC_ADAPTOR_ADDRESS` in .env file to provide OmnichainLedgerV1 contract with OCC Adaptor address. If not set, contract will be deployed with zero address as OCC Adaptor address. It can be set later by owner call `setOccAdaptor` function.
- Make call:
```shell
yarn deploy-to orderlySepolia
```
It will deploy OmnichainLedgerV1 and OmnichainLedgerTestV1 contracts.
- Rename deployment artifacts folder (see above for details) and commit changes with mentioning salt value in commit message.
- Make owner call `setOccAdaptor` function to set OCC Adaptor address if not set during deployment.
- `valorEmissionStartTimestamp` is set to 24 hours after deployment timestamp by default. It can be set later by owner call `setValorEmissionStartTimestamp` function. But only before currently set timestamp passed. After Valor emission started, it can't be changed.

## Scripts for calling contract functions:

> **NOTE:** All scripts required specification of contract address and network.
> Network should be specified as a parameter `--network <network-name>`
> Contract address can be specified in two ways:
> - As an optional parameter `--contract-address <contract-address>` - preferred
> - As an environment variable `CONTRACT_ADDRESS`


### Omnichain Ledger role management

- Transfer ownership
    
```shell
yarn ledger-transfer-ownership --to 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 --network orderlySepolia
```

- Grant  TREASURE_UPDATER_ROLE
```shell
yarn hardhat ledger-grant-root-updater-role --to 0x2FA47E9a2a9d1b0A13BF84Ff38F7B54617C9614f --network orderlySepolia
```

- Revoke  TREASURE_UPDATER_ROLE
```shell
yarn ledger-revoke-treasure-updater-role --from 0x2FA47E9a2a9d1b0A13BF84Ff38F7B54617C9614f --network orderlySepolia
```

- Grant  ROOT_UPDATER_ROLE
```shell
yarn ledger-grant-root-updater-role --to 0x2FA47E9a2a9d1b0A13BF84Ff38F7B54617C9614f --network orderlySepolia
```

- Revoke  ROOT_UPDATER_ROLE
```shell
yarn ledger-revoke-root-updater-role --from 0x2FA47E9a2a9d1b0A13BF84Ff38F7B54617C9614f --network orderlySepolia
```

### Omnichain Ledger Merkle Distributor

- Create distribution

```shell
yarn hardhat ledger-create-distribution --network orderlySepolia --distribution-id 1 --token ORDER --root 0x53bc4e0e5fee341a5efadc8dee7f9a3b2473fdf5669d6dc76cd2d1b878bf981d --start-timestamp 1717747711 ```