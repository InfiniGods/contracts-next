// SPDX-License-Identifier: Apache 2.0
pragma solidity ^0.8.0;

import "../lib/LibBitmap.sol";
import {ITokenHook, ITokenHookConsumer} from "../interface/extension/ITokenHookConsumer.sol";

abstract contract TokenHookConsumer is ITokenHookConsumer {
    using LibBitmap for LibBitmap.Bitmap;

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 public constant BEFORE_MINT_FLAG = 2 ** 1;
    uint256 public constant BEFORE_TRANSFER_FLAG = 2 ** 2;
    uint256 public constant BEFORE_BURN_FLAG = 2 ** 3;
    uint256 public constant BEFORE_APPROVE_FLAG = 2 ** 4;

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    uint256 private _activeHooks;
    LibBitmap.Bitmap private _hookImplementations;
    mapping(uint256 => address) private _hookImplementationMap;

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function getAllHooks() external view returns (HookImplementation memory hooks) {
        hooks = HookImplementation({
            beforeMint: _hookImplementationMap[BEFORE_MINT_FLAG],
            beforeTransfer: _hookImplementationMap[BEFORE_TRANSFER_FLAG],
            beforeBurn: _hookImplementationMap[BEFORE_BURN_FLAG],
            beforeApprove: _hookImplementationMap[BEFORE_APPROVE_FLAG]
        });
    }

    function getHookImplementation(uint256 _flag) public view returns (address) {
        return _hookImplementationMap[_flag];
    }

    /*//////////////////////////////////////////////////////////////
                            EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function installHook(ITokenHook _hook) external {
        if (!_canUpdateHooks(msg.sender)) {
            revert TokenHookConsumerNotAuthorized();
        }

        uint256 hooksToInstall = _hook.getHooksImplemented();

        _updateHooks(hooksToInstall, address(_hook), _addHook);
        _hookImplementations.set(uint160(address(_hook)));

        emit TokenHookInstalled(address(_hook), hooksToInstall);
    }

    function uninstallHook(ITokenHook _hook) external {
        if (!_canUpdateHooks(msg.sender)) {
            revert TokenHookConsumerNotAuthorized();
        }
        if (!_hookImplementations.get(uint160(address(_hook)))) {
            revert TokenHookConsumerHookDoesNotExist();
        }

        uint256 hooksToUninstall = _hook.getHooksImplemented();

        _updateHooks(hooksToUninstall, address(0), _removeHook);
        _hookImplementations.unset(uint160(address(_hook)));

        emit TokenHookUninstalled(address(_hook), hooksToUninstall);
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _canUpdateHooks(address _caller) internal view virtual returns (bool);

    function _maxFlagIndex() internal pure virtual returns (uint8) {
        return 4;
    }

    function _addHook(uint256 _flag, uint256 _currentHooks) internal pure returns (uint256) {
        if (_currentHooks & _flag > 0) {
            revert TokenHookConsumerHookAlreadyExists();
        }
        return _currentHooks | _flag;
    }

    function _removeHook(uint256 _flag, uint256 _currentHooks) internal pure returns (uint256) {
        return _currentHooks & ~_flag;
    }

    function _updateHooks(
        uint256 _hooksToUpdate,
        address _implementation,
        function (uint256, uint256) internal pure returns (uint256) _addOrRemoveHook
    ) internal {
        uint256 currentActiveHooks = _activeHooks;

        uint256 flag = 2 ** _maxFlagIndex();
        while (flag > 1) {
            if (_hooksToUpdate & flag > 0) {
                currentActiveHooks = _addOrRemoveHook(flag, currentActiveHooks);
                _hookImplementationMap[flag] = _implementation;
            }

            flag >>= 1;
        }

        _activeHooks = currentActiveHooks;
    }

    /*//////////////////////////////////////////////////////////////
                        HOOKS INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _beforeMint(address _to, uint256 _quantity, bytes memory _data)
        internal
        virtual
        returns (bool success, uint256 tokenIdToMint)
    {
        address hook = getHookImplementation(BEFORE_MINT_FLAG);

        if (hook != address(0)) {
            tokenIdToMint = ITokenHook(hook).beforeMint{value: msg.value}(_to, _quantity, _data);
            success = true;
        }
    }

    function _beforeTransfer(address _from, address _to, uint256 _tokenId) internal virtual {
        address hook = getHookImplementation(BEFORE_TRANSFER_FLAG);

        if (hook != address(0)) {
            ITokenHook(hook).beforeTransfer(_from, _to, _tokenId);
        }
    }

    function _beforeBurn(address _from, uint256 _tokenId) internal virtual {
        address hook = getHookImplementation(BEFORE_BURN_FLAG);

        if (hook != address(0)) {
            ITokenHook(hook).beforeBurn(_from, _tokenId);
        }
    }

    function _beforeApprove(address _from, address _to, uint256 _tokenId) internal virtual {
        address hook = getHookImplementation(BEFORE_APPROVE_FLAG);

        if (hook != address(0)) {
            ITokenHook(hook).beforeApprove(_from, _to, _tokenId);
        }
    }
}
