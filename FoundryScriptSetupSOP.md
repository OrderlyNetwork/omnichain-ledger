
# Foundry Script Setup SOP
1. Setup Network Configurations

    example: 
    ```bash
    ARBSEPOLIA_PRIVATE_KEY="0x<private-key>"
    ARBSEPOLIA_CHAIN_ID="421614"
    RPC_URL_ARBSEPOLIA="https://sepolia-rollup.arbitrum.io/rpc"
    #### Explorer information
    ARBSEPOLIA_EXPLORER_TYPE="etherscan"
    ARBSEPOLIA_EXPLORER_API_URL="https://api-sepolia.arbiscan.io/api"
    ARBSEPOLIA_ETHERSCAN_API_KEY="<api-key>"
    #### Layerzero information
    ARBSEPOLIA_LZ_EID="40231" # Layerzero V2 EID
    ARBSEPOLIA_ENDPOINT="0x6098e96a28E02f27B1e6BD381f870F1C8Bd169d3"
    ```

2. Setup Other Contracts(OFT, USDC) Deployment Addresses
    example:
    ```bash
    ARBSEPOLIA_OFT_ADDRESS="0x6850bdEe5a830AE53b161B3246d68F202a6C14B7"
    ARBSEPOLIA_USDC_ADDRESS="0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d"
    ```
3. Setup Ledger Addresses in Config Json: `config/ledger.json`
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