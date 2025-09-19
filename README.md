# ZStakingV3System
ZStaking V3 is the modernest staking system updated
# ZStaking V3 – Pool Factory Guide  

## 🚀 Pool Creation Process  
1. **Fill in the form** on the website with parameters:  
   - **Staking Token**  
   - **Reward Token**  
   - **Lock Duration**  
   - **Constant k** (for ZPR formula)  
   - **Activation Fee (Bonding Curve)**  

2. **Submit the form** → backend receives and validates the data.  

3. **Backend (owner)** calls the **Factory** contract to deploy a pool clone using the provided parameters.  
   ⏱ Processing time: **≤ 24h**.  

---

## 🔑 Pool Activation  
- Once the pool is deployed → frontend shows an **Activate Pool** option for the Pool Maker who registered it.  
- Pool Maker deposits the **Activation Fee (Bonding Curve)** to activate the pool.  
- On activation:  
  - The fee is split into **Bond + Reward + Treasury**.  
  - ZPR starts being calculated according to the defined formula.  

---

## 💻 Frontend Display  
- After activation, frontend displays:  
  - **Pool Maker Address**  
  - **ZPR %**  
  - Actions: **Stake / Unstake**  

👉 If there are **no unlocked tokens**, the **Unlock** button will **not be displayed**.  

---

## 📌 Best Practices for Pool Maker  

### Lock Duration  
- **Short (7–30 days):** attractive for new users, lower risk.  
- **Long (90–365 days):** locks capital longer, increases trust and pool value.  

### Activation Fee (Bonding Curve)  
- **High fee** → more tokens locked in contract → pool has **higher value**.  
- **Low fee** → easier to create, but lower pool value and potentially lower ZPR%.  
- ⚖️ Tip: choose a fee aligned with your community size and desired capital.  

### Constant k  
- **Smaller k** → ZPR % grows faster, more volatile.  
- **Larger k** → ZPR stabilizes, better for long-term pools.  

### Reward Token  
- If **Reward = Staking Token** → can enable **Auto-Compound** for faster growth.  
- If **Reward ≠ Staking Token** → ensure the reward token has liquidity and is easy to claim.  

---

## ✅ Summary  
- Pool Maker only needs to **fill in the form** → backend handles deployment → Factory creates the clone.  
- After **pool activation**, system displays Pool info + ZPR% for users to participate.  
- **Bonding Curve Fee** is the key factor that determines pool value and ZPR.  
