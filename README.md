# memewars

A Solidity smart contract for meme-based gaming on the blockchain.

## Overview

memewars is a smart contract that implements a meme-based battle system where players can engage in strategic gameplay using meme tokens.

## Getting Started

### Prerequisites

- Node.js (v14 or higher)
- npm or yarn
- Hardhat or Truffle for deployment
- MetaMask or compatible Web3 wallet

### Installation

1. Clone the repository:
   ```bash
   git clone https://github.com/memesteroidfun/memewars.git
   cd memewars
   ```

2. Install dependencies:
   ```bash
   npm install
   ```

### Deployment

1. Configure your network settings in `hardhat.config.js`
2. Deploy the contract:
   ```bash
   npx hardhat run scripts/deploy.js --network <your-network>
   ```

### Usage

1. Connect your Web3 wallet to the deployed contract
2. Interact with the contract functions through a dApp frontend or directly via Web3
3. Participate in meme battles and earn rewards

## Contract Features

- Meme token management
- Battle system implementation
- Reward distribution
- Player statistics tracking

## MUSD Token

The project includes a MUSD (Meme USD) token contract that serves as a faucet for testing and gameplay.

### MUSD Features

- **Token Name**: Meme USD (MUSD)
- **Faucet System**: Users can claim 1000 MUSD tokens every 4 hours
- **Cooldown Period**: 4-hour waiting period between claims
- **ERC20 Standard**: Fully compatible with ERC20 token standard

### MUSD Functions

- `claim()`: Claim 1000 MUSD tokens (4-hour cooldown)
- `timeUntilNextClaim(address)`: Check remaining cooldown time
- `canClaim(address)`: Check if user can claim tokens
- `lastClaim(address)`: View last claim timestamp for a user

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Submit a pull request

## License

This project is licensed under the MIT License.

## Support

For questions or support, please open an issue on GitHub.