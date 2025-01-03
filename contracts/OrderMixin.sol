// SPDX-License-Identifier: MIT

pragma solidity ^0.8.23;

import "@openzeppelin/contracts/utils/math/Math.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

import "@1inch/solidity-utils/contracts/interfaces/IWETH.sol";
import "@1inch/solidity-utils/contracts/libraries/SafeERC20.sol";
import "@1inch/solidity-utils/contracts/mixins/OnlyWethReceiver.sol";
import "@1inch/solidity-utils/contracts/mixins/PermitAndCall.sol";

import "./helpers/PredicateHelper.sol";
import "./helpers/SeriesEpochManager.sol";
import "./interfaces/ITakerInteraction.sol";
import "./interfaces/IPreInteraction.sol";
import "./interfaces/IPostInteraction.sol";
import "./interfaces/IOrderMixin.sol";
import "./libraries/Errors.sol";
import "./libraries/TakerTraitsLib.sol";
import "./libraries/BitInvalidatorLib.sol";
import "./libraries/RemainingInvalidatorLib.sol";
import "./OrderLib.sol";

/// @title Limit Order mixin
abstract contract OrderMixin is IOrderMixin, EIP712, PredicateHelper, SeriesEpochManager, Pausable, OnlyWethReceiver, PermitAndCall {
    using SafeERC20 for IERC20;
    using SafeERC20 for IWETH;
    using OrderLib for IOrderMixin.Order;
    using ExtensionLib for bytes;
    using AddressLib for Address;
    using MakerTraitsLib for MakerTraits;
    using TakerTraitsLib for TakerTraits;
    using BitInvalidatorLib for BitInvalidatorLib.Data;
    using RemainingInvalidatorLib for RemainingInvalidator;

    IWETH private immutable _WETH;
    mapping(address maker => BitInvalidatorLib.Data data) private _bitInvalidator;
    mapping(address maker => mapping(bytes32 orderHash => RemainingInvalidator remaining)) private _remainingInvalidator;

    constructor(IWETH weth) OnlyWethReceiver(address(weth)) {
        _WETH = weth;
    }

    /**
     * @notice See {IOrderMixin-bitInvalidatorForOrder}.
     */
    function bitInvalidatorForOrder(address maker, uint256 slot) external view returns(uint256 /* result */) {
        return _bitInvalidator[maker].checkSlot(slot);
    }

    /**
     * @notice See {IOrderMixin-remainingInvalidatorForOrder}.
     */
    function remainingInvalidatorForOrder(address maker, bytes32 orderHash) external view returns(uint256 /* remaining */) {
        return _remainingInvalidator[maker][orderHash].remaining();
    }

    /**
     * @notice See {IOrderMixin-rawRemainingInvalidatorForOrder}.
     */
    function rawRemainingInvalidatorForOrder(address maker, bytes32 orderHash) external view returns(uint256 /* remainingRaw */) {
        return RemainingInvalidator.unwrap(_remainingInvalidator[maker][orderHash]);
    }

    /**
     * @notice See {IOrderMixin-simulate}.
     */
    function simulate(address target, bytes calldata data) external {
        // solhint-disable-next-line avoid-low-level-calls
        (bool success, bytes memory result) = target.delegatecall(data);
        revert SimulationResults(success, result);
    }

    /**
     * @notice See {IOrderMixin-cancelOrder}.
     */
    function cancelOrder(MakerTraits makerTraits, bytes32 orderHash) public {
        if (makerTraits.useBitInvalidator()) {
            uint256 invalidator = _bitInvalidator[msg.sender].massInvalidate(makerTraits.nonceOrEpoch(), 0);
            emit BitInvalidatorUpdated(msg.sender, makerTraits.nonceOrEpoch() >> 8, invalidator);
        } else {
            _remainingInvalidator[msg.sender][orderHash] = RemainingInvalidatorLib.fullyFilled();
            emit OrderCancelled(orderHash);
        }
    }

    /**
     * @notice See {IOrderMixin-cancelOrders}.
     */
    function cancelOrders(MakerTraits[] calldata makerTraits, bytes32[] calldata orderHashes) external {
        if (makerTraits.length != orderHashes.length) revert MismatchArraysLengths();
        unchecked {
            for (uint256 i = 0; i < makerTraits.length; i++) {
                cancelOrder(makerTraits[i], orderHashes[i]);
            }
        }
    }

    /**
     * @notice See {IOrderMixin-bitsInvalidateForOrder}.
     */
    function bitsInvalidateForOrder(MakerTraits makerTraits, uint256 additionalMask) external {
        if (!makerTraits.useBitInvalidator()) revert OrderIsNotSuitableForMassInvalidation();
        uint256 invalidator = _bitInvalidator[msg.sender].massInvalidate(makerTraits.nonceOrEpoch(), additionalMask);
        emit BitInvalidatorUpdated(msg.sender, makerTraits.nonceOrEpoch() >> 8, invalidator);
    }

     /**
     * @notice See {IOrderMixin-hashOrder}.
     */
    function hashOrder(IOrderMixin.Order calldata order) external view returns(bytes32) {
        return order.hash(_domainSeparatorV4());
    }

    /**
     * @notice See {IOrderMixin-checkPredicate}.
     */
    function checkPredicate(bytes calldata predicate) public view returns(bool) {
        (bool success, uint256 res) = _staticcallForUint(address(this), predicate);
        return success && res == 1;
    }

    /**
     * @notice See {IOrderMixin-fillOrder}.
     */
    function fillOrder(
        IOrderMixin.Order calldata order,
        bytes32 r,
        bytes32 vs,
        uint256 amount,
        TakerTraits takerTraits
    ) external payable returns(uint256 /* makingAmount */, uint256 /* takingAmount */, bytes32 /* orderHash */) {
        return _fillOrder(order, r, vs, amount, takerTraits, msg.sender, msg.data[:0], msg.data[:0]);
    }

    /**
     * @notice See {IOrderMixin-fillOrderArgs}.
     */
    function fillOrderArgs(
        IOrderMixin.Order calldata order,
        bytes32 r,
        bytes32 vs,
        uint256 amount,
        TakerTraits takerTraits,
        bytes calldata args
    ) external payable returns(uint256 /* makingAmount */, uint256 /* takingAmount */, bytes32 /* orderHash */) {
        (
            address target,
            bytes calldata extension,
            bytes calldata interaction
        ) = _parseArgs(takerTraits, args);

        return _fillOrder(order, r, vs, amount, takerTraits, target, extension, interaction);
    }

    function _fillOrder(
        IOrderMixin.Order calldata order,
        bytes32 r,
        bytes32 vs,
        uint256 amount,
        TakerTraits takerTraits,
        address target,
        bytes calldata extension,
        bytes calldata interaction
    ) private returns(uint256 makingAmount, uint256 takingAmount, bytes32 orderHash) {
        // Check signature and apply order/maker permit only on the first fill
        orderHash = order.hash(_domainSeparatorV4());
        uint256 remainingMakingAmount = _checkRemainingMakingAmount(order, orderHash);
        if (remainingMakingAmount == order.makingAmount) {
            address maker = order.maker.get();
            if (maker == address(0) || maker != ECDSA.recover(orderHash, r, vs)) revert BadSignature();
            if (!takerTraits.skipMakerPermit()) {
                bytes calldata makerPermit = extension.makerPermit();
                if (makerPermit.length >= 20) {
                    // proceed only if taker is willing to execute permit and its length is enough to store address
                    IERC20(address(bytes20(makerPermit))).tryPermit(maker, address(this), makerPermit[20:]);
                    if (!order.makerTraits.useBitInvalidator()) {
                        // Bit orders are not subjects for reentrancy, but we still need to check remaining-based orders for reentrancy
                        if (!_remainingInvalidator[order.maker.get()][orderHash].isNewOrder()) revert ReentrancyDetected();
                    }
                }
            }
        }

        (makingAmount, takingAmount) = _fill(order, orderHash, remainingMakingAmount, amount, takerTraits, target, extension, interaction);
    }

    /**
     * @notice See {IOrderMixin-fillContractOrder}.
     */
    function fillContractOrder(
        IOrderMixin.Order calldata order,
        bytes calldata signature,
        uint256 amount,
        TakerTraits takerTraits
    ) external returns(uint256 /* makingAmount */, uint256 /* takingAmount */, bytes32 /* orderHash */) {
        return _fillContractOrder(order, signature, amount, takerTraits, msg.sender, msg.data[:0], msg.data[:0]);
    }

    /**
     * @notice See {IOrderMixin-fillContractOrderArgs}.
     */
    function fillContractOrderArgs(
        IOrderMixin.Order calldata order,
        bytes calldata signature,
        uint256 amount,
        TakerTraits takerTraits,
        bytes calldata args
    ) external returns(uint256 /* makingAmount */, uint256 /* takingAmount */, bytes32 /* orderHash */) {
        (
            address target,
            bytes calldata extension,
            bytes calldata interaction
        ) = _parseArgs(takerTraits, args);

        return _fillContractOrder(order, signature, amount, takerTraits, target, extension, interaction);
    }

    function _fillContractOrder(
        IOrderMixin.Order calldata order,
        bytes calldata signature,
        uint256 amount,
        TakerTraits takerTraits,
        address target,
        bytes calldata extension,
        bytes calldata interaction
    ) private returns(uint256 makingAmount, uint256 takingAmount, bytes32 orderHash) {
        // Check signature only on the first fill
        orderHash = order.hash(_domainSeparatorV4());
        uint256 remainingMakingAmount = _checkRemainingMakingAmount(order, orderHash);
        if (remainingMakingAmount == order.makingAmount) {
            if (!ECDSA.isValidSignature(order.maker.get(), orderHash, signature)) revert BadSignature();
        }

        (makingAmount, takingAmount) = _fill(order, orderHash, remainingMakingAmount, amount, takerTraits, target, extension, interaction);
    }

    /**
      * @notice Fills an order and transfers making amount to a specified target.
      * @dev If the target is zero assigns it the caller's address.
      * The function flow is as follows:
      * 1. Validate order
      * 2. Call maker pre-interaction
      * 3. Transfer maker asset to taker
      * 4. Call taker interaction
      * 5. Transfer taker asset to maker
      * 5. Call maker post-interaction
      * 6. Emit OrderFilled event
      * @param order The order details.
      * @param orderHash The hash of the order.
      * @param extension The extension calldata of the order.
      * @param remainingMakingAmount The remaining amount to be filled.
      * @param amount The order amount.
      * @param takerTraits The taker preferences for the order.
      * @param target The address to which the order is filled.
      * @param interaction The interaction calldata.
      * @return makingAmount The computed amount that the maker will get.
      * @return takingAmount The computed amount that the taker will send.
      */
    function _fill(
        IOrderMixin.Order calldata order,
        bytes32 orderHash,
        uint256 remainingMakingAmount,
        uint256 amount,
        TakerTraits takerTraits,
        address target,
        bytes calldata extension,
        bytes calldata interaction
    ) private whenNotPaused() returns(uint256 makingAmount, uint256 takingAmount) {
        // Validate order
        {
            (bool valid, bytes4 validationResult) = order.isValidExtension(extension);
            if (!valid) {
                // solhint-disable-next-line no-inline-assembly
                assembly ("memory-safe") {
                    mstore(0, validationResult)
                    revert(0, 4)
                }
            }
        }
        if (!order.makerTraits.isAllowedSender(msg.sender)) revert PrivateOrder();
        if (order.makerTraits.isExpired()) revert OrderExpired();
        if (order.makerTraits.needCheckEpochManager()) {
            if (order.makerTraits.useBitInvalidator()) revert EpochManagerAndBitInvalidatorsAreIncompatible();
            if (!epochEquals(order.maker.get(), order.makerTraits.series(), order.makerTraits.nonceOrEpoch())) revert WrongSeriesNonce();
        }

        // Check if orders predicate allows filling
        if (extension.length > 0) {
            bytes calldata predicate = extension.predicate();
            if (predicate.length > 0) {
                if (!checkPredicate(predicate)) revert PredicateIsNotTrue();
            }
        }

        // Compute maker and taker assets amount
        if (takerTraits.isMakingAmount()) {
            makingAmount = Math.min(amount, remainingMakingAmount);
            takingAmount = order.calculateTakingAmount(extension, makingAmount, remainingMakingAmount, orderHash);

            uint256 threshold = takerTraits.threshold();
            if (threshold > 0) {
                // Check rate: takingAmount / makingAmount <= threshold / amount
                if (amount == makingAmount) {  // Gas optimization, no SafeMath.mul()
                    if (takingAmount > threshold) revert TakingAmountTooHigh();
                } else {
                    if (takingAmount * amount > threshold * makingAmount) revert TakingAmountTooHigh();
                }
            }
        }
        else {
            takingAmount = amount;
            makingAmount = order.calculateMakingAmount(extension, takingAmount, remainingMakingAmount, orderHash);
            if (makingAmount > remainingMakingAmount) {
                // Try to decrease taking amount because computed making amount exceeds remaining amount
                makingAmount = remainingMakingAmount;
                takingAmount = order.calculateTakingAmount(extension, makingAmount, remainingMakingAmount, orderHash);
                if (takingAmount > amount) revert TakingAmountExceeded();
            }

            uint256 threshold = takerTraits.threshold();
            if (threshold > 0) {
                // Check rate: makingAmount / takingAmount >= threshold / amount
                if (amount == takingAmount) { // Gas optimization, no SafeMath.mul()
                    if (makingAmount < threshold) revert MakingAmountTooLow();
                } else {
                    if (makingAmount * amount < threshold * takingAmount) revert MakingAmountTooLow();
                }
            }
        }
        if (!order.makerTraits.allowPartialFills() && makingAmount != order.makingAmount) revert PartialFillNotAllowed();
        unchecked { if (makingAmount * takingAmount == 0) revert SwapWithZeroAmount(); }

        // Invalidate order depending on makerTraits
        if (order.makerTraits.useBitInvalidator()) {
            _bitInvalidator[order.maker.get()].checkAndInvalidate(order.makerTraits.nonceOrEpoch());
        } else {
            _remainingInvalidator[order.maker.get()][orderHash] = RemainingInvalidatorLib.remains(remainingMakingAmount, makingAmount);
        }

        // Pre interaction, where maker can prepare funds interactively
        if (order.makerTraits.needPreInteractionCall()) {
            bytes calldata data = extension.preInteractionTargetAndData();
            address listener = order.maker.get();
            if (data.length > 19) {
                listener = address(bytes20(data));
                data = data[20:];
            }
            IPreInteraction(listener).preInteraction(
                order, extension, orderHash, msg.sender, makingAmount, takingAmount, remainingMakingAmount, data
            );
        }

        // Maker => Taker
        {
            bool needUnwrap = order.makerAsset.get() == address(_WETH) && takerTraits.unwrapWeth();
            address receiver = needUnwrap ? address(this) : target;
            if (order.makerTraits.usePermit2()) {
                if (extension.makerAssetSuffix().length > 0) revert InvalidPermit2Transfer();
                IERC20(order.makerAsset.get()).safeTransferFromPermit2(order.maker.get(), receiver, makingAmount);
            } else {
                if (!_callTransferFromWithSuffix(
                    order.makerAsset.get(),
                    order.maker.get(),
                    receiver,
                    makingAmount,
                    extension.makerAssetSuffix()
                )) revert TransferFromMakerToTakerFailed();
            }
            if (needUnwrap) {
                _WETH.safeWithdrawTo(makingAmount, target);
            }
        }

        if (interaction.length > 19) {
            // proceed only if interaction length is enough to store address
            ITakerInteraction(address(bytes20(interaction))).takerInteraction(
                order, extension, orderHash, msg.sender, makingAmount, takingAmount, remainingMakingAmount, interaction[20:]
            );
        }

        // Taker => Maker
        if (order.takerAsset.get() == address(_WETH) && msg.value > 0) {
            if (msg.value < takingAmount) revert Errors.InvalidMsgValue();
            if (msg.value > takingAmount) {
                unchecked {
                    // solhint-disable-next-line avoid-low-level-calls
                    (bool success, ) = msg.sender.call{value: msg.value - takingAmount}("");
                    if (!success) revert Errors.ETHTransferFailed();
                }
            }

            if (order.makerTraits.unwrapWeth()) {
                // solhint-disable-next-line avoid-low-level-calls
                (bool success, ) = order.getReceiver().call{value: takingAmount}("");
                if (!success) revert Errors.ETHTransferFailed();
            } else {
                _WETH.safeDeposit(takingAmount);
                _WETH.safeTransfer(order.getReceiver(), takingAmount);
            }
        } else {
            if (msg.value != 0) revert Errors.InvalidMsgValue();

            bool needUnwrap = order.takerAsset.get() == address(_WETH) && order.makerTraits.unwrapWeth();
            address receiver = needUnwrap ? address(this) : order.getReceiver();
            if (takerTraits.usePermit2()) {
                if (extension.takerAssetSuffix().length > 0) revert InvalidPermit2Transfer();
                IERC20(order.takerAsset.get()).safeTransferFromPermit2(msg.sender, receiver, takingAmount);
            } else {
                if (!_callTransferFromWithSuffix(
                    order.takerAsset.get(),
                    msg.sender,
                    receiver,
                    takingAmount,
                    extension.takerAssetSuffix()
                )) revert TransferFromTakerToMakerFailed();
            }

            if (needUnwrap) {
                _WETH.safeWithdrawTo(takingAmount, order.getReceiver());
            }
        }

        // Post interaction, where maker can handle funds interactively
        if (order.makerTraits.needPostInteractionCall()) {
            bytes calldata data = extension.postInteractionTargetAndData();
            address listener = order.maker.get();
            if (data.length > 19) {
                listener = address(bytes20(data));
                data = data[20:];
            }
            IPostInteraction(listener).postInteraction(
                order, extension, orderHash, msg.sender, makingAmount, takingAmount, remainingMakingAmount, data
            );
        }

        emit OrderFilled(orderHash, remainingMakingAmount - makingAmount);
    }

    /**
      * @notice Processes the taker interaction arguments.
      * @param takerTraits The taker preferences for the order.
      * @param args The taker interaction arguments.
      * @return target The address to which the order is filled.
      * @return extension The extension calldata of the order.
      * @return interaction The interaction calldata.
      */
    function _parseArgs(TakerTraits takerTraits, bytes calldata args)
        private
        view
        returns(
            address target,
            bytes calldata extension,
            bytes calldata interaction
        )
    {
        if (takerTraits.argsHasTarget()) {
            target = address(bytes20(args));
            args = args[20:];
        } else {
            target = msg.sender;
        }

        uint256 extensionLength = takerTraits.argsExtensionLength();
        if (extensionLength > 0) {
            extension = args[:extensionLength];
            args = args[extensionLength:];
        } else {
            extension = msg.data[:0];
        }

        uint256 interactionLength = takerTraits.argsInteractionLength();
        if (interactionLength > 0) {
            interaction = args[:interactionLength];
        } else {
            interaction = msg.data[:0];
        }
    }

    /**
      * @notice Checks the remaining making amount for the order.
      * @dev If the order has been invalidated, the function will revert.
      * @param order The order to check.
      * @param orderHash The hash of the order.
      * @return remainingMakingAmount The remaining amount of the order.
      */
    function _checkRemainingMakingAmount(IOrderMixin.Order calldata order, bytes32 orderHash) private view returns(uint256 remainingMakingAmount) {
        if (order.makerTraits.useBitInvalidator()) {
            remainingMakingAmount = order.makingAmount;
        } else {
            remainingMakingAmount = _remainingInvalidator[order.maker.get()][orderHash].remaining(order.makingAmount);
        }
        if (remainingMakingAmount == 0) revert InvalidatedOrder();
    }

    /**
      * @notice Calls the transferFrom function with an arbitrary suffix.
      * @dev The suffix is appended to the end of the standard ERC20 transferFrom function parameters.
      * @param asset The token to be transferred.
      * @param from The address to transfer the token from.
      * @param to The address to transfer the token to.
      * @param amount The amount of the token to transfer.
      * @param suffix The suffix (additional data) to append to the end of the transferFrom call.
      * @return success A boolean indicating whether the transfer was successful.
      */
    function _callTransferFromWithSuffix(address asset, address from, address to, uint256 amount, bytes calldata suffix) private returns(bool success) {
        bytes4 selector = IERC20.transferFrom.selector;
        assembly ("memory-safe") { // solhint-disable-line no-inline-assembly
            let data := mload(0x40)
            mstore(data, selector)
            mstore(add(data, 0x04), from)
            mstore(add(data, 0x24), to)
            mstore(add(data, 0x44), amount)
            if suffix.length {
                calldatacopy(add(data, 0x64), suffix.offset, suffix.length)
            }
            let status := call(gas(), asset, 0, data, add(0x64, suffix.length), 0x0, 0x20)
            success := and(status, or(iszero(returndatasize()), and(gt(returndatasize(), 31), eq(mload(0), 1))))
        }
    }
}
