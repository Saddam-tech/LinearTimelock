// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

contract LinearTimelock {
    // boolean to prevent reentrancy
    bool internal locked;

    // Library usage
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    // Contract owner
    address payable public owner;

    // Contract owner access
    bool public allIncomingDepositsFinalised;

    // Timestamp related variables
    // The epoch in seconds "as at" the time when the smart contract is initialized (via the setTimestamp function) by the owner
    uint256 public initialTimestamp;
    // A boolean to acknowledge when the one-time setTimestamp function has been called
    bool public timestampSet;
    // The epoch, in seconds, representing the period of time from the initialTimestamp to the moment tokens begin to be released linearly i.e. 3 months
    uint256 public cliffEdge;
    // The epoch, in seconds, representing the period of time from the initialTimestamp to the moment all funds are fully released i.e. 18 months
    uint256 public releaseEdge;
    // Last time a recipient accessed the unlock function
    // mapping(address => uint256) public mostRecentUnlockTimestamp;

    // Token amount variables
    mapping(address => uint256) public alreadyWithdrawn;
    mapping(address => uint256) public balances;
    uint256 public contractBalance;

    // // ERC20 contract address
    // IERC20 public erc20Contract;

    // Events
    event Transfer(address from, address to, uint256 amount);
    event AllocationPerformed(address recipient, uint256 amount);

    constructor() {
        // Allow this contract's owner to make deposits by setting allIncomingDepositsFinalised to false
        allIncomingDepositsFinalised = false;
        // Set contract owner
        owner = payable(msg.sender);
        // Timestamp values not set yet
        timestampSet = false;
        // Set the erc20 contract address which this timelock is deliberately paired to
        // require(
        //     address(_erc20_contract_address) != address(0),
        //     "_erc20_contract_address address can not be zero"
        // );
        // require(
        //     address(msg.sender) !=
        //         address(0xC2CE2b63e35Fbe60Cc86370b177650B3800F7221),
        //     "owner address can not be 0xC2C...F7221"
        // );
        // Initialize the reentrancy variable to not locked
        locked = false;
    }

    // Modifier
    /**
     * @dev Prevents reentrancy
     */
    modifier noReentrant() {
        require(!locked, "No re-entrancy");
        locked = true;
        _;
        locked = false;
    }

    // Modifier
    /**
     * @dev Throws if allIncomingDepositsFinalised is true.
     */
    modifier incomingDepositsStillAllowed() {
        require(
            allIncomingDepositsFinalised == false,
            "Incoming deposits have been finalised."
        );
        _;
    }

    // Modifier
    /**
     * @dev Throws if called by any account other than the owner.
     */
    modifier onlyOwner() {
        require(
            msg.sender == owner,
            "Message sender must be the contract's owner."
        );
        _;
    }

    // Modifier
    /**
     * @dev Throws if timestamp already set.
     */
    modifier timestampNotSet() {
        require(timestampSet == false, "The time stamp has already been set.");
        _;
    }

    // Modifier
    /**
     * @dev Throws if timestamp not set.
     */
    modifier timestampIsSet() {
        require(
            timestampSet == true,
            "Please set the time stamp first, then try again."
        );
        _;
    }

    receive() external payable incomingDepositsStillAllowed {
        contractBalance = contractBalance.add(msg.value);
        emit Transfer(msg.sender, address(this), msg.value);
    }

    function depositWL() external payable incomingDepositsStillAllowed {
        contractBalance = contractBalance.add(msg.value);
        emit Transfer(msg.sender, address(this), msg.value);
    }

    // @dev Takes away any ability (for the contract owner) to assign any coin amount to any recipients. This function is only to be called by the contract owner. Calling this function can not be undone. Calling this function must only be performed when all of the addresses and amounts are allocated (to the recipients). This function finalizes the contract owners involvement and at this point the contract's timelock functionality is non-custodial
    function finalizeAllIncomingDeposits()
        public
        onlyOwner
        timestampIsSet
        incomingDepositsStillAllowed
    {
        allIncomingDepositsFinalised = true;
    }

    /// @dev Sets the initial timestamp and calculates locking period variables i.e. twelveMonths etc.
    /// @param _cliffTimePeriod amount of seconds to add to the initial timestamp i.e. we are essentially creating the end of the lockup period here (which marks the start of the linear release logic)
    /// @param _releaseTimePeriod amount of seconds to add to the initial timestamp i.e. we are essemtially creating the point in time where gradual linear unlocking process is complete and all tokens are all simply available
    function setTimestamp(
        int _cliffTimePeriod,
        int _releaseTimePeriod
    ) public onlyOwner timestampNotSet {
        // Ensure that time periods are greater then zero
        require(
            _cliffTimePeriod != 0 && _releaseTimePeriod != 0,
            "Time periods can not be zero"
        );
        // Set timestamp boolean to true so that this function can not be called again (and so that token transfer and unlock functions can be called from now on)
        timestampSet = true;
        // Set initial timestamp to the current time
        initialTimestamp = block.timestamp;
        // Add the current time to the cliff time period to create the cliffEdge (The moment when tokens can start to unlock)
        if (_cliffTimePeriod > 0) {
            cliffEdge = initialTimestamp.add(uint256(_cliffTimePeriod));
        } else {
            cliffEdge = initialTimestamp.sub(uint256(-_cliffTimePeriod));
        }
        // Add the current time to the release time period to create the releaseEdge (The final moment when all tokens are free/unlocked)
        if (_releaseTimePeriod > 0) {
            releaseEdge = initialTimestamp.add(uint256(_releaseTimePeriod));
        } else {
            releaseEdge = initialTimestamp.sub(uint256(-_releaseTimePeriod));
        }
        // Tokens are released between cliffEdge and releaseEdge epochs; therefore the cliffEdge must always be older then the releaseEdge
        require(cliffEdge < releaseEdge);
    }

    /// @dev Function to withdraw Eth in case Eth is accidently sent to this contract.
    /// @param amount of network tokens to withdraw (in wei).
    function withdrawEth(
        uint256 amount
    ) public onlyOwner noReentrant incomingDepositsStillAllowed {
        require(amount <= contractBalance, "Insufficient funds");
        contractBalance = contractBalance.sub(amount);
        // Transfer the specified amount of Eth to the owner of this contract
        owner.transfer(amount);
        emit Transfer(address(this), owner, amount);
    }

    /// @dev Allows the contract owner to allocate official ERC20 tokens to each future recipient (only one at a time).
    /// @param recipient, address of recipient.
    /// @param amount to allocate to recipient.
    function depositTokens(
        address recipient,
        uint256 amount
    ) public onlyOwner timestampIsSet incomingDepositsStillAllowed {
        // The amount deposited must be greater than the netReleasePeriod or the wei per second will be less than one wei (which is not acceptable)
        require(
            amount >= (releaseEdge.sub(cliffEdge)),
            "Amount deposited must be greater than netReleasePeriod"
        );
        require(recipient != address(0), "Transfer to the zero address");
        balances[recipient] = balances[recipient].add(amount);
        // mostRecentUnlockTimestamp[recipient] = cliffEdge;
        emit AllocationPerformed(recipient, amount);
    }

    /// @dev Allows the contract owner to allocate official ERC20 tokens to multiple future recipient in bulk.
    /// @param recipients, an array of addresses of the many recipient.
    /// @param amounts to allocate to each of the many recipient.
    function bulkDepositTokens(
        address[] calldata recipients,
        uint256[] calldata amounts
    ) external onlyOwner timestampIsSet incomingDepositsStillAllowed {
        require(
            recipients.length == amounts.length,
            "The recipients and amounts arrays must be the same size in length"
        );
        for (uint256 i = 0; i < recipients.length; i++) {
            require(
                recipients[i] != address(0),
                "Transfer to the zero address"
            );
            // The amount deposited must be greater than the netReleasePeriod or the wei per second will be negative i.e. minimum wei per secon is 1
            require(
                amounts[i] >= (releaseEdge.sub(cliffEdge)),
                "Amount deposited must be greater than netReleasePeriod"
            );
            balances[recipients[i]] = balances[recipients[i]].add(amounts[i]);
            // mostRecentUnlockTimestamp[recipients[i]] = cliffEdge;
            emit AllocationPerformed(recipients[i], amounts[i]);
        }
    }

    /// @dev Calculates the weiPerSecond value for a specific user
    /// @param _to the address to calculate the wei per second for
    /// @return uint256
    /*
    function calculateWeiPerSecond(address _to) internal view returns(uint256) {
            // Calculate the linear portion of tokens which are made available for each one second time increment
            return (balances[_to].add(alreadyWithdrawn[_to])).div((releaseEdge.sub(cliffEdge)));
    }
    */

    /// @dev Allows recipient to start linearly unlocking eth (after cliffEdge has elapsed) or unlock up to entire balance (after releaseEdge has elapsed)
    /// @param to - the recipient's account address.
    /// @param amount - the amount to unlock (in wei)
    function transferTimeLockedTokensAfterTimePeriod(
        address to,
        uint256 amount
    ) public timestampIsSet noReentrant {
        require(to != address(0), "Transfer to the zero address");
        require(
            balances[to] >= amount,
            "Insufficient WL balance, try lesser amount"
        );
        require(
            msg.sender == to,
            "Only the WL recipient can perform the unlock"
        );
        require(
            block.timestamp > cliffEdge,
            "WL is only available after correct time period has elapsed"
        );
        // Ensure that the amount is available to be unlocked at this current point in time
        if (block.timestamp > releaseEdge) {
            alreadyWithdrawn[to] = alreadyWithdrawn[to].add(amount);
            balances[to] = balances[to].sub(amount);
            // mostRecentUnlockTimestamp[to] = block.timestamp;
            // token.safeTransfer(to, amount);
            // modified to send WL
            payable(to).transfer(amount);
            contractBalance = contractBalance.sub(amount);
            emit Transfer(address(this), to, amount);
        } else {
            // require(amount <= calculateWeiPerSecond(to).mul((block.timestamp.sub(mostRecentUnlockTimestamp[to]))), "Token amount not available for unlock right now, please try lesser amount.");

            uint256 total = alreadyWithdrawn[to].add(balances[to]);
            uint256 vested = total.mul(block.timestamp.sub(cliffEdge)).div(
                releaseEdge.sub(cliffEdge)
            );
            uint256 avail = vested - alreadyWithdrawn[to];
            require(
                amount <= avail,
                "WL amount not available for unlock right now, please try lesser amount."
            );

            alreadyWithdrawn[to] = alreadyWithdrawn[to].add(amount);
            balances[to] = balances[to].sub(amount);
            // mostRecentUnlockTimestamp[to] = block.timestamp;
            // token.safeTransfer(to, amount);
            // modified to send WL
            payable(to).transfer(amount);
            contractBalance = contractBalance.sub(amount);
            emit Transfer(address(this), to, amount);
        }
    }

    /// @dev Transfer accidentally locked ERC20 tokens.
    /// @param token - ERC20 token address.
    /// @param amount of ERC20 tokens to remove.
    function transferAccidentallyLockedTokens(
        IERC20 token,
        uint256 amount
    ) public onlyOwner noReentrant {
        require(address(token) != address(0), "Token address can not be zero");
        // This function can not access the official timelocked tokens; just other random ERC20 tokens that may have been accidently sent here
        // require(
        //     token != erc20Contract,
        //     "Token address can not be ERC20 address which was passed into the constructor"
        // );
        // Transfer the amount of the specified ERC20 tokens, to the owner of this contract
        token.safeTransfer(owner, amount);
        emit Transfer(address(this), owner, amount);
    }
}
