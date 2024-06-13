
import { addArgvType, addOperation } from "../utils/config";
import { set_env_var, foundry_wrapper } from "../foundry";
import { checkArgs } from "../utils/helper";
import { setupDeployJson } from "../utils/setupDeployJson";
import {ethers} from "ethers";
// current file name
const method_name = "CallRandomFunction";


function genRawTxCalldata(func: string, args: string) {
    // split args by comma if it contains ,
    const argsArray = args.includes(",") ? args.split(",") : [args];
     // func is like "set(uint256,uint256)"
    // and generate the calldata
    const iface = new ethers.Interface(["function " + func]);
    const calldata = iface.encodeFunctionData(func, argsArray);
    return calldata;
}

export function CallRandomFunctionWithArgv(argv: any) {
    const required_flags = ["network", "address","func", "args", "value"];
    checkArgs(method_name, argv, required_flags);
    CallRandomFunction(argv.network, argv.address, argv.func, argv.args, argv.value, argv.broadcast, argv.simulate);
}

export function CallRandomFunction(network: string, address: string, func: string, args: string, value: number, broadcast: boolean, simulate: boolean) {
    const calldata = genRawTxCalldata(func, args);
    console.log("address: ", address);
    console.log("calldata: ", calldata);

    const ethValue = ethers.parseEther(value.toString());

    set_env_var(method_name, "network", network);
    set_env_var(method_name, "address", address);
    set_env_var(method_name, "calldata", calldata);
    set_env_var(method_name, "value", ethValue.toString());
    foundry_wrapper(method_name, broadcast, simulate);

}

addOperation(method_name, CallRandomFunctionWithArgv);
