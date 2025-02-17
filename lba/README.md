# Vertex LBA

Vertex LBA contracts.

## Dependencies

- node >=16
- [yarn](https://www.npmjs.com/package/yarn)

## Quickstart

1. Install yarn dependencies: `yarn install`.
3. Copy `.env.example` to `.env` - modify as necessary

## Common Commands

Common commands can be found in the `package.json` file, and runnable with `yarn <COMMAND_NAME>`. For
example: `yarn contracts:compile`.

`lint`: Runs prettier & SolHint

`contracts:force-compile`: Compiles contracts and generates TS bindings + ABIs

`run-local-node`: Runs a persistent local [Hardhat node](https://hardhat.org/hardhat-network) for local testing
