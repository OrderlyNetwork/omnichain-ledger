// import ethers from 'ethers';
import { ethers } from 'ethers';

export function printErrorsSig(abiPath: string) {
    // load json file
    const fs = require('fs');
    const json = JSON.parse(fs.readFileSync(abiPath, 'utf8'));

    const abi = json["abi"];
    // print errors signature: bytes4(Keccak256("Error(string)"))
    const iface = new ethers.Interface(abi);
    iface.forEachError((error) => {
        console.log(`Error name: ${error.name} selector: ${error.selector}`);
    })

}