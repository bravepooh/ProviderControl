# ProviderControl #
###################
+ ProviderControl.sol is the solution for the home assignment
+ VerA_ProviderControl.sol is based on ProviderControl.sol and updated with:
    ++ Enforcement of 30 days time lock for withdrawals
    ++ unchecked {} for loops index increment
+ VerAB_ProviderControl.sol is based on VerA_ProviderControl.sol and updated with:  
    ++ Two-way mapping for providerSubscribers and subscriberProviders to reduce gas cost of array lookups
    
# Subscriber pause/register issues:
+ There is no unPauseSubscription() function for the user the restart his subscription. So basically he can only re-register but then loose his funds
+ Another problem is that a subscriber can register more than once for the same providers, this can be solved by the code if needed.

# Bonus questions:
##################

# System Scalability:
#####################
1. Linked Lists:
change arrays
   mapping(uint64 => uint64[]) providerSubscribers;
   mapping(uint64 => uint64[]) subscriberProviders;
to linked list structures:
   mapping(uint64 => ProviderNode) providerSubscribers;
   mapping(uint64 => SubscriberNode) subscriberProviders;
   struct SubscriberNode {
     uint64 id; // Unique identifier for this provider
     Subscriber subscriberData; // The actual data of the subscriber
     uint64 next; // Next provider's id
     uint64 prev; // Previous provider's id }
Each item will point to next item, this way we can avoid the 200 array size limitation, but we will have more gas to pay.
Not the best solution

2. Proxy Diamond:
Change contract architecture to enable upgrades related to scalability in the future.
The contract can be break to smaller parts: providers contract, subscribers contract, earning contract...
It will enable creating a bigger storage area

3. manage storage per data size: 
main contract should store only the size of each list of subscribers and providers.
When a treshold is reached for the size of the list, a new contract will be created , for example: providersA, providersB,,,,,
Implementation: 
+ Create a providerStorageFactory contract
+ The main contract will count the number of providers (but without their data)
+ The main contract will call the providerStorageFactory when a treshold of 200 providers reached (The initial storage for providers will be created on first provider)
+ A new storage for providers data will be created
+ The main contract will have mapping between providerId and the respective providerStorage contract.
+ Since it creates non equal cost for a provider to be registered , the main contract should be added a functionallity to repay the provider the while registering a new storage contract is created.

4. L2 solution (reduce gas cost of computation and hence enable more data to be taken care)

5. move data and computation off chain, to reduce storage/cost

# Balance Management:
#####################

While Daily or Hourly Basis Payment can introduce more flexibility and accuracy for the subscribers
It has few challenges:
+ Increased Transaction Costs for subscribers
+ Liquidity Issues for Providers: short liquidity for service providers

possible implementation:
+ Total cost calculation based on period
     uint256 totalCost = (paymentPeriod == "daily") ? totalMonthlyCost/30 : (paymentPeriod == "hourly") ? totalMonthlyCost/720 : totalMonthlyCost * 2;
     require(_deposit >= totalCost, "Deposit too low");
+ Subscription end-date: Each subscription will have an end date, and each deposit will update the end date
+ new feature to enable auto renewal of subscription, balance and end date can be checked by an oracle
  and a new function will be responsible to fund again the contract (assuming allowance is big enough)

# Changing Provider Fees:
#########################
+ Better to create some billing cycle that starts for all providers at the same time, or per provider (lastWithdrawal var in VerA solution)
+ Update Provider struct with  nextFee and feeChangeDate
struct Provider {
        uint256 balance;
        uint256 fee;
        uint32 subscriberCount;
        address owner;
        bool active;
        uint256 nextFee;   // the new fee to be applied in the next billing cycle
        uint256 feeChangeDate;  // the date when the fee change will take effect
}
+ New function changeProviderFee:
function changeProviderFee(uint64 _providerId, uint256 newFee, uint256 effectiveDate) external {
    require(providers[_providerId].owner == msg.sender, "Only owner-Provider allowed");
    providers[_providerId].nextFee = newFee;
    providers[_providerId].feeChangeDate = effectiveDate;
}
+ Update function withdrawProviderEarnings and calculateProviderEarnings:
function withdrawProviderEarnings(uint64 _providerId) public {
    // only the owner of the provider can withdraw funds
    require(providers[_providerId].owner == msg.sender, "Only provider's owner allowed");

    uint256 amount = calculateProviderEarnings(_providerId);

    require(amount <= providers[_providerId].balance, "Insufficient funds");
    providers[_providerId].balance += amount; // This is the total balance of provider withdrawn

    transferBalance(msg.sender, amount);
}

function calculateProviderEarnings(uint64 _providerId) private view returns (uint256 earnings) {
    Provider memory provider = providers[_providerId];
    uint64[] memory subIds = providerSubscribers[_providerId];

    // If there's no scheduled fee change or it's in the future, use the current fee
    if (provider.feeChangeDate == 0 || provider.feeChangeDate > block.timestamp) {
        return provider.fee * subIds.length; // Assuming one month of earnings
    } else {
        // Calculate prorated earnings based on old fee and new fee for the given billing cycle
        uint256 daysBeforeChange = (provider.feeChangeDate - /* start of the billing cycle */) / 1 days;
        uint256 daysAfterChange = 30 - daysBeforeChange; // Assuming 30-day billing cycles

        uint256 earningsBeforeChange = daysBeforeChange * (provider.fee / 30);
        uint256 earningsAfterChange = daysAfterChange * (provider.nextFee / 30);

        return (earningsBeforeChange + earningsAfterChange) * subIds.length;
    }
}
