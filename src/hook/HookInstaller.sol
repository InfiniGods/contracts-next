// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;

import { LibBitmap } from "@solady/utils/LibBitmap.sol";

import { IHook } from "../interface/hook/IHook.sol";
import { IHookInstaller } from "../interface/hook/IHookInstaller.sol";

import { HookInstallerStorage } from "../storage/hook/HookInstallerStorage.sol";

abstract contract HookInstaller is IHookInstaller {
    using LibBitmap for LibBitmap.Bitmap;

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted on failure to perform a call.
    error HookInstallerCallFailed();

    /// @notice Emitted on attempt to call non-existent hook.
    error HookInstallerInvalidHook();

    /// @notice Emitted on attempt to call an uninstalled hook.
    error HookInstallerHookNotInstalled();

    /// @notice Emitted on attempting to call with more value than sent.
    error HookInstallerInvalidValue();

    /// @notice Emitted on attempt to write to hooks without permission.
    error HookInstallerUnauthorizedWrite();

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     *  @notice Retusn the implementation of a given hook, if any.
     *  @param _flag The bits representing the hook.
     *  @return impl The implementation of the hook.
     */
    function getHookImplementation(uint256 _flag) public view returns (address) {
        return HookInstallerStorage.data().hookImplementationMap[_flag];
    }

    /**
     *  @notice A generic entrypoint to read state of any of the installed hooks.
     *  @param _hookFlag The bits representing the hook.
     *  @param _data The data to pass to the hook staticcall.
     *  @return returndata The return data from the hook view function call.
     */
    function hookFunctionRead(uint256 _hookFlag, bytes calldata _data) external view returns (bytes memory) {
        if (_hookFlag > 2**_maxHookFlag()) {
            revert HookInstallerInvalidHook();
        }

        address target = getHookImplementation(_hookFlag);
        if (target == address(0)) {
            revert HookInstallerHookNotInstalled();
        }

        (bool success, bytes memory returndata) = target.staticcall(_data);
        if (!success) {
            _revert(returndata);
        }
        return returndata;
    }

    /*//////////////////////////////////////////////////////////////
                            EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     *  @notice Installs a hook in the contract.
     *  @dev Maps all hook functions implemented by the hook to the hook's address.
     *  @param _hook The hook to install.
     */
    function installHook(IHook _hook) external {
        if (!_canUpdateHooks(msg.sender)) {
            revert HookNotAuthorized();
        }
        _installHook(_hook);
    }

    /**
     *  @notice Uninstalls a hook in the contract.
     *  @dev Reverts if the hook is not installed already.
     *  @param _hook The hook to uninstall.
     */
    function uninstallHook(IHook _hook) external {
        if (!_canUpdateHooks(msg.sender)) {
            revert HookNotAuthorized();
        }
        _uninstallHook(_hook);
    }

    /**
     *  @notice A generic entrypoint to write state of any of the installed hooks.
     */
    function hookFunctionWrite(
        uint256 _hookFlag,
        uint256 _value,
        bytes calldata _data
    ) external payable returns (bytes memory) {
        if (!_canWriteToHooks(msg.sender)) {
            revert HookInstallerUnauthorizedWrite();
        }
        if (_hookFlag > 2**_maxHookFlag()) {
            revert HookInstallerInvalidHook();
        }
        if (msg.value != _value) {
            revert HookInstallerInvalidValue();
        }

        address target = getHookImplementation(_hookFlag);
        if (target == address(0)) {
            revert HookInstallerHookNotInstalled();
        }

        (bool success, bytes memory returndata) = target.call{ value: _value }(_data);
        if (!success) {
            _revert(returndata);
        }

        return returndata;
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev Returns whether the caller can update hooks.
    function _canUpdateHooks(address _caller) internal view virtual returns (bool);

    /// @dev Returns whether the caller can write to hooks.
    function _canWriteToHooks(address _caller) internal view virtual returns (bool);

    /// @dev Should return the max flag that represents a hook.
    function _maxHookFlag() internal pure virtual returns (uint256) {
        return 0;
    }

    /// @dev Installs a hook in the contract.
    function _installHook(IHook _hook) internal {
        uint256 hooksToInstall = _hook.getHooks();

        _updateHooks(hooksToInstall, address(_hook), _addhook);
        HookInstallerStorage.data().hookImplementations.set(uint160(address(_hook)));

        emit HooksInstalled(address(_hook), hooksToInstall);
    }

    /// @dev Uninstalls a hook in the contract.
    function _uninstallHook(IHook _hook) internal {
        HookInstallerStorage.Data storage data = HookInstallerStorage.data();

        if (!data.hookImplementations.get(uint160(address(_hook)))) {
            revert HookNotInstalled();
        }

        uint256 hooksToUninstall = _hook.getHooks();

        _updateHooks(hooksToUninstall, address(0), _removehook);
        data.hookImplementations.unset(uint160(address(_hook)));

        emit HooksUninstalled(address(_hook), hooksToUninstall);
    }

    /// @dev Adds a hook to the given integer represented hooks.
    function _addhook(uint256 _flag, uint256 _currenthooks) internal pure returns (uint256) {
        if (_currenthooks & _flag > 0) {
            revert HookAlreadyInstalled();
        }
        return _currenthooks | _flag;
    }

    /// @dev Removes a hook from the given integer represented hooks.
    function _removehook(uint256 _flag, uint256 _currenthooks) internal pure returns (uint256) {
        return _currenthooks & ~_flag;
    }

    /// @dev Updates the current active hooks of the contract.
    function _updateHooks(
        uint256 _hooksToUpdate,
        address _implementation,
        function(uint256, uint256) internal pure returns (uint256) _addOrRemovehook
    ) internal {
        HookInstallerStorage.Data storage data = HookInstallerStorage.data();

        uint256 currentActivehooks = data.installedHooks;

        uint256 flag = 2**_maxHookFlag();
        while (flag > 1) {
            if (_hooksToUpdate & flag > 0) {
                currentActivehooks = _addOrRemovehook(flag, currentActivehooks);
                data.hookImplementationMap[flag] = _implementation;
            }

            flag >>= 1;
        }

        data.installedHooks = currentActivehooks;
    }

    /// @dev Reverts with the given return data / error message.
    function _revert(bytes memory _returndata) private pure {
        // Look for revert reason and bubble it up if present
        if (_returndata.length > 0) {
            // The easiest way to bubble the revert reason is using memory via assembly
            /// @solidity memory-safe-assembly
            assembly {
                let returndata_size := mload(_returndata)
                revert(add(32, _returndata), returndata_size)
            }
        } else {
            revert HookInstallerCallFailed();
        }
    }
}
