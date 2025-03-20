# Vertex Protocol

This repository contains the smart contract implementations for the Vertex Protocol ecosystem.

## Project Structure

The repository is organized into two main projects:

- **[vertex-contracts/core](./core)**: EVM implementation of Vertex core functionality
- **[vertex-contracts/lba](./lba)**: Vertex LBA (Liquidity Bootstrap Auction) contracts

## Requirements

- Node.js >=16
- [Yarn](https://yarnpkg.com/)

## Getting Started

Each project has its own setup and development commands. Navigate to the respective directories for project-specific instructions:

```
# For Vertex EVM Core Contracts
cd vertex-contracts/core
yarn install
yarn compile

# For Vertex LBA Contracts
cd vertex-contracts/lba
yarn install
# Follow the .env setup instructions
```

## Available Commands

### Core Contracts

- `yarn compile`: Compile Vertex EVM contracts
- See project-specific README for more details

### LBA Contracts

- `yarn lint`: Run prettier & SolHint
- `yarn contracts:force-compile`: Compile contracts and generate TS bindings + ABIs
- `yarn run-local-node`: Run a persistent local Hardhat node for testing
- See project-specific README for more details

## Further Documentation

For more detailed information about each project, please refer to their respective README files.