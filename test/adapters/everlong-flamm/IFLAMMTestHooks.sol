// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2026 Everlong Labs Limited
pragma solidity ^0.8.0;

/// @notice Test-only views and admin entries of the deployed FLAMM pool (c104), with the exact
/// signatures of `IFLAMM`. The adapter never calls these; the fork tests use them to quote the
/// same state they execute against and to move the curator/keeper dials under `vm.prank`.
interface IFLAMMTestHooks {
  error LevPaused();
  error NotionalCap();
  error PriceBand();
  error SpreadUnavailable();

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

  function switches()
    external
    view
    returns (uint256 featureBits, uint32 delaySec, bool leveragePaused);

  function paused() external view returns (bool);

  function loanConfig(uint8 idx)
    external
    view
    returns (
      address token,
      uint8 decimals,
      uint64 swapPriceBandWad,
      uint64 feeFloorWad,
      uint256 maxSwapNotional,
      uint256 reserveTarget,
      uint256 liquid
    );

  /// @dev Curator (core owner) sets any field; the guardian may only tighten.
  function setLoanConfig(
    uint8 idx,
    uint64 bandWad,
    uint64 feeFloorWad,
    uint256 maxSwapNotional,
    uint256 reserveTarget
  ) external;

  /// @dev Curator sets either way; the guardian may only pause.
  function setLevPaused(bool p) external;

  function hooks() external view returns (HookSet memory);

  function core() external view returns (address);
}

/// @notice The leverage venue's keeper-posted spread. A post older than `maxSpreadAge` is no
/// answer: lever-ups fail closed, lever-downs degrade to the last live spread.
interface ILeverageSpreadHook {
  function spread() external view returns (uint24);
  function minSpread() external view returns (uint24);
  function maxSpread() external view returns (uint24);
  function maxSpreadAge() external view returns (uint32);
  function lastSetTs() external view returns (uint48);

  /// @dev Core keeper or owner, inside [minSpread, maxSpread].
  function setSpread(uint24 newSpread) external;
}

interface IEverlongCore {
  function owner() external view returns (address);
  function guardian() external view returns (address);
  function keeper() external view returns (address);
}
