// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2026 Everlong Labs Limited
pragma solidity ^0.8.0;

/// @notice Test-only views and admin entries of the deployed FLAMM pool (c104), with the exact
/// signatures of `IFLAMM`. The adapter never calls these; the fork tests use the previews to
/// quote the same state they execute against, and the rest to arm the leverage venue under
/// `vm.prank`.
interface IFLAMMTestHooks {
  struct HookSet {
    address invariantHook;
    address feeHook;
    address recenterHook;
    address controllerHook;
    address leverageHook;
    address spreadHook;
    address loanSwapHook;
  }

  function previewSwap(bool poolAssetIn, uint256 amountIn)
    external
    view
    returns (uint256 amountInUsed, uint256 amountOut, uint256 feeWad);

  function previewLever(bool up, uint256 amountIn)
    external
    view
    returns (uint256 amountInUsed, uint256 amountOut, uint256 spreadPpm, uint256 crAfterWad);

  /// @dev Curator sets either way; the guardian may only pause.
  function setLevPaused(bool p) external;

  function hooks() external view returns (HookSet memory);

  function core() external view returns (address);
}

/// @notice The leverage venue's keeper-posted spread. Re-posting the standing value makes it
/// live again without changing it.
interface ILeverageSpreadHook {
  function spread() external view returns (uint24);

  /// @dev Core keeper or owner, inside [minSpread, maxSpread].
  function setSpread(uint24 newSpread) external;
}

interface IEverlongCore {
  function owner() external view returns (address);
  function keeper() external view returns (address);
}
