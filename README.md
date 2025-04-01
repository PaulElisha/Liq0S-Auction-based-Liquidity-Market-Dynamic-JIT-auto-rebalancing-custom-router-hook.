## Dynamic Auction-based JIT Rebalancer Hook

This is a JIT Rebalancer Hook that allows LPs to bid to pre-commit liquidity into a pool where a large swap could potentially occur. It happens dynamically as it manages all pools by various `Id` so that swap can only occur at a pool where liquidity has been pre-committed.

It takes the approach of the regular MEV bots but automated on-chain for profitable MEV strategy. So that slippage can be reduced and avoids impermanent loss by removing liquidity immediately after swap, there by, avoiding on-chain interactions.

## Why?

I participated in the UH1-C2 hookathon with my team where we built a JIT Rebalancer hook [JIT Rebalancer Hook](https://github.com/PaulElisha/JIT-UNISWAP-V4-HOOK) but I noticed it comes with some flaws which includes:

1. The need to manage the deployments of multiple liquidity manager contract doesn't make it sustainable. 

It kind of creates a seperate pool for LPs that want to provide liquidity for large swaps thus fragmenting liquidity.

2. It computes the next price of a swap without factoring if the swap is a complex swap like a multi-hop large swap.

It only works for a simple swap.

3. It assumes the LP wants to provide a single-sided liquidity by computing only the amount of a token to add.

It computes liquidityDelta based on the amount of a token in the pool.

4. It gives infinite approval of both tokens in the liquidity manager pool which is risky approach.

## Solution

1. This contract manages pools by their `key` and `Id`. 

It stores Pool parameters after liquidity provision and checks if the `Id` provided for swap is in the mapping to ensure it utilizes the liquidity bidded.

This removes the management of multiple liquidity manager contracts and leverages the singleton approach.

2. It uses `TrySwap` in the libraries to simulate swap regardless of the complexity even if it's a cross-tick swap. And hooks in a `swapStepHook` function to ensure that re-allocation of liqudity is done in a single transaction. 

The `TrySwap` library interacts directly with Uniswap V4 contract so it's perfect to get the next price and factors in other parameters considered in the Uniswap V4.

3. It removes liquidity and adds liquidity in both tokens and ensures proper re-allocation of liqudity.

## Mechanism

- Registers a LPs bid `afterAddLiquidity`.
- Checks if swap in a particular poolId has liqudity already pre-committed for it in the bids mapping.
- Simulates swap to get the accurate next price by interacting with the pool in simulation and adjust liqudity accordingly.
- Removes liqudity after swap to the bidder to avoid impermanent loss.

# Test Cases


Ran 3 tests for test/JITRebalancerHookTest.t.sol:JITRebalancerHookTest
[PASS] testAddLiquidity() (gas: 578392)
[PASS] testBeforeSwap() (gas: 1211477)
[PASS] testSwap() (gas: 1211090)
Suite result: ok. 3 passed; 0 failed; 0 skipped; finished in 2.58ms (3.09ms CPU time)

## Foundry

**Foundry is a blazing fast, portable and modular toolkit for Ethereum application development written in Rust.**

Foundry consists of:

-   **Forge**: Ethereum testing framework (like Truffle, Hardhat and DappTools).
-   **Cast**: Swiss army knife for interacting with EVM smart contracts, sending transactions and getting chain data.
-   **Anvil**: Local Ethereum node, akin to Ganache, Hardhat Network.
-   **Chisel**: Fast, utilitarian, and verbose solidity REPL.

## Documentation

https://book.getfoundry.sh/

## Usage

### Build

```shell
$ forge build
```

### Test

```shell
$ forge test
```

### Format

```shell
$ forge fmt
```

### Gas Snapshots

```shell
$ forge snapshot
```

### Anvil

```shell
$ anvil
```

### Deploy

```shell
$ forge script script/Counter.s.sol:CounterScript --rpc-url <your_rpc_url> --private-key <your_private_key>
```

### Cast

```shell
$ cast <subcommand>
```

### Help

```shell
$ forge --help
$ anvil --help
$ cast --help
```
