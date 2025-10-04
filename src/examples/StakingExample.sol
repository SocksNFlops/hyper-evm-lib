// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {CoreWriterLib, HLConstants, HLConversions} from "@hyper-evm-lib/src/CoreWriterLib.sol";
/**
 * @title StakingExample
 * @dev This contract demonstrates CoreWriterLib staking functionality.
 */

contract StakingExample {
    using CoreWriterLib for *;

    error NoHypeBalance();

    /**
     * @notice Transfers HYPE tokens to core, stakes them, and delegates to a validator
     */
    function bridgeHypeAndStake(uint256 evmAmount, address validator) external payable {
        // Transfer HYPE tokens to core
        uint64 hypeTokenIndex = HLConstants.hypeTokenIndex();
        hypeTokenIndex.bridgeToCore(evmAmount);

        // Using data from the `TokenInfo` precompile, convert EVM amount to core decimals for staking operations
        uint64 coreAmount = HLConversions.evmToWei(hypeTokenIndex, evmAmount);

        // Transfer tokens to staking account
        CoreWriterLib.depositStake(coreAmount);

        // Delegate the tokens to a validator
        CoreWriterLib.delegateToken(validator, coreAmount, false);
    }

    /**
     * @notice Undelegates tokens from a validator
     */
    function undelegateTokens(address validator, uint64 coreAmount) external {
        // Undelegate tokens by setting the bool `undelegate` parameter to true
        CoreWriterLib.delegateToken(validator, coreAmount, true);
    }

    /**
     * @notice Undelegates tokens from a validator and withdraws them to the spot balance
     */
    function undelegateAndWithdrawStake(address validator, uint64 coreAmount) external {
        // Undelegate tokens from the validator
        CoreWriterLib.delegateToken(validator, coreAmount, true);

        // Withdraw the tokens from staking
        CoreWriterLib.withdrawStake(coreAmount);
    }

    /**
     * @notice Withdraws tokens from the staking balance
     */
    function withdrawStake(uint64 coreAmount) external {
        // Withdraw the tokens from the staking balance
        CoreWriterLib.withdrawStake(coreAmount);
    }

    /**
     * @notice Transfers all HYPE balance to the sender
     */
    function transferAllHypeToSender() external {
        uint256 balance = address(this).balance;
        if (balance == 0) revert NoHypeBalance();
        payable(msg.sender).transfer(balance);
    }

    receive() external payable {}
}
