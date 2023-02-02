//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract ERC20Mock is ERC20 {
    constructor(uint256 initialSupply) ERC20("ERC20 Mock Token", "ERC20MT") {
        _mint(msg.sender, initialSupply);
    }

    function mint(address to, uint amount) public {
        _mint(to,amount);
    }
}
