// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import './ICrossCollateralRouter.sol';

import './ICrossCollateralRoutingFee.sol';
import './IFeeContract.sol';
import './ILinearFee.sol';
import './IOffchainQuotedLinearFee.sol';

abstract contract GhostQuoter {
  bytes32 internal constant DEFAULT_ROUTER = keccak256('RoutingFee.DEFAULT_ROUTER');
  uint32 internal constant WILDCARD_DEST = type(uint32).max;
  bytes32 internal constant WILDCARD_RECIPIENT = bytes32(type(uint256).max);

  uint8 internal constant FEE_TYPE_LINEAR = 1;
  uint8 internal constant FEE_TYPE_CROSS_COLLATERAL_ROUTING = 5;
  uint8 internal constant FEE_TYPE_OFFCHAIN_QUOTED_LINEAR = 6;

  error NoFeeContract();
  error UnsupportedFeeType(uint8 feeType);

  function _calcExactInTransfer(
    address routerIn,
    uint32 localDomain,
    bytes32 routerOutBytes32,
    bytes32 recipient,
    uint256 amountIn
  ) internal view returns (uint256 transfer) {
    (uint256 maxFee, uint256 halfAmount) =
      _resolveFeeContractParams(routerIn, localDomain, routerOutBytes32, recipient);

    transfer = _calcExactInMaxTransfer(amountIn, maxFee, halfAmount);
  }

  /// @dev Solves for the largest amount such that amount + fee(amount) <= amountIn.
  ///      fee(x) = min(maxFee, x * maxFee / (2 * halfAmount))
  function _calcExactInMaxTransfer(uint256 amountIn, uint256 maxFee, uint256 halfAmount)
    internal
    pure
    returns (uint256 amount)
  {
    if (maxFee == 0 || halfAmount == 0) return amountIn;

    uint256 wholeAmount = 2 * halfAmount;

    if (amountIn >= maxFee) {
      uint256 cappedAmount = amountIn - maxFee;
      if (cappedAmount >= wholeAmount) return cappedAmount;
    }

    amount = (amountIn * wholeAmount) / (wholeAmount + maxFee);

    // Recover 1 wei of integer-division dust when it still fits the budget. We are
    // provably in the linear region here (amount < wholeAmount), so the fee scales
    // linearly and cannot exceed maxFee — no cap check needed.
    uint256 feeIfRoundedUp = ((amount + 1) * maxFee) / wholeAmount;
    if (amount + 1 + feeIfRoundedUp <= amountIn) {
      amount += 1;
    }
  }

  function _resolveFeeContractParams(
    address routerIn,
    uint32 localDomain,
    bytes32 routerOutBytes32,
    bytes32 recipientBytes32
  ) internal view returns (uint256 maxFee, uint256 halfAmount) {
    address feeRecipient = ICrossCollateralRouter(routerIn).feeRecipient();
    address feeContract = _resolveFeeContract(feeRecipient, localDomain, routerOutBytes32);
    return _resolveFeeParams(feeContract, localDomain, recipientBytes32);
  }

  function _resolveFeeContract(address feeRoot, uint32 domain, bytes32 routerOut)
    internal
    view
    returns (address)
  {
    uint8 ft = IFeeContract(feeRoot).feeType();

    if (ft == FEE_TYPE_CROSS_COLLATERAL_ROUTING) {
      address feeContract = ICrossCollateralRoutingFee(feeRoot).feeContracts(domain, routerOut);

      if (feeContract == address(0)) {
        feeContract = ICrossCollateralRoutingFee(feeRoot).feeContracts(domain, DEFAULT_ROUTER);
      }

      if (feeContract == address(0)) {
        revert NoFeeContract();
      }

      return feeContract;
    }

    return feeRoot;
  }

  function _resolveFeeParams(address feeContract, uint32 domain, bytes32 recipientBytes32)
    internal
    view
    returns (uint256 maxFee, uint256 halfAmount)
  {
    uint8 ft = IFeeContract(feeContract).feeType();

    if (ft == FEE_TYPE_OFFCHAIN_QUOTED_LINEAR) {
      uint48 expiry;

      (maxFee, halfAmount,, expiry) =
        IOffchainQuotedLinearFee(feeContract).quotes(domain, recipientBytes32);
      if (expiry > 0 && block.timestamp <= expiry) return (maxFee, halfAmount);

      (maxFee, halfAmount,, expiry) =
        IOffchainQuotedLinearFee(feeContract).quotes(domain, WILDCARD_RECIPIENT);
      if (expiry > 0 && block.timestamp <= expiry) return (maxFee, halfAmount);

      (maxFee, halfAmount,, expiry) =
        IOffchainQuotedLinearFee(feeContract).quotes(WILDCARD_DEST, recipientBytes32);
      if (expiry > 0 && block.timestamp <= expiry) return (maxFee, halfAmount);

      return (ILinearFee(feeContract).maxFee(), ILinearFee(feeContract).halfAmount());
    }

    if (ft == FEE_TYPE_LINEAR) {
      return (ILinearFee(feeContract).maxFee(), ILinearFee(feeContract).halfAmount());
    }

    revert UnsupportedFeeType(ft);
  }

  function _toBytes32(address a) internal pure returns (bytes32) {
    return bytes32(uint256(uint160(a)));
  }
}
