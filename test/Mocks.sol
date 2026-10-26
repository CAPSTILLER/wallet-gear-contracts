// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract Mock6 is ERC20 {
    constructor(string memory n) ERC20(n, n) {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 a) external { _mint(to, a); }
}

interface IDeskLike { function sellToHouse(uint256[] calldata) external; }

/// GEAR-like token with a transfer hook that tries to re-enter the desk.
contract HookToken is Mock6 {
    address public target; bool public reentered; bool public reentryReverted;
    constructor() Mock6("HOOK") {}
    function arm(address t) external { target = t; }
    function _update(address f, address t, uint256 v) internal override {
        super._update(f, t, v);
        if (target != address(0) && !reentered) {
            reentered = true;
            uint256[] memory ids = new uint256[](1);
            ids[0] = 1;
            try IDeskLike(target).sellToHouse(ids) { } catch { reentryReverted = true; }
        }
    }
}
