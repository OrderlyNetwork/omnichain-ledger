
# Foundry Script Setup SOP
1. Setup Network Configurations

    example: 
    ```bash
    <network-name>_PRIVATE_KEY="0x<private-key>"
    <network-name>_CHAIN_ID="421614"
    RPC_URL_<network-name>="https://sepolia-rollup.arbitrum.io/rpc"
    #### Explorer information
    <network-name>_EXPLORER_TYPE="etherscan"
    <network-name>_EXPLORER_API_URL="https://api-sepolia.arbiscan.io/api"
    <network-name>_ETHERSCAN_API_KEY="<api-key>"
    #### Layerzero information
    <network-name>_LZ_EID="40231" # Layerzero V2 EID
    <network-name>_V2_ENDPOINT="0x<layerzero-v2-endpoint>"
    ```

2. Setup Other Contracts(USDC) Deployment Addresses
    example:
    ```bash
    <network-name>_USDC_ADDRESS="0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d"
    ```
3. Setup OFT contracts in `config/oft.json`
    example:
    ```json
    {
        "dev": {
            "sepolia": "0x581BE804Ba3A74DFcD86014c093042EB93508876",
            ...
        },
        "qa": {
            "sepolia": "0x90573a6725202A16cd7d786167d947FC3fB1e628",
            ...
        }
    }
    ```

4. Setup Ledger Addresses in Config Json: `config/ledger.json`
    example:
    ```json
    {
        "dev": {
            "ledger": {
                "impl": "0x<ledger-impl-address>",
                "proxy": "0x<ledger-proxy-address>"
            },
            "ledger_occ_manager": { },
            "ledger_proxy": {
                "<network-name>": {}
                ...
            },
        },
        "qa": {
            ...
        }
        ...
    }

# Proxy Ledger Deployment SOP

1. finish foundry script setup like above 

2. run deploy scripts
    example:
    ```bash
    ts-node scripts/ts_foundry/run.ts --method ProxyLedgerDeploy --env qa --network sepolia --broadcast 
    ```

3. setup ledger proxy
    example:
    ```bash
    ts-node scripts/ts_foundry/run.ts --method ProxyLedgerSetup --env qa --network sepolia --broadcast 
    ```

4. verify contracts
    example:
    ```bash
    ts-node scripts/ts_foundry/run.ts --method verifyContract --env qa --network sepolia --contract ledger_proxy --compilerVersion 0.8.22
    ```

5. Setup on orderly chain side
    example:
    ```bash
    ts-node scripts/ts_foundry/run.ts --method LedgerOCCManagerAddNewChain --env qa --newNetwork basesepolia --broadcast
    ```

6. update contract addressed in information board

# Ledger OCC Manager Deployment SOP

1. finish foundry script setup like above

2. run deploy scripts
    example:
    ```bash
    ts-node scripts/ts_foundry/run.ts --method LedgerOCCManagerDeploy --env qa --network sepolia --broadcast
    ```
3. setup ledger occ manager
    example:
    ```bash
    ts-node scripts/ts_foundry/run.ts --method LedgerOCCManagerSetup --env qa --network sepolia --broadcast
    ```
4. verify contracts
    example:
    ```bash
    ts-node scripts/ts_foundry/run.ts --method verifyContract --env qa --network sepolia --contract ledger_occ_manager --compilerVersion 0.8.22
    ```
5. update contract addressed in information board