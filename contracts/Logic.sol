// Copyright (C) 2020 Zerion Inc. <https://zerion.io>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.
//
// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.6.8;
pragma experimental ABIEncoderV2;

import { Action, Output, ActionType, AmountType } from "./Structs.sol";
import { InteractiveAdapter } from "./interactiveAdapters/InteractiveAdapter.sol";
import { ProtocolAdapter } from "./adapters/ProtocolAdapter.sol";
import { ERC20 } from "./ERC20.sol";
import { SignatureVerifier } from "./SignatureVerifier.sol";
import { Ownable } from "./Ownable.sol";
import { AdapterRegistry } from "./AdapterRegistry.sol";
import { TokenSpender } from "./TokenSpender.sol";
import { SafeERC20 } from "./SafeERC20.sol";


/**
 * @title Main contract executing actions.
 * TODO: reentrancy lock
 * TODO: safe math
 */
contract Logic {
    using SafeERC20 for ERC20;

    address internal constant ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    AdapterRegistry public adapterRegistry;

    event ExecutedAction(uint256 index);

    constructor(
        address _adapterRegistry
    )
        public
    {
        adapterRegistry = AdapterRegistry(_adapterRegistry);
    }

    // solhint-disable-next-line no-empty-blocks
    receive() external payable {}

    /**
     * @notice Execute actions on `account`'s behalf.
     * @param actions Array with actions.
     * @param minReturns Array with tokens approvals for the actions.
     * @param account address that will receive all the resulting funds.
     */
    function executeActions(
        Action[] memory actions,
        Output[] memory minReturns,
        address payable account
    )
        public
        payable
    {
        address[][] memory tokensToBeWithdrawn = new address[][](actions.length);

        for (uint256 i = 0; i < actions.length; i++) {
            tokensToBeWithdrawn[i] = callInteractiveAdapter(actions[i]);
            emit ExecutedAction(i);
        }

        returnTokens(minReturns, tokensToBeWithdrawn, account);
    }

    function callInteractiveAdapter(
        Action memory action
    )
        internal
        returns (address[] memory)
    {
        require(action.actionType != ActionType.None, "L: wrong action type!");
        require(action.amounts.length == action.amountTypes.length, "L: inconsistent arrays![1]");
        require(action.amounts.length == action.tokens.length, "L: inconsistent arrays![2]");
        address[] memory adapters = adapterRegistry.getProtocolAdapters(action.protocolName);
        require(action.adapterIndex <= adapters.length, "L: wrong index!");
        address adapter = adapters[action.adapterIndex];

        bytes4 selector;
        if (action.actionType == ActionType.Deposit) {
            selector = InteractiveAdapter(adapter).deposit.selector;
        } else {
            selector = InteractiveAdapter(adapter).withdraw.selector;
        }

        // solhint-disable-next-line avoid-low-level-calls
        (bool success, bytes memory returnData) = adapter.delegatecall(
            abi.encodeWithSelector(
                selector,
                action.tokens,
                action.amounts,
                action.amountTypes,
                action.data
            )
        );

        // assembly revert opcode is used here as `returnData`
        // is already bytes array generated by the callee's revert()
        // solhint-disable-next-line no-inline-assembly
        assembly {
            if eq(success, 0) { revert(add(returnData, 32), returndatasize()) }
        }

        address[] memory tokensToBeWithdrawn = abi.decode(returnData, (address[]));

        return tokensToBeWithdrawn;
    }

    function returnTokens(
        Output[] memory minReturns,
        address[][] memory tokensToBeWithdrawn,
        address payable account
    )
        internal
    {
        address token;
        uint256 amount;

        for (uint256 i = 0; i < minReturns.length; i++) {
            token = minReturns[i].token;
            if (token == ETH) {
                amount = address(this).balance;
                require(amount > minReturns[i].amount, "L: less then min!");
                account.transfer(amount);
            } else {
                amount = ERC20(token).balanceOf(address(this));
                require(amount > minReturns[i].amount, "L: less then min!");
                ERC20(token).safeTransfer(account, amount, "L!");
            }
        }

        for (uint256 i = 0; i < tokensToBeWithdrawn.length; i++) {
            for (uint256 j = 0; j < tokensToBeWithdrawn[i].length; j++) {
                token = tokensToBeWithdrawn[i][j];
                amount = ERC20(token).balanceOf(address(this));
                if (amount > 0) {
                    ERC20(token).safeTransfer(account, amount, "L!");
                }
            }
        }

        amount = address(this).balance;
        if (amount > 0) {
            account.transfer(amount);
        }
    }
}