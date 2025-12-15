// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Ownable} from "solady/auth/Ownable.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

abstract contract BaseGuidestarHook is Ownable {
    IPoolManager public immutable poolManager;
    address public immutable gateway;

    error NotGateway();

    constructor(IPoolManager _poolManager, address _initialOwner, address _gateway) {
        _initializeOwner(_initialOwner);
        gateway = _gateway;
        poolManager = _poolManager;
    }

    modifier onlyByGateway() {
        if (msg.sender != address(gateway)) {
            revert NotGateway();
        }
        _;
    }
}
