// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract Create2Deployer {
    function deploy(uint256 salt, bytes memory code) public returns (address) {
        return deploy(0, salt, code);
    }

    function deploy(uint256 value, uint256 salt, bytes memory code) public returns (address addr) {
        assembly {
            addr := create2(value, add(code, 0x20), mload(code), salt)
        }
    }
}

