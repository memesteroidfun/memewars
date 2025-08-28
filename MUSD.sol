// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MUSD is ERC20 {
    uint256 public constant CLAIM_AMOUNT = 1000 * 10**18; // 1000 MUSD
    uint256 public constant COOLDOWN = 14400; // 4 hours in seconds

    mapping(address => uint256) public lastClaim;

    event FaucetClaimed(address indexed user, uint256 amount);

    constructor() ERC20("Meme USD", "MUSD") {}

    function claim() external {
        require(
            block.timestamp - lastClaim[msg.sender] >= COOLDOWN,
            "Faucet: Please wait 4 hours between claims"
        );

        lastClaim[msg.sender] = block.timestamp;
        _mint(msg.sender, CLAIM_AMOUNT);

        emit FaucetClaimed(msg.sender, CLAIM_AMOUNT);
    }

    function timeUntilNextClaim(address user) external view returns (uint256) {
        if (block.timestamp - lastClaim[user] >= COOLDOWN) {
            return 0;
        }
        return COOLDOWN - (block.timestamp - lastClaim[user]);
    }

    function canClaim(address user) external view returns (bool) {
        return (block.timestamp - lastClaim[user] >= COOLDOWN);
    }
}
