// SPDX-License-Identifier: MIT

pragma solidity 0.8.11;

import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/utils/cryptography/draft-EIP712.sol";
import "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "./helpers/AmountCalculator.sol";
import "./helpers/ChainlinkCalculator.sol";
import "./helpers/NonceManager.sol";
import "./helpers/PredicateHelper.sol";
import "./interfaces/NotificationReceiver.sol";
import "./libraries/ArgumentsDecoder.sol";
import "./libraries/Permitable.sol";

library OrderType {
    struct Order {
        uint256 salt;
        address makerAsset;
        address takerAsset;
        address maker;
        address receiver;
        address allowedSender;  // equals to Zero address on public orders
        uint256 makingAmount;
        uint256 takingAmount;
        uint256 offsets;
        // bytes makerAssetData;
        // bytes takerAssetData;
        // bytes getMakingAmount; // this.staticcall(abi.encodePacked(bytes, swapTakerAmount)) => (swapMakerAmount)
        // bytes getTakingAmount; // this.staticcall(abi.encodePacked(bytes, swapMakerAmount)) => (swapTakerAmount)
        // bytes predicate;      // this.staticcall(bytes) => (bool)
        // bytes permit;         // On first fill: permit.1.call(abi.encodePacked(permit.selector, permit.2))
        // bytes preInteraction;
        // bytes postInteraction;
        bytes interactions; // concat(makerAssetData, takerAssetData, getMakingAmount, getTakingAmount, predicate, permit, preIntercation, postInteraction)
    }

    enum DynamicField {
        MakerAssetData,
        TakerAssetData,
        GetMakingAmount,
        GetTakingAmount,
        Predicate,
        Permit,
        PreInteraction,
        PostInteraction
    }

    function _get(Order calldata order, DynamicField field) private pure returns(bytes calldata) {
        if (uint256(field) == 0) {
            return order.interactions[0:uint32(order.offsets)];
        }

        uint256 bitShift = 32 * uint256(field);
        return order.interactions[
            uint32(order.offsets >> (bitShift - 32)):
            uint32(order.offsets >> bitShift)
        ];
    }

    function makerAssetData(Order calldata order) internal pure returns(bytes calldata) {
        return _get(order, DynamicField.MakerAssetData);
    }

    function takerAssetData(Order calldata order) internal pure returns(bytes calldata) {
        return _get(order, DynamicField.TakerAssetData);
    }

    function getMakingAmount(Order calldata order) internal pure returns(bytes calldata) {
        return _get(order, DynamicField.GetMakingAmount);
    }

    function getTakingAmount(Order calldata order) internal pure returns(bytes calldata) {
        return _get(order, DynamicField.GetTakingAmount);
    }

    function predicate(Order calldata order) internal pure returns(bytes calldata) {
        return _get(order, DynamicField.Predicate);
    }

    function permit(Order calldata order) internal pure returns(bytes calldata) {
        return _get(order, DynamicField.Permit);
    }

    function preInteraction(Order calldata order) internal pure returns(bytes calldata) {
        return _get(order, DynamicField.PreInteraction);
    }

    function postInteraction(Order calldata order) internal pure returns(bytes calldata) {
        return _get(order, DynamicField.PostInteraction);
    }
}

/// @title Regular Limit Order mixin
abstract contract OrderMixin is
    EIP712,
    AmountCalculator,
    ChainlinkCalculator,
    NonceManager,
    PredicateHelper,
    Permitable
{
    using Address for address;
    using ArgumentsDecoder for bytes;
    using OrderType for OrderType.Order;

    /// @notice Emitted every time order gets filled, including partial fills
    event OrderFilled(
        address indexed maker,
        bytes32 orderHash,
        uint256 remaining
    );

    /// @notice Emitted when order gets cancelled
    event OrderCanceled(
        address indexed maker,
        bytes32 orderHash,
        uint256 remainingRaw
    );

    bytes32 constant public LIMIT_ORDER_TYPEHASH = keccak256(
        "Order(uint256 salt,address makerAsset,address takerAsset,address maker,address receiver,address allowedSender,uint256 makingAmount,uint256 takingAmount,uint256 offsets,bytes interactions)"
    );
    uint256 constant private _ORDER_DOES_NOT_EXIST = 0;
    uint256 constant private _ORDER_FILLED = 1;

    /// @notice Stores unfilled amounts for each order plus one.
    /// Therefore 0 means order doesn't exist and 1 means order was filled
    mapping(bytes32 => uint256) private _remaining;

    /// @notice Returns unfilled amount for order. Throws if order does not exist
    function remaining(bytes32 orderHash) external view returns(uint256) {
        uint256 amount = _remaining[orderHash];
        require(amount != _ORDER_DOES_NOT_EXIST, "LOP: Unknown order");
        unchecked { amount -= 1; }
        return amount;
    }

    /// @notice Returns unfilled amount for order
    /// @return Result Unfilled amount of order plus one if order exists. Otherwise 0
    function remainingRaw(bytes32 orderHash) external view returns(uint256) {
        return _remaining[orderHash];
    }

    /// @notice Same as `remainingRaw` but for multiple orders
    function remainingsRaw(bytes32[] memory orderHashes) external view returns(uint256[] memory) {
        uint256[] memory results = new uint256[](orderHashes.length);
        for (uint256 i = 0; i < orderHashes.length; i++) {
            results[i] = _remaining[orderHashes[i]];
        }
        return results;
    }

    /**
     * @notice Calls every target with corresponding data. Then reverts with CALL_RESULTS_0101011 where zeroes and ones
     * denote failure or success of the corresponding call
     * @param targets Array of addresses that will be called
     * @param data Array of data that will be passed to each call
     */
    function simulateCalls(address[] calldata targets, bytes[] calldata data) external {
        require(targets.length == data.length, "LOP: array size mismatch");
        bytes memory reason = new bytes(targets.length);
        for (uint256 i = 0; i < targets.length; i++) {
            // solhint-disable-next-line avoid-low-level-calls
            (bool success, bytes memory result) = targets[i].call(data[i]);
            if (success && result.length > 0) {
                success = result.length == 32 && result.decodeBoolMemory();
            }
            reason[i] = success ? bytes1("1") : bytes1("0");
        }

        // Always revert and provide per call results
        revert(string(abi.encodePacked("CALL_RESULTS_", reason)));
    }

    /// @notice Cancels order by setting remaining amount to zero
    function cancelOrder(OrderType.Order calldata order) external {
        require(order.maker == msg.sender, "LOP: Access denied");

        bytes32 orderHash = hashOrder(order);
        uint256 orderRemaining = _remaining[orderHash];
        require(orderRemaining != _ORDER_FILLED, "LOP: already filled");
        emit OrderCanceled(msg.sender, orderHash, orderRemaining);
        _remaining[orderHash] = _ORDER_FILLED;
    }

    /// @notice Fills an order. If one doesn't exist (first fill) it will be created using order.makerAssetData
    /// @param order Order quote to fill
    /// @param signature Signature to confirm quote ownership
    /// @param makingAmount Making amount
    /// @param takingAmount Taking amount
    /// @param thresholdAmount Specifies maximum allowed takingAmount when takingAmount is zero, otherwise specifies minimum allowed makingAmount
    function fillOrder(
        OrderType.Order calldata order,
        bytes calldata signature,
        bytes calldata interaction,
        uint256 makingAmount,
        uint256 takingAmount,
        uint256 thresholdAmount
    ) external returns(uint256 /* actualMakingAmount */, uint256 /* actualTakingAmount */) {
        return fillOrderTo(order, signature, interaction, makingAmount, takingAmount, thresholdAmount, msg.sender);
    }

    /// @notice Same as `fillOrder` but calls permit first,
    /// allowing to approve token spending and make a swap in one transaction.
    /// Also allows to specify funds destination instead of `msg.sender`
    /// @param order Order quote to fill
    /// @param signature Signature to confirm quote ownership
    /// @param makingAmount Making amount
    /// @param takingAmount Taking amount
    /// @param thresholdAmount Specifies maximum allowed takingAmount when takingAmount is zero, otherwise specifies minimum allowed makingAmount
    /// @param target Address that will receive swap funds
    /// @param permit Should consist of abiencoded token address and encoded `IERC20Permit.permit` call.
    /// @dev See tests for examples
    function fillOrderToWithPermit(
        OrderType.Order calldata order,
        bytes calldata signature,
        bytes calldata interaction,
        uint256 makingAmount,
        uint256 takingAmount,
        uint256 thresholdAmount,
        address target,
        bytes calldata permit
    ) external returns(uint256 /* actualMakingAmount */, uint256 /* actualTakingAmount */) {
        require(permit.length >= 20, "LOP: permit length too low");
        {  // Stack too deep
            (address token, bytes calldata permitData) = permit.decodeTargetAndCalldata();
            _permit(token, permitData);
        }
        return fillOrderTo(order, signature, interaction, makingAmount, takingAmount, thresholdAmount, target);
    }

    /// @notice Same as `fillOrder` but allows to specify funds destination instead of `msg.sender`
    /// @param order_ Order quote to fill
    /// @param signature Signature to confirm quote ownership
    /// @param makingAmount Making amount
    /// @param takingAmount Taking amount
    /// @param thresholdAmount Specifies maximum allowed takingAmount when takingAmount is zero, otherwise specifies minimum allowed makingAmount
    /// @param target Address that will receive swap funds
    function fillOrderTo(
        OrderType.Order calldata order_,
        bytes calldata signature,
        bytes calldata interaction,
        uint256 makingAmount,
        uint256 takingAmount,
        uint256 thresholdAmount,
        address target
    ) public returns(uint256 /* actualMakingAmount */, uint256 /* actualTakingAmount */) {
        require(target != address(0), "LOP: zero target is forbidden");
        bytes32 orderHash = hashOrder(order_);

        OrderType.Order calldata order = order_; // Helps with "Stack too deep"

        {  // Stack too deep
            uint256 remainingMakerAmount = _remaining[orderHash];
            require(remainingMakerAmount != _ORDER_FILLED, "LOP: remaining amount is 0");
            require(order.allowedSender == address(0) || order.allowedSender == msg.sender, "LOP: private order");
            if (remainingMakerAmount == _ORDER_DOES_NOT_EXIST) {
                // First fill: validate order and permit maker asset
                require(SignatureChecker.isValidSignatureNow(order.maker, orderHash, signature), "LOP: bad signature");
                remainingMakerAmount = order.makingAmount;

                bytes calldata permit = order.permit(); // Helps with "Stack too deep"
                if (permit.length >= 20) {
                    // proceed only if permit length is enough to store address
                    (address token, bytes calldata permitCalldata) = permit.decodeTargetAndCalldata();
                    _permitMemory(token, permitCalldata);
                    require(_remaining[orderHash] == _ORDER_DOES_NOT_EXIST, "LOP: reentrancy detected");
                }
            } else {
                unchecked { remainingMakerAmount -= 1; }
            }

            // Check if order is valid
            if (order.predicate().length > 0) {
                require(checkPredicate(order), "LOP: predicate returned false");
            }

            // Compute maker and taker assets amount
            if ((takingAmount == 0) == (makingAmount == 0)) {
                revert("LOP: only one amount should be 0");
            } else if (takingAmount == 0) {
                uint256 requestedMakingAmount = makingAmount;
                if (makingAmount > remainingMakerAmount) {
                    makingAmount = remainingMakerAmount;
                }
                takingAmount = _callGetter(order.getTakingAmount(), order.makingAmount, makingAmount, order.takingAmount);
                // check that actual rate is not worse than what was expected
                // takingAmount / makingAmount <= thresholdAmount / requestedMakingAmount
                require(takingAmount * requestedMakingAmount <= thresholdAmount * makingAmount, "LOP: taking amount too high");
            } else {
                uint256 requestedTakingAmount = takingAmount;
                makingAmount = _callGetter(order.getMakingAmount(), order.takingAmount, takingAmount, order.makingAmount);
                if (makingAmount > remainingMakerAmount) {
                    makingAmount = remainingMakerAmount;
                    takingAmount = _callGetter(order.getTakingAmount(), order.makingAmount, makingAmount, order.takingAmount);
                }
                // check that actual rate is not worse than what was expected
                // makingAmount / takingAmount >= thresholdAmount / requestedTakingAmount
                require(makingAmount * requestedTakingAmount >= thresholdAmount * takingAmount, "LOP: making amount too low");
            }

            require(makingAmount > 0 && takingAmount > 0, "LOP: can't swap 0 amount");

            // Update remaining amount in storage
            unchecked {
                remainingMakerAmount = remainingMakerAmount - makingAmount;
                _remaining[orderHash] = remainingMakerAmount + 1;
            }
            emit OrderFilled(msg.sender, orderHash, remainingMakerAmount);
        }

        // Maker can handle funds interactively
        if (order.preInteraction().length >= 20) {
            // proceed only if interaction length is enough to store address
            (address interactionTarget, bytes calldata interactionData) = order.preInteraction().decodeTargetAndCalldata();
            PreInteractionNotificationReceiver(interactionTarget).fillOrderPreInteraction(
                msg.sender, order.makerAsset, order.takerAsset, makingAmount, takingAmount, interactionData
            );
        }

        // Maker => Taker
        _makeCall(
            order.makerAsset,
            abi.encodePacked(
                IERC20.transferFrom.selector,
                uint256(uint160(order.maker)),
                uint256(uint160(target)),
                makingAmount,
                order.makerAssetData()
            )
        );

        if (interaction.length >= 20) {
            // proceed only if interaction length is enough to store address
            (address interactionTarget, bytes calldata interactionData) = interaction.decodeTargetAndCalldata();
            InteractionNotificationReceiver(interactionTarget).fillOrderInteraction(
                msg.sender, order.makerAsset, order.takerAsset, makingAmount, takingAmount, interactionData
            );
        }

        // Taker => Maker
        _makeCall(
            order.takerAsset,
            abi.encodePacked(
                IERC20.transferFrom.selector,
                uint256(uint160(msg.sender)),
                uint256(uint160(order.receiver == address(0) ? order.maker : order.receiver)),
                takingAmount,
                order.takerAssetData()
            )
        );

        // Maker can handle funds interactively
        if (order.postInteraction().length >= 20) {
            // proceed only if interaction length is enough to store address
            (address interactionTarget, bytes calldata interactionData) = order.postInteraction().decodeTargetAndCalldata();
            PostInteractionNotificationReceiver(interactionTarget).fillOrderPostInteraction(
                msg.sender, order.makerAsset, order.takerAsset, makingAmount, takingAmount, interactionData
            );
        }

        return (makingAmount, takingAmount);
    }

    /// @notice Checks order predicate
    function checkPredicate(OrderType.Order calldata order) public view returns(bool) {
        bytes memory result = address(this).functionStaticCall(order.predicate(), "LOP: predicate call failed");
        require(result.length == 32, "LOP: invalid predicate return");
        return result.decodeBoolMemory();
    }

    function hashOrder(OrderType.Order calldata order) public view returns(bytes32) {
        bytes32 typehash = LIMIT_ORDER_TYPEHASH;
        bytes calldata interactions = order.interactions;
        bytes32 hash;
        assembly { // solhint-disable-line no-inline-assembly
            let ptr := mload(0x40)
            mstore(0x40, add(ptr, add(0x160, interactions.length)))

            calldatacopy(ptr, interactions.offset, interactions.length)
            mstore(add(ptr, 0x140), keccak256(ptr, interactions.length))
            calldatacopy(add(ptr, 0x20), order, 0x120)
            mstore(ptr, typehash)
            hash := keccak256(ptr, 0x160)
        }

        return _hashTypedDataV4(hash);
    }

    function _makeCall(address asset, bytes memory assetData) private {
        bytes memory result = asset.functionCall(assetData, "LOP: asset.call failed");
        if (result.length > 0) {
            require(result.length == 32 && result.decodeBoolMemory(), "LOP: asset.call bad result");
        }
    }

    function _callGetter(bytes calldata getter, uint256 orderExpectedAmount, uint256 amount, uint256 orderResultAmount) private view returns(uint256) {
        if (getter.length == 0) {
            // On empty getter calldata only exact amount is allowed
            require(amount == orderExpectedAmount, "LOP: wrong amount");
            return orderResultAmount;
        } else {
            bytes memory result = address(this).functionStaticCall(abi.encodePacked(getter, amount), "LOP: getAmount call failed");
            require(result.length == 32, "LOP: invalid getAmount return");
            return result.decodeUint256Memory();
        }
    }
}
