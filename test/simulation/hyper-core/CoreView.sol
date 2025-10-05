// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {DoubleEndedQueue} from "@openzeppelin/contracts/utils/structs/DoubleEndedQueue.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {PrecompileLib} from "../../../src/PrecompileLib.sol";
import {RealL1Read} from "../../utils/RealL1Read.sol";
import {CoreState} from "./CoreState.sol";

/// Modified from https://github.com/ambitlabsxyz/hypercore
contract CoreView is CoreState {
    using EnumerableSet for EnumerableSet.AddressSet;
    using DoubleEndedQueue for DoubleEndedQueue.Bytes32Deque;
    using EnumerableSet for EnumerableSet.UintSet;

    using SafeCast for uint256;

    function tokenExists(uint32 token) public view returns (bool) {
        return bytes(_tokens[token].name).length > 0;
    }

    function readMarkPx(uint32 perp) public returns (uint64) {
        if (_perpMarkPrice[perp] == 0) {
            return RealL1Read.markPx(perp);
        }

        return _perpMarkPrice[perp];
    }

    function readSpotPx(uint32 spotMarketId) public view returns (uint64) {
        if (_spotPrice[spotMarketId] == 0) {
            return PrecompileLib.spotPx(spotMarketId);
        }

        return _spotPrice[spotMarketId];
    }

    function readSpotBalance(address account, uint64 token) public returns (PrecompileLib.SpotBalance memory) {
        if (_initializedSpotBalance[account][token] == false) {
            return RealL1Read.spotBalance(account, token);
        }

        return PrecompileLib.SpotBalance({total: _accounts[account].spot[token], entryNtl: 0, hold: 0});
    }

    // Even if the HyperCore account is not created, the precompile returns 0 (it does not revert)
    function readWithdrawable(address account) public returns (PrecompileLib.Withdrawable memory) {
        if (_accounts[account].activated == false) {
            return RealL1Read.withdrawable(account);
        }

        return _previewWithdrawable(account);
    }

    function readUserVaultEquity(address user, address vault)
        public
        view
        returns (PrecompileLib.UserVaultEquity memory)
    {
        PrecompileLib.UserVaultEquity memory equity = _accounts[user].vaultEquity[vault];

        uint256 multiplier = _vaultMultiplier[vault] == 0 ? 1e18 : _vaultMultiplier[vault];
        uint256 lastMultiplier = _userVaultMultiplier[user][vault] == 0 ? 1e18 : _userVaultMultiplier[user][vault];
        if (multiplier != 0) equity.equity = uint64((uint256(equity.equity) * multiplier) / lastMultiplier);
        return equity;
    }

    function _getDelegationAmount(address user, address validator) internal view returns (uint64) {
        uint256 multiplier = _stakingYieldIndex;
        uint256 userLastMultiplier = _userStakingYieldIndex[user][validator] == 0 ? 1e18 : _userStakingYieldIndex[user][validator];

        return SafeCast.toUint64(uint256(_accounts[user].delegations[validator].amount) * multiplier / userLastMultiplier);
    }

    function readDelegations(address user) public returns (PrecompileLib.Delegation[] memory userDelegations) {

        if (_accounts[user].activated == false) {
            return RealL1Read.delegations(user);
        }

        address[] memory validators = _accounts[user].delegatedValidators.values();

        userDelegations = new PrecompileLib.Delegation[](validators.length);
        for (uint256 i; i < userDelegations.length; i++) {
            userDelegations[i].validator = validators[i];
            userDelegations[i].amount = _getDelegationAmount(user, validators[i]);
            userDelegations[i].lockedUntilTimestamp = _accounts[user].delegations[validators[i]].lockedUntilTimestamp;
        }
    }

    function readDelegatorSummary(address user) public returns (PrecompileLib.DelegatorSummary memory summary) {

        if (_accounts[user].activated == false) {
            return RealL1Read.delegatorSummary(user);
        }

        address[] memory validators = _accounts[user].delegatedValidators.values();

        for (uint256 i; i < validators.length; i++) {
            summary.delegated += _getDelegationAmount(user, validators[i]);
        }
        summary.undelegated = _accounts[user].staking;

        for (uint256 i; i < _withdrawQueue.length(); i++) {
            WithdrawRequest memory request = deserializeWithdrawRequest(_withdrawQueue.at(i));
            if (request.account == user) {
                summary.nPendingWithdrawals++;
                summary.totalPendingWithdrawal += request.amount;
            }
        }
    }

    function readPosition(address user, uint16 perp) public returns (PrecompileLib.Position memory) {
        if (_accounts[user].activated == false) {
            return RealL1Read.position(user, perp);
        }

        return _accounts[user].positions[perp];
    }

    function coreUserExists(address account) public returns (bool) {
        if (_accounts[account].activated == false) {
            return RealL1Read.coreUserExists(account).exists;
        }

        return _accounts[account].activated;
    }

    function readAccountMarginSummary(uint16 perp_dex_index, address user)
        public
        returns (PrecompileLib.AccountMarginSummary memory)
    {
        // 1. maintain an enumerable set for the perps that a user is in
        // 2. iterate over their positions and calculate position value, add them up (value = abs(sz * markPx))
        return _previewAccountMarginSummary(user);
    }

    function _previewAccountMarginSummary(address sender)
        internal
        returns (PrecompileLib.AccountMarginSummary memory)
    {
        uint64 totalNtlPos = 0;
        uint64 totalMarginUsed = 0;

        uint64 entryNtlByLeverage = 0;

        uint64 totalLongNtlPos = 0;
        uint64 totalShortNtlPos = 0;

        for (uint256 i = 0; i < _userPerpPositions[sender].length(); i++) {
            uint16 perpIndex = uint16(_userPerpPositions[sender].at(i));

            PrecompileLib.Position memory position = _accounts[sender].positions[perpIndex];

            uint32 leverage = position.leverage;
            uint64 markPx = readMarkPx(perpIndex);

            entryNtlByLeverage += position.entryNtl / leverage;

            int64 szi = position.szi;

            if (szi > 0) {
                uint64 ntlPos = uint64(szi) * markPx;
                totalNtlPos += ntlPos;
                totalMarginUsed += ntlPos / leverage;

                totalLongNtlPos += ntlPos;
            } else if (szi < 0) {
                uint64 ntlPos = uint64(-szi) * markPx;
                totalNtlPos += ntlPos;
                totalMarginUsed += ntlPos / leverage;

                totalShortNtlPos += ntlPos;
            }
        }

        int64 totalAccountValue = int64(_accounts[sender].perpBalance - entryNtlByLeverage + totalMarginUsed);
        int64 totalRawUsd = totalAccountValue - int64(totalLongNtlPos) + int64(totalShortNtlPos);

        return PrecompileLib.AccountMarginSummary({
            accountValue: totalAccountValue,
            marginUsed: totalMarginUsed,
            ntlPos: totalNtlPos,
            rawUsd: totalRawUsd
        });
    }

    function _previewWithdrawable(address account) internal returns (PrecompileLib.Withdrawable memory) {
        PrecompileLib.AccountMarginSummary memory summary = _previewAccountMarginSummary(account);

        uint64 transferMarginRequirement = 0;

        for (uint256 i = 0; i < _userPerpPositions[account].length(); i++) {
            uint16 perpIndex = uint16(_userPerpPositions[account].at(i));
            PrecompileLib.Position memory position = _accounts[account].positions[perpIndex];
            uint64 markPx = readMarkPx(perpIndex);

            uint64 ntlPos = 0;

            if (position.szi > 0) {
                ntlPos = uint64(position.szi) * markPx;
            } else if (position.szi < 0) {
                ntlPos = uint64(-position.szi) * markPx;
            }

            uint64 initialMargin = position.entryNtl / position.leverage;

            transferMarginRequirement += max(ntlPos / 10, initialMargin);
        }

        int64 withdrawable = summary.accountValue - int64(transferMarginRequirement);

        uint64 withdrawableAmount = withdrawable > 0 ? uint64(withdrawable) : 0;

        return PrecompileLib.Withdrawable({withdrawable: withdrawableAmount});
    }

    function max(uint64 a, uint64 b) internal pure returns (uint64) {
        return a > b ? a : b;
    }
}
