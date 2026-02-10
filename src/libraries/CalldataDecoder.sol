// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title Library for abi decoding in calldata
library CalldataDecoder {
  error SliceOutOfBounds();

  /// @notice mask used for offsets and lengths to ensure no overflow
  /// @dev no sane abi encoding will pass in an offset or length greater than type(uint32).max
  ///      (note that this does deviate from standard solidity behavior and offsets/lengths will
  ///      be interpreted as mod type(uint32).max which will only impact malicious/buggy callers)
  uint256 internal constant OFFSET_OR_LENGTH_MASK = 0xffffffff;
  uint256 internal constant OFFSET_OR_LENGTH_MASK_AND_WORD_ALIGN = 0xffffffe0;

  /// @notice equivalent to SliceOutOfBounds.selector, stored in least-significant bits
  uint256 internal constant SLICE_ERROR_SELECTOR = 0x3b99b53d;

  function decodeAddress(bytes calldata _bytes) internal pure returns (address value) {
    assembly ('memory-safe') {
      value := calldataload(_bytes.offset)
    }
  }

  function decodeAddress(bytes calldata _bytes, uint256 _arg)
    internal
    pure
    returns (address value)
  {
    assembly ('memory-safe') {
      value := calldataload(add(_bytes.offset, shl(5, _arg)))
    }
  }

  function decodeUint256(bytes calldata _bytes) internal pure returns (uint256 value) {
    assembly ('memory-safe') {
      value := calldataload(_bytes.offset)
    }
  }

  function decodeUint256(bytes calldata _bytes, uint256 _arg)
    internal
    pure
    returns (uint256 value)
  {
    assembly ('memory-safe') {
      value := calldataload(add(_bytes.offset, shl(5, _arg)))
    }
  }

  function decodeBool(bytes calldata _bytes) internal pure returns (bool value) {
    assembly ('memory-safe') {
      value := calldataload(_bytes.offset)
    }
  }

  function decodeBool(bytes calldata _bytes, uint256 _arg) internal pure returns (bool value) {
    assembly ('memory-safe') {
      value := calldataload(add(_bytes.offset, shl(5, _arg)))
    }
  }

  function decodeBytes32(bytes calldata _bytes) internal pure returns (bytes32 value) {
    assembly ('memory-safe') {
      value := calldataload(_bytes.offset)
    }
  }

  function decodeBytes32(bytes calldata _bytes, uint256 _arg)
    internal
    pure
    returns (bytes32 value)
  {
    assembly ('memory-safe') {
      value := calldataload(add(_bytes.offset, shl(5, _arg)))
    }
  }

  /// @notice Decode the `_arg`-th element in `_bytes` as a dynamic array
  /// @dev The decoding of `length` and `offset` is universal,
  /// whereas the type declaration of `res` instructs the compiler how to read it.
  /// @param _bytes The input bytes string to slice
  /// @param _arg The index of the argument to extract
  /// @return length Length of the array
  /// @return offset Pointer to the data part of the array
  function decodeLengthOffset(bytes calldata _bytes, uint256 _arg)
    internal
    pure
    returns (uint256 length, uint256 offset)
  {
    assembly ('memory-safe') {
      // The offset of the `_arg`-th element is `32 * arg`, which stores the offset of the length pointer.
      // shl(5, x) is equivalent to mul(32, x)
      let lengthPtr := add(_bytes.offset, calldataload(add(_bytes.offset, shl(5, _arg))))
      length := calldataload(lengthPtr)
      offset := add(lengthPtr, 0x20)

      // if the provided bytes string isnt as long as the encoding says, revert
      if lt(add(_bytes.length, _bytes.offset), add(length, offset)) {
        mstore(0, SLICE_ERROR_SELECTOR)
        revert(0x1c, 4)
      }
    }
  }

  /// @notice Decode the `_arg`-th element in `_bytes` as `bytes`
  /// @param _bytes The input bytes string to extract a bytes string from
  /// @param _arg The index of the argument to extract
  function decodeBytes(bytes calldata _bytes, uint256 _arg)
    internal
    pure
    returns (bytes calldata res)
  {
    (uint256 length, uint256 offset) = decodeLengthOffset(_bytes, _arg);
    assembly ('memory-safe') {
      res.length := length
      res.offset := offset
    }
  }

  /// @notice Decode the `_arg`-th element in `_bytes` as `uint256[]`
  /// @param _bytes The input bytes string to extract a uint256 array from
  /// @param _arg The index of the argument to extract
  function decodeUint256Array(bytes calldata _bytes, uint256 _arg)
    internal
    pure
    returns (uint256[] calldata res)
  {
    (uint256 length, uint256 offset) = decodeLengthOffset(_bytes, _arg);
    assembly ('memory-safe') {
      res.length := length
      res.offset := offset
    }
  }

  /// @notice Decode the `_arg`-th element in `_bytes` as `address[]`
  /// @param _bytes The input bytes string to extract an address array from
  /// @param _arg The index of the argument to extract
  function decodeAddressArray(bytes calldata _bytes, uint256 _arg)
    internal
    pure
    returns (address[] calldata res)
  {
    (uint256 length, uint256 offset) = decodeLengthOffset(_bytes, _arg);
    assembly ('memory-safe') {
      res.length := length
      res.offset := offset
    }
  }

  /// @notice Decode the `_arg`-th element in `_bytes` as `bytes32[]`
  /// @param _bytes The input bytes string to extract a bytes32 array from
  /// @param _arg The index of the argument to extract
  function decodeBytes32Array(bytes calldata _bytes, uint256 _arg)
    internal
    pure
    returns (bytes32[] calldata res)
  {
    (uint256 length, uint256 offset) = decodeLengthOffset(_bytes, _arg);
    assembly ('memory-safe') {
      res.length := length
      res.offset := offset
    }
  }
}
