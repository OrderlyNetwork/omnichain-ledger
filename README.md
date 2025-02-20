# Omnichain Ledger contract

## [Latest changes (Solana support)](#solana-support)

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

## After deployment:

### MerkleDistributorL1 setup:
#### Set token address:
- MDL1 contract can distribut only one particular token. Token address can be set during deployment or later by owner call `setTokenAddress(IERC20 _token)`. This function can be called only once and only if token address is not set during deployment.

#### Propose Merkle root:
- To create distribution MDL1 contract should be provided with Merkle root by owner call `function proposeRoot(bytes32 _merkleRoot, uint256 _startTimestamp, uint256 _endTimestamp, bytes calldata _ipfsCid)`. Distribution will start after `_startTimestamp` passed and will be active until `_endTimestamp` passed. If _endTimestamp is set to 0, distribution will be active forever. _ipfsCid is optional parameter, it can be empty or `0x` if not used.
- Merkle root can be proposed more than once to support distribution of cummulatively added rewards. In this case Merkle root can be proposed every epoch. Each new root should contain all previous rewards and users to give users ability to claim rewards from previous epochs. Amounts of rewards for each user should be cummulatively increased by n-th epoch. Contract stores already claimed amounts for each user and if user already claimed reward from previous epoch, he will not be able to claim it again. Proposed Merkle root will become active after `_startTimestamp` passed for it.

#### Provide liquidity:
- It is off-chain owner responsibility to provide enough liquidity for distribution. Tokens should be transferred to MDL1 contract address before distribution starts. If there is not enough tokens on contract balance, users will not be able to claim rewards.

### OmnichainLedgerV1 setup:
#### Set up:
- To function properly, OmnichainLedgerV1 contract should be provided with OCC Adaptor address. It can be set by owner call `setOccAdaptor(IOmnichainAdaptor _occAdaptor)`. It can be called more than once.
- Set Valor emission start timestamp. By default, Valor emission starts 24 hours after deployment timestamp. It can be set by owner call `setValorEmissionStartTimestamp(uint256 _valorEmissionStartTimestamp)`. But only before currently set timestamp passed. After Valor emission started, it can't be changed.
- Minimal forever stake. To prevent edge cases with zero stakes, contract should be provided with minimal stake amount, that will be never withdrawn. It can be done as usual stake from one of vault chains. It can be as minimal as 0.01 ORDER. Minimal forever stake should be done before Valor emission started.

#### Create reward distribution:
OmniChainLedgerV1 contract supports distribution of two types of tokens: ORDER and esORDER (record based).
- To create reward distribution, owner should call function `createDistribution(uint32 _distributionId, LedgerToken _token, bytes32 _merkleRoot, uint256 _startTimestamp, bytes calldata _ipfsCid)`, provideing unique distribution id, token type, and Merkle root. Distribution will start after `_startTimestamp` passed. _ipfsCid is optional parameter, it can be empty or `0x` if not used. After distribution created, it's impossible to change it's token type.
- Each distribution supports cummulative distribution of rewards. Owner can propose Merkle root for the same distribution id by calling `proposeRoot(uint32 _distributionId, bytes32 _merkleRoot, uint256 _startTimestamp, bytes calldata _ipfsCid)`. Each new root should contain all previous rewards and users to give users ability to claim rewards from previous epochs. Amounts of rewards for each user should be cummulatively increased by n-th epoch. Contract stores already claimed amounts for each user and if user already claimed reward from previous epoch, he will not be able to claim it again. Proposed Merkle root will become active after `_startTimestamp` passed for it.

#### Provide liquidity:
- It is off-chain owner responsibility to provide enough liquidity for ORDER distribution. Tokens should be transferred to OmnichainLedgerV1 contract address before distribution starts. If there is not enough tokens on contract balance, users will not be able to claim rewards. For esORDER token type, it is not necessary to provide liquidity, because such tokens are record based and a kind of virtual.

#### Calling dailyUsdcNetFeeRevenue function:
- `dailyUsdcNetFeeRevenue` function suppose to be called daily by operator to update daily USDC net fee revenue. It also updates `valorToUsdcRateScaled` that is a kind of exchange rate between Valor and USDC. Also it updates `fixedValorToUsdcRateScaled` for Valor redemption batches. It is important, that this function should be called at least one time before first batch ends (14 days after Valor emission started).

### Scripts for calling contract functions:

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
yarn hardhat ledger-create-distribution --network orderlySepolia --distribution-id 1 --token ORDER --root 0x53bc4e0e5fee341a5efadc8dee7f9a3b2473fdf5669d6dc76cd2d1b878bf981d --start-timestamp 1717747711
```

## Solana support

### EVM contracts architecture for Solana support

For the EVM-compatible Vault chains we use OFT lzCompose for delivering messages from Proxy contract on Vault chain to OCCManager on the Orderly chain and back. The OCCManager contract in its turn calls the OmnichainLedger contract to process user requests.

Because of Solana specific and limitations, we have to implement different approach to deliver messages from Solana to OmnichainLedger contract on Orderly chain. OFT lzCompose is used for delivering only `Stake` request along with $ORDER tokens transfer. For other request types we implemented a [Solana Proxy](https://gitlab.com/orderlynetwork/orderly-v2/solana-proxy) as a LayerZero Oapp to send the messages.

For backward messages from Orderly chain to Solana we use OFT lzCompose for delivering the messages with $ORDER token transfer, but for `ClaimUsdcRevenueBackward` we implemented LedgerOApp (included in [Solana Proxy repo](https://gitlab.com/orderlynetwork/orderly-v2/solana-proxy)) as a LayerZero Oapp to send the message.

To suppport LayerZero Oapp send-receive mechanism we have created `LedgerOapp` contract, that implements Oapp-spcific interface. This contract is implemented as part of Solana Proxy project in separate repository. In this project `LedgerOapp` contract is presented by `ILedgerOapp` interface. This interface implements function `ledgerOappSend`, that used for backward messages to Vault Proxy contract on Solana.

For most of the incoming requests, entry point is `ledgerOappReceive` function in OCCManager contract, that is locked to be called by LedgerOzpp contract.
For `Stake` requests entry point is `lzCompose` function in LedgerOCCManager contract.
For backward messages entry point is `ledgerSendToVault` function in LedgerOCCManager contract.

### Payload Types and Message Flow for Solana support

| #   | Payload Type                | Direction | Transport | Function          | Notes                                               |
| --- | --------------------------- | --------- | --------- | ----------------- | --------------------------------------------------- |
| 0   | ClaimReward                 | Forward   | OFT       | lzCompose         | EVM-specific reward claim, NOT supported for Solana |
| 1   | Stake                       | Forward   | OFT       | lzCompose         | Token staking                                       |
| 2   | CreateOrderUnstakeRequest   | Forward   | OApp      | ledgerOappReceive | Request to unstake ORDER                            |
| 3   | CancelOrderUnstakeRequest   | Forward   | OApp      | ledgerOappReceive | Cancel pending unstake                              |
| 4   | WithdrawOrder               | Forward   | OApp      | ledgerOappReceive | Withdraw staked ORDER                               |
| 5   | EsOrderUnstakeAndVest       | Forward   | OApp      | ledgerOappReceive | Unstake and vest esORDER                            |
| 6   | CancelVestingRequest        | Forward   | OApp      | ledgerOappReceive | Cancel specific vesting                             |
| 7   | CancelAllVestingRequests    | Forward   | OApp      | ledgerOappReceive | Deprecated - NOT supported anymore                  |
| 8   | ClaimVestingRequest         | Forward   | OApp      | ledgerOappReceive | Claim vested tokens                                 |
| 9   | RedeemValor                 | Forward   | OApp      | ledgerOappReceive | Redeem Valor tokens                                 |
| 10  | ClaimUsdcRevenue            | Forward   | OApp      | ledgerOappReceive | Claim USDC revenue                                  |
| 11  | ClaimRewardBackward         | Backward  | OFT       | ledgerSendToVault | Reward claim response                               |
| 12  | WithdrawOrderBackward       | Backward  | OFT       | ledgerSendToVault | Withdrawal response                                 |
| 13  | ClaimVestingRequestBackward | Backward  | OFT       | ledgerSendToVault | Vesting claim response                              |
| 14  | ClaimUsdcRevenueBackward    | Backward  | OApp      | ledgerSendToVault | USDC claim response                                 |
| 15  | UnstakeOrderNow             | Forward   | OApp      | ledgerOappReceive | Immediate unstaking                                 |
| 16  | ClaimRewardSolana           | Forward   | OApp      | ledgerOappReceive | Solana-specific reward claim. For Solana only       |

### Solana address mapping

EVM address consists of 20 bytes, while Solana address consists of 32 bytes. To support Solana users in EVM-based OmnichainLedger contract while avoid crucial changes in it and it's internal storage implementation, we have to map Solana addresses to EVM addresses. This mapping is implemented in the OCCManager contract. There are two mappings actually:

- `userSolana2EvmAddress` - mapping from Solana address to EVM address, used to avoid address calculation if user already known
- `userEvm2SolanaAddress` - mapping from EVM address to Solana address, used to be able to send messages back to Solana user

Each time when Solana user send request to the OCCManager contract, it checks if user's Solana address is mapped to EVM address. If not, it calculates correspondent EVM-like 20 bytes address for this user and creates new mapping. EVM-like address calculation is implemented in publicly accessible function `calculateUserSolana2EvmAddress`. It use last 20 bytes of keccak256 hash of abi-encoded Solana address. So, anyone can check, which EVM address will be calculated for any Solana address.

### Claim reward Solana specific

It appeared, that there is strong limitation on amount of data, that can be sent from Solana to EVM chain using any of the available methods. For claim reward call, using conventional method of checking Merkle Proof in the OmnichainLedger's MerkleDistributor, we have to send Merkle proof, that is much bigger than available data limit.

To overcome this limitation, we have implemented Solana-specific claim reward method. It supposed, that user provide Merkle proof along with token amount on Solana side to the Proxy contract, that calculates Merkle root from the user address, token amount and provided proof, and sends the root with other information to the OmnichainLedger through the LedgerOapp contract. Merkle root is much smaller, than Merkle proof and satisfy data limitation.

This method requires separate payload type `ClaimRewardSolana`, that is used for Solana-specific reward claim. It also required update for internal processing of the claim reward in the OmnichainLedger contract.

OmnichainLedger contract can trust to the Merkle root, that is used as proof in `ClaimRewardSolana` request, because of the following reasons:

- it is calculated in the trusted environment (Proxy contract)
- channel, that it receibed by, locked to LedgerOapp, that paired only with Proxy contract on the Solana side.

### Tests for Solana support

There is a set of tests for Solana support in the `test/forge/LedgerSolana.t.sol` file. They are testing Solana-specific requests from OCCManager entry point to the OmnichainLedger contract and sending back messages. There are tests for all supported payload types, that are used for Solana support.

To run tests for Solana support, you have to run:

```shell
forge test --match-contract LedgerSolanaTest
```

Specific test for Solana-specific reward claim:

```shell
forge test -vvvv --match-test test_solana_oapp_receive_fail_cases
```