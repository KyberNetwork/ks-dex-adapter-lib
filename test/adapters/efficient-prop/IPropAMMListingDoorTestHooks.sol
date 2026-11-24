// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2026 Everlong Labs Limited
pragma solidity ^0.8.0;

/// @notice Test-only views of an Efficient PropAMM listing door, with the door's exact signatures.
/// The adapter never calls these; the fork test reads the front, the listing and the pair from the
/// door and checks every fill against the door's own `quote` of the same state.
interface IPropAMMListingDoorTestHooks {
  /// @notice What a fill of `amountIn` pays in this state where the listing has no price source or
  ///         only approved ones; a source's code runs again in the fill and can answer it
  ///         differently.
  ///         Reverts where the listing does not fill `amountIn` now, a tip above its cap included.
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

/// @notice Test-only views of the front a listing trades on, with the front's exact signatures. The
/// adapter never calls these; the Ethereum fork test reads the listing's desk and that desk's quote
/// contract, which logs each fill's `Swapped` on a builder chain.
interface IPropAMMFrontTestHooks {
  /// @notice A listing as its door reads it. The test reads `desk` alone.
  struct DoorView {
    uint256 pairWord;
    address token0;
    address token1;
    address pool;
    uint8 baseIndex;
    uint8 quoteIndex;
    uint8 flags;
    uint32 keyEpoch;
    uint32 desk;
    uint8 wordIndex;
    uint8 scopes;
    uint32 fenceBidPpm;
    uint32 fenceAskPpm;
    uint16 tipCap;
    uint8 confMul;
    uint8 creditMode;
    uint48 bidFillMs;
    uint48 askFillMs;
    uint256 ticket;
    uint256 word;
    uint256[4] depth;
  }

  /// @notice The listing's view.
  function doorView(uint24 listing) external view returns (DoorView memory);

  /// @notice The quote contract of `desk`.
  function deskCellOf(uint32 desk) external view returns (address);
}
