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