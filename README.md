# **Dynamic Auction-Based JIT Rebalancer Hook**  

**License**: MIT  
**Version**: v1.0  
**Tests**: ✅ [Passing](#test-cases)  
---

## **Overview**  
The **Dynamic Auction-Based JIT Rebalancer Hook** is a Uniswap v4 hook designed to optimize large swaps by allowing liquidity providers (LPs) to bid on liquidity provision rights in real time. This ensures minimal slippage, reduced MEV extraction, and improved capital efficiency—all while maintaining atomic transaction execution.  

Built as an improvement over traditional JIT liquidity models, this hook eliminates fragmentation, supports complex multi-hop swaps, and dynamically rebalances liquidity post-swap to avoid impermanent loss.  

---


## **Motivation**

I participated in the UH1-C2 hookathon with my team where we built a JIT Rebalancer hook [JIT Rebalancer Hook](https://github.com/PaulElisha/JIT-UNISWAP-V4-HOOK) but I noticed it comes with some flaws which includes:

1. The need to manage the deployments of multiple liquidity manager contract doesn't make it sustainable. 

It kind of creates a seperate pool for LPs that want to provide liquidity for large swaps thus fragmenting liquidity.

2. It computes the next price of a swap without factoring if the swap is a complex swap like a multi-hop large swap.

It only works for a simple swap.

3. It assumes the LP wants to provide a single-sided liquidity by computing only the amount of a token to add.

It computes liquidityDelta based on the amount of a token in the pool.

4. It gives infinite approval of both tokens in the liquidity manager pool which is risky approach.

---

## Solution

1. Uniswap V3 and V4 boosts of capital efficiency for LPs but capital is not fully efficient if they are not where they are most needed. This Hook dynamically adjust liquidity around large swaps.

2. Prevents MEV front-running by ensuring atomic or same block transactions.

3. Market makers are not fully automated without a dynamic liquidity management or rebalancer. It enables market making on demand by placing liquidity in areas of high surge without manual control from LPs.

4. Adjusting liquidity positions for all kinds of simple and complex swaps while enabling passive yield for LPs.

5. It does not require a separate liquidity manager contract. It fosters the utility of stale liquidity that could cause impermanent loss.

---

## Mechanism

1. This contract manages pools by their `key` and `Id`. 

It stores Pool parameters after liquidity provision and checks if the `Id` provided for swap is in the mapping to ensure it utilizes the liquidity bidded.

This removes the management of multiple liquidity manager contracts and leverages the singleton approach.

2. It uses `TrySwap` in the libraries to simulate swap regardless of the complexity even if it's a cross-tick swap. And hooks in a `swapStepHook` function to ensure that re-allocation of liqudity is done in a single transaction. 

The `TrySwap` library interacts directly with Uniswap V4 contract so it's perfect to get the next price and factors in other parameters considered in the Uniswap V4.

3. It removes liquidity and adds liquidity in both tokens and ensures proper re-allocation of liqudity in an optimal price range.

---

## **Features**  

✅ **Auction-Based Liquidity**  
- LPs bid to pre-commit liquidity for large swaps, ensuring optimal pricing.  

✅ **Multi-Pool & Multi-Hop Swap Support**  
- Uses `TrySwap` library to simulate complex swaps (cross-tick, multi-pool) for accurate price adjustments.  

✅ **Atomic Liquidity Rebalancing**  
- Removes and re-adds liquidity in a single transaction, minimizing MEV and slippage.  

✅ **Singleton Pool Management**  
- No need for multiple liquidity manager contracts—pools are tracked by `PoolKey` and `PoolId`.  

✅ **Secure & Gas-Efficient**  
- No infinite token approvals; leverages Uniswap v4’s native security features.  

---

## **How It Works**  

### **1. LP Bidding Phase**  
- LPs call `addLiquidity()` to bid liquidity into a pool.  
- Bids are stored in an auction-style queue (`bids[poolId]`).  

### **2. Large Swap Detection**  
- The hook checks if a swap exceeds a liquidity threshold (e.g., >1% of pool reserves).  
- If triggered, it selects the best LP bid for the swap.  

### **3. Atomic Execution**  
- **Pre-Swap**: Removes the winning LP’s liquidity to reduce slippage.  
- **Swap**: Executes the trade using Uniswap v4’s core logic.  
- **Post-Swap**: Re-adds liquidity around the new price (`_getUsableTicks`).  

### **4. Settlement**  
- Winning LPs earn swap fees.  
- Traders benefit from near-optimal pricing.  

---

## **Why It’s Better**  

🔄 **Solves Fragmentation**  
- Unlike older JIT models, this hook **does not require separate liquidity manager contracts**, avoiding pool fragmentation.  

📉 **Handles Complex Swaps**  
- Simulates multi-hop swaps via `TrySwap` for accurate price adjustments.  

🔐 **No Risky Approvals**  
- Avoids infinite token approvals—uses Permit2-style security where applicable.  

⚡ **MEV-Resistant**  
- All steps (bid selection, swap, rebalance) happen atomically in one TX.  

---

## **Test Cases**  

```bash
Ran 3 tests for test/JITRebalancerHookTest.t.sol:JITRebalancerHookTest
[PASS] testAddLiquidity() (gas: 578392)
[PASS] testBeforeSwap() (gas: 1211477)
[PASS] testSwap() (gas: 1211090)
Suite result: ok. 3 passed; 0 failed; 0 skipped
```

---

## **Technical Stack**  
- **Uniswap v4 Hooks**: Custom logic via `beforeSwap`/`afterSwap`.  
- **Foundry**: For testing and deployment (see [Foundry Book](https://book.getfoundry.sh/)).  
- **Permit2**: Secure token approvals (future integration).  

---

## **Future Roadmap**  
- **NFT Position Delegation**: Represent LP positions as NFTs for auto-rebalancing. 
- **Deployment on Unichain**: Deploy the Uniswap V4 Hook on Unichain. 
<!-- 
- **Cross-Chain Expansion**: Extend to other AMMs (e.g., PancakeSwap).   -->
- **Institutional Tools**: Optimize for hedge funds and DAOs.  

---

## **Quick Start**  

### **Build**  
```bash
forge build
```

### **Test**  
```bash
forge test
```

### **Deploy**  
```bash
forge script script/Deploy.s.sol --rpc-url <RPC_URL> --private-key <PK>
```

---

## **Join the Discussion**  
- **Discord**: [Community Link](https://discord.gg/example)  
- **Twitter**: [@Example](https://twitter.com/example)  

---

**One-Liner**:  
*"A dynamic liquidity layer where LPs compete in real-time auctions, swaps execute with CEX-like efficiency, and MEV becomes obsolete."* 🚀