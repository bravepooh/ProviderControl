// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract ProviderController {
    IERC20 token;

    struct Provider {
        uint256 fee; // fee is the cost in token units that the provider charges to subscribers per month
        uint256 balance; // the provider balance is stored in the contract
        address owner;
        uint32 subscriberCount;
        bool active;
    }

    struct Subscriber {
        address owner;
        bool paused;
        uint256 balance; // the subscriber balance is stored in the contract
        string plan; // basic / premium / vip
    }

    uint256 private constant MINIMUM_DEPOSIT = 1000;
    uint64 private constant MAX_NUMBER_PROVIDERS = 200;

    mapping(bytes => bool) registerKeys; // New mapping to track register keys
    
    address public manager;
    uint64 public providerId;
    uint64 public subscriberId;
    mapping(uint64 => Provider) providers;
    mapping(uint64 => Subscriber) subscribers;
    mapping(uint64 => uint64[]) providerSubscribers;
    mapping(uint64 => uint64[]) subscriberProviders;


    // Events
    event ProviderAdded(uint64 indexed providerId, address indexed owner, bytes publicKey, uint256 fee);
    event ProviderRemoved(uint64 indexed providerId);

    event SubscriberAdded(uint64 indexed subscriberId, address indexed owner, string plan, uint256 deposit);

    constructor(address _token) {
        token = IERC20(_token);
        manager = msg.sender;
    }

    function registerProvider(bytes calldata registerKey, uint256 fee) external returns (uint64 id) {
        // fee (token units) should be greater than a fixed value. Add a check
        require(fee > MINIMUM_DEPOSIT, "Fee must be greater than MINIMUM_DEPOSIT");
        
        // the system doesn't allow to register a provider with the same registerKey.
        require(!registerKeys[registerKey], "Provider's registerKey used"); // Check registerKey is unique
        registerKeys[registerKey] = true; // Store the registerKey

        // check MAX_NUMBER_PROVIDERS is not surpassed
        id = ++providerId;
        require(id <= MAX_NUMBER_PROVIDERS,"MAX_NUMBER_PROVIDERS limit");
        providers[id] = Provider({owner: msg.sender, balance: 0, subscriberCount: 0, fee: fee, active: true});

        emit ProviderAdded(id, msg.sender, registerKey, fee);
    }

    function removeProvider(uint64 _providerId) external {
        // Only the owner of the Provider can remove it
        require(providers[_providerId].owner == msg.sender, "Only owner-Provider allowed");

        // Transfer the balance if > 0
        uint256 currentBalance = providers[_providerId].balance;
        if (currentBalance > 0) {
            transferBalance(msg.sender, currentBalance);
        }

        // Update the subscribers that they no longer have this provider
        uint64[] memory subs = providerSubscribers[_providerId];
        for (uint i = 0; i < subs.length; i++) {
            uint64 subId = subs[i];
            removeProviderFromSubscriber(_providerId, subId);
        }

        // Deleting the provider struct
        delete providers[_providerId];
        delete providerSubscribers[_providerId];  // Ensure that provider's subscribers list is also cleared

        emit ProviderRemoved(_providerId);
    }

    function removeProviderFromSubscriber(uint64 _providerId, uint64 _subscriberId) private {
        uint64[] storage provs = subscriberProviders[_subscriberId];
        for (uint i = 0; i < provs.length; i++) {
            if (provs[i] == _providerId) {
                provs[i] = provs[provs.length - 1];
                provs.pop();
                break;
            }
        }
    }

    // private functions
    function withdrawProviderEarnings(uint64 _providerId) public {
        // only the owner of the provider can withdraw funds
        require(providers[_providerId].owner == msg.sender, "Only provider's owner allowed");

        // IMPORTANT: before withdrawing, the amount earned from subscribers needs to be calculated
        uint256 amount = calculateProviderEarnings(_providerId);
        providers[_providerId].balance += amount; // This is the total balance of provider withdrawn

        transferBalance(msg.sender, amount);
    }

    function updateProvidersState(uint64[] calldata providerIds, bool[] calldata isActive) external {
        // Implement the logic of this function
        // It will receive a list of provider Ids and a flag (enable /disable)
        // and update the providers state accordingly (active / inactive)
        // You can change data structures if that helps improve gas cost
        // Remember the limt of providers in the system is 200
        // Only the owner of the contract can call this function

        require(msg.sender == manager, "Only manager allowed");
        require(providerIds.length == isActive.length, "arrays size should be equal");
        require(providerIds.length <= MAX_NUMBER_PROVIDERS, "providerIds size exceeds");
        for (uint i = 0; i < providerIds.length; i++) {
            providers[providerIds[i]].active = isActive[i];
        }
    }

    function calculateProviderEarnings(uint64 _providerId) private view returns (uint256 earnings) {
        // Calculate the earnings for a given provider based on subscribers count and provider fee
        // The calculation is made on a full month basis.
        uint64[] memory subIds = providerSubscribers[_providerId];
        uint256 totalFee = providers[_providerId].fee;
        return totalFee * subIds.length; // Assuming one month of earnings
    }

    function transferBalance(address to, uint256 amount) private {
        token.transfer(to, amount);
    }
        
    function registerSubscriber(uint256 _deposit, string memory plan, uint64[] calldata providerIds) external {
        // Only allow subscriber registrations if providers are active
        // Provider list must at least 3 and less or equals 14
        // check if the deposit amount cover expenses of providers' fees for at least 2 months
        // plan does not affect the cost of the subscription

        require(providerIds.length >= 3 && providerIds.length <= 14, "3<=providersIds<=14");

        uint256 totalMonthlyCost = 0;

        for (uint i = 0; i < providerIds.length; i++) {
            require(providers[providerIds[i]].active, "Provider is inactive");
            providerSubscribers[providerIds[i]].push(subscriberId);
            totalMonthlyCost += providers[providerIds[i]].fee;
        }
        require(_deposit >= totalMonthlyCost * 2, "Deposit too low");

        uint64 id = ++subscriberId;

        subscribers[id] = Subscriber({owner: msg.sender, balance: _deposit, plan: plan, paused: false});

        // Linking the subscriber with his providers
        for (uint i = 0; i < providerIds.length;) {
            subscriberProviders[id].push(providerIds[i]);
            unchecked {
                i++;
            }
        }
        
        // deposit the funds
        token.transferFrom(msg.sender, address(this), _deposit);

        emit SubscriberAdded(id, msg.sender, plan, _deposit);
    }

    function pauseSubscription(uint64 _subscriberId) external {
        // Only the subscriber owner can pause the subscription
        // when the subscription is paused, it must be removed from providers list (providerSubscribers)
        // and for every provider, reduce subscriberCount
        // when pausing a subscription, the funds of the subscriber are not transferred back to the owner

        require(subscribers[_subscriberId].owner == msg.sender, "Only subscriber owner allowed");
        subscribers[_subscriberId].paused = true;
        uint64[] memory providerIds = subscriberProviders[_subscriberId]; // Array of providerIds per subscriber
        
        for (uint i = 0; i < providerIds.length; i++) {
            uint64 providerIdInt = providerIds[i];
            providers[providerIdInt].subscriberCount--;
            removeSubscriberFromProvider(providerIdInt, _subscriberId);
        }
    }

    function removeSubscriberFromProvider(uint64 _providerId, uint64 subscriberIdToRemove) private {
        uint64[] storage subs = providerSubscribers[_providerId];
        for (uint i = 0; i < subs.length; i++) {
            if (subs[i] == subscriberIdToRemove) {
                subs[i] = subs[subs.length - 1]; // Move the last element to the slot of the key to delete
                subs.pop(); // Remove the last element as it now has been moved to the index i
                break;
            }
        }
    }

    function deposit(uint64 _subscriberId, uint256 _deposit) external {
        // Only the subscriber owner can deposit to the subscription
        require(subscribers[_subscriberId].owner == msg.sender, "Only subscriber owner allowed");

        token.transferFrom(msg.sender, address(this), _deposit);
        subscribers[_subscriberId].balance += _deposit;
    }

// Read-only functions
    function getProviderState(uint64 _providerId) external view returns (
        uint32 subscriberCount, 
        uint256 fee, 
        address owner, 
        uint256 balance, 
        bool state
    ) {
        Provider memory provider = providers[_providerId];
        return (provider.subscriberCount, provider.fee, provider.owner, provider.balance, provider.active);
    }

    function getProviderEarnings(uint64 _providerId) external view returns (uint256) {
        return calculateProviderEarnings(_providerId);
    }

    function getSubscriberState(uint64 _subscriberId) external view returns (
        address owner, 
        uint256 balance, 
        string memory plan, 
        bool state
    ) {
        Subscriber memory subscriber = subscribers[_subscriberId];
        return (subscriber.owner, subscriber.balance, subscriber.plan, subscriber.paused);
    }

    function getLiveBalance(uint64 _subscriberId) external view returns (uint256) {
        uint256 totalFees = 0;
        uint64[] memory providerIds = subscriberProviders[_subscriberId];

        for (uint i = 0; i < providerIds.length; i++) {
            totalFees += providers[providerIds[i]].fee;
        }

        return subscribers[_subscriberId].balance - totalFees;
    }
}






  