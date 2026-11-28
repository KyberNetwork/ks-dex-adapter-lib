// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2026 Everlong Labs Limited
pragma solidity ^0.8.0;

/// @notice Test-only views of an Efficient PropAMM listing door, with the door's exact signatures.
/// The adapter never calls these; the fork test reads the front, the listing and the pair from the
/// door and checks every fill against the door's own `quote` of the same state.
interface IPropAMMListingDoorTestHooks {
  /// @notice What a fill of `amountIn` pays in this state. Reverts where the listing does not fill
  ///         `amountIn` now.
  function quote(address tokenIn, address tokenOut, uint256 amountIn)
    external
    view
    returns (uint256 amountOut);

  /// @notice The front the listing trades on.
  function FRONT() external view returns (address);

  /// @notice The listing's id on its front.
  function LISTING() external view returns (uint24);

  /// @notice The lower address of the listing's pair.
  function TOKEN0() external view returns (address);

  /// @notice The higher address of the listing's pair.
  function TOKEN1() external view returns (address);
}
