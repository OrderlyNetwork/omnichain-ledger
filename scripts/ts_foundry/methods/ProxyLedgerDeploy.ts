
// generated by scripts/ts_foundry/methods/gen.ts
// Path: scripts/foundry/ProxyLedgerDeploy.s.sol
import { addOperation } from "../utils/config";
import { set_env_var, foundry_wrapper } from "../foundry";
import { checkArgs } from "../utils/helper";

// current file name
const method_name = "ProxyLedgerDeploy";

export function ProxyLedgerDeployWithArgv(argv: any) {
    const required_flags = ["env", "network", "broadcast"];
    checkArgs(method_name, argv, required_flags);
    ProxyLedgerDeploy(argv.env, argv.network, argv.broadcast, argv.simulate);
}

export function ProxyLedgerDeploy(env: string, network: string, broadcast: boolean, simulate: boolean) {
    

    set_env_var(method_name, "env", env);
    set_env_var(method_name, "network", network);
    set_env_var(method_name, "broadcast", broadcast.toString());
    foundry_wrapper(method_name, broadcast, simulate);

}

addOperation(method_name, ProxyLedgerDeployWithArgv);
