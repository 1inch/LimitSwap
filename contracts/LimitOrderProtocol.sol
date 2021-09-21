// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/cryptography/draft-EIP712.sol";
import "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/draft-IERC20Permit.sol";

import "./helpers/AmountCalculator.sol";
import "./helpers/ChainlinkCalculator.sol";
import "./helpers/ERC1155Proxy.sol";
import "./helpers/ERC20Proxy.sol";
import "./helpers/ERC721Proxy.sol";
import "./helpers/NonceManager.sol";
import "./helpers/Permitable.sol";
import "./helpers/PredicateHelper.sol";
import "./interfaces/InteractiveNotificationReceiver.sol";
import "./interfaces/IDaiLikePermit.sol";
import "./libraries/ArgumentsDecoder.sol";

/// @title 1inch Limit Order Protocol v1
contract LimitOrderProtocol is
    ImmutableOwner(address(this)),
    EIP712("1inch Limit Order Protocol", "2"),
    AmountCalculator,
    ChainlinkCalculator,
    ERC1155Proxy,
    ERC20Proxy,
    ERC721Proxy,
    NonceManager,
    Permitable,
    PredicateHelper
{
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    using Address for address;
    using ArgumentsDecoder for bytes;

    // Expiration Mask:
    //   predicate := PredicateHelper.timestampBelow(deadline)
    //
    // Maker Nonce:
    //   predicate := this.nonceEquals(makerAddress, makerNonce)

    event OrderFilled(
        address indexed maker,
        bytes32 orderHash,
        uint256 remaining
    );

    event OrderCanceled(
        address indexed maker,
        bytes32 orderHash
    );

    event OrderFilledRFQ(
        bytes32 orderHash,
        uint256 makingAmount
    );

    struct OrderRFQ {
        uint256 info;  // lowest 64 bits is the order id, next 64 bits is the expiration timestamp
        address makerAsset;
        address takerAsset;
        bytes makerAssetData; // (transferFrom.selector, signer, ______, makerAmount, ...)
        bytes takerAssetData; // (transferFrom.selector, sender, signer, takerAmount, ...)
    }

    struct Order {
        uint256 salt;
        address makerAsset;
        address takerAsset;
        bytes makerAssetData; // (transferFrom.selector, signer, ______, makerAmount, ...)
        bytes takerAssetData; // (transferFrom.selector, sender, signer, takerAmount, ...)
        bytes getMakerAmount; // this.staticcall(abi.encodePacked(bytes, swapTakerAmount)) => (swapMakerAmount)
        bytes getTakerAmount; // this.staticcall(abi.encodePacked(bytes, swapMakerAmount)) => (swapTakerAmount)
        bytes predicate;      // this.staticcall(bytes) => (bool)
        bytes permit;         // On first fill: permit.1.call(abi.encodePacked(permit.selector, permit.2))
        bytes interaction;
    }

    bytes32 constant public LIMIT_ORDER_TYPEHASH = keccak256(
        "Order(uint256 salt,address makerAsset,address takerAsset,bytes makerAssetData,bytes takerAssetData,bytes getMakerAmount,bytes getTakerAmount,bytes predicate,bytes permit,bytes interaction)"
    );

    bytes32 constant public LIMIT_ORDER_RFQ_TYPEHASH = keccak256(
        "OrderRFQ(uint256 info,address makerAsset,address takerAsset,bytes makerAssetData,bytes takerAssetData)"
    );

    // solhint-disable-next-line var-name-mixedcase
    bytes4 immutable private _MAX_SELECTOR = bytes4(uint32(IERC20.transferFrom.selector) + 10);

    uint256 constant private _FROM_INDEX = 0;
    uint256 constant private _TO_INDEX = 1;
    uint256 constant private _AMOUNT_INDEX = 2;

    mapping(bytes32 => uint256) private _remaining;
    mapping(address => mapping(uint256 => uint256)) private _invalidator;

    // solhint-disable-next-line func-name-mixedcase
    function DOMAIN_SEPARATOR() external view returns(bytes32) {
        return _domainSeparatorV4();
    }

    /// @notice Returns unfilled amount for order. Throws if order does not exist
    function remaining(bytes32 orderHash) external view returns(uint256) {
        return _remaining[orderHash].sub(1, "LOP: Unknown order");
    }

    /// @notice Returns unfilled amount for order
    /// @return Result Unfilled amount of order plus one if order exists. Otherwise 0
    function remainingRaw(bytes32 orderHash) external view returns(uint256) {
        return _remaining[orderHash];
    }

    /// @notice Same as `remainingRaw` but for multiple orders
    function remainingsRaw(bytes32[] memory orderHashes) external view returns(uint256[] memory results) {
        results = new uint256[](orderHashes.length);
        for (uint i = 0; i < orderHashes.length; i++) {
            results[i] = _remaining[orderHashes[i]];
        }
    }

    /// @notice Returns bitmask for double-spend invalidators based on lowest byte of order.info and filled quotes
    /// @return Result Each bit represents whenever corresponding quote was filled
    function invalidatorForOrderRFQ(address maker, uint256 slot) external view returns(uint256) {
        return _invalidator[maker][slot];
    }

    /// @notice Checks order predicate
    function checkPredicate(Order memory order) public view returns(bool) {
        bytes memory result = address(this).functionStaticCall(order.predicate, "LOP: predicate call failed");
        require(result.length == 32, "LOP: invalid predicate return");
        return abi.decode(result, (bool));
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
        for (uint i = 0; i < targets.length; i++) {
            // solhint-disable-next-line avoid-low-level-calls
            (bool success, bytes memory result) = targets[i].call(data[i]);
            if (success && result.length > 0) {
                success = abi.decode(result, (bool));
            }
            reason[i] = success ? bytes1("1") : bytes1("0");
        }

        // Always revert and provide per call results
        revert(string(abi.encodePacked("CALL_RESULTS_", reason)));
    }

    /// @notice Cancels order by setting remaining amount to zero
    function cancelOrder(Order memory order) external {
        require(order.makerAssetData.decodeAddress(_FROM_INDEX) == msg.sender, "LOP: Access denied");

        bytes32 orderHash = _hash(order);
        require(_remaining[orderHash] != 1, "LOP: already filled");
        _remaining[orderHash] = 1;
        emit OrderCanceled(msg.sender, orderHash);
    }

    /// @notice Cancels order's quote
    function cancelOrderRFQ(uint256 orderInfo) external {
        _invalidator[msg.sender][uint64(orderInfo) >> 8] |= (1 << (orderInfo & 0xff));
    }

    /// @notice Fills order's quote, fully or partially (whichever is possible)
    /// @param order Order quote to fill
    /// @param signature Signature to confirm quote ownership
    /// @param makingAmount Making amount
    /// @param takingAmount Taking amount
    function fillOrderRFQ(
        OrderRFQ memory order,
        bytes calldata signature,
        uint256 makingAmount,
        uint256 takingAmount
    ) external returns(uint256, uint256) {
        return fillOrderRFQTo(order, signature, makingAmount, takingAmount, msg.sender);
    }

    function fillOrderRFQToWithPermit(
        OrderRFQ memory order,
        bytes calldata signature,
        uint256 makingAmount,
        uint256 takingAmount,
        address target,
        bytes calldata encodedTokenPermitPair
    ) external returns(uint256, uint256) {
        _permit(encodedTokenPermitPair);
        return fillOrderRFQTo(order, signature, makingAmount, takingAmount, target);
    }

    function fillOrderRFQTo(
        OrderRFQ memory order,
        bytes calldata signature,
        uint256 makingAmount,
        uint256 takingAmount,
        address target
    ) public returns(uint256, uint256) {
        // Check time expiration
        uint256 expiration = uint128(order.info) >> 64;
        require(expiration == 0 || block.timestamp <= expiration, "LOP: order expired");  // solhint-disable-line not-rely-on-time

        {  // Stack too deep
            // Validate double spend
            address maker = order.makerAssetData.decodeAddress(_FROM_INDEX);
            uint256 invalidatorSlot = uint64(order.info) >> 8;
            uint256 invalidatorBit = 1 << (order.info & 0xff);
            uint256 invalidator = _invalidator[maker][invalidatorSlot];
            require(invalidator & invalidatorBit == 0, "LOP: already filled");
            _invalidator[maker][invalidatorSlot] = invalidator | invalidatorBit;
        }

        // Compute partial fill if needed
        uint256 orderMakerAmount = order.makerAssetData.decodeUint256(_AMOUNT_INDEX);
        uint256 orderTakerAmount = order.takerAssetData.decodeUint256(_AMOUNT_INDEX);
        if (takingAmount == 0 && makingAmount == 0) {
            // Two zeros means whole order
            makingAmount = orderMakerAmount;
            takingAmount = orderTakerAmount;
        }
        else if (takingAmount == 0) {
            takingAmount = (makingAmount * orderTakerAmount + orderMakerAmount - 1) / orderMakerAmount;
        }
        else if (makingAmount == 0) {
            makingAmount = takingAmount * orderMakerAmount / orderTakerAmount;
        }
        else {
            revert("LOP: one of amounts should be 0");
        }

        require(makingAmount > 0 && takingAmount > 0, "LOP: can't swap 0 amount");
        require(makingAmount <= orderMakerAmount, "LOP: making amount exceeded");
        require(takingAmount <= orderTakerAmount, "LOP: taking amount exceeded");

        // Validate order
        bytes32 orderHash = _hash(order);
        _validate(order.makerAssetData, order.takerAssetData, signature, orderHash);

        // Maker => Taker, Taker => Maker
        _callMakerAssetTransferFrom(order.makerAsset, order.makerAssetData, target, makingAmount);
        _callTakerAssetTransferFrom(order.takerAsset, order.takerAssetData, takingAmount);

        emit OrderFilledRFQ(orderHash, makingAmount);
        return (makingAmount, takingAmount);
    }

    /// @notice Fills an order. If one doesn't exist (first fill) it will be created using order.makerAssetData
    /// @param order Order quote to fill
    /// @param signature Signature to confirm quote ownership
    /// @param makingAmount Making amount
    /// @param takingAmount Taking amount
    /// @param thresholdAmount If makingAmout > 0 this is max takingAmount, else it is min makingAmount
    function fillOrder(
        Order memory order,
        bytes calldata signature,
        uint256 makingAmount,
        uint256 takingAmount,
        uint256 thresholdAmount
    ) external returns(uint256, uint256) {
        return fillOrderTo(order, signature, makingAmount, takingAmount, thresholdAmount, msg.sender);
    }

    function fillOrderToWithPermit(
        Order memory order,
        bytes calldata signature,
        uint256 makingAmount,
        uint256 takingAmount,
        uint256 thresholdAmount,
        address target,
        bytes calldata encodedTokenPermitPair
    ) external returns(uint256, uint256) {
        _permit(encodedTokenPermitPair);
        return fillOrderTo(order, signature, makingAmount, takingAmount, thresholdAmount, target);
    }

    function fillOrderTo(
        Order memory order,
        bytes calldata signature,
        uint256 makingAmount,
        uint256 takingAmount,
        uint256 thresholdAmount,
        address target
    ) public returns(uint256, uint256) {
        bytes32 orderHash = _hash(order);

        {  // Stack too deep
            uint256 remainingMakerAmount;
            { // Stack too deep
                bool orderExists;
                (orderExists, remainingMakerAmount) = _remaining[orderHash].trySub(1);
                if (!orderExists) {
                    // First fill: validate order and permit maker asset
                    _validate(order.makerAssetData, order.takerAssetData, signature, orderHash);
                    remainingMakerAmount = order.makerAssetData.decodeUint256(_AMOUNT_INDEX);
                    if (order.permit.length > 0) {
                        _permit(order.permit);
                        require(_remaining[orderHash] == 0, "LOP: reentrancy detected");
                    }
                }
            }

            // Check if order is valid
            if (order.predicate.length > 0) {
                require(checkPredicate(order), "LOP: predicate returned false");
            }

            // Compute maker and taker assets amount
            if ((takingAmount == 0) == (makingAmount == 0)) {
                revert("LOP: only one amount should be 0");
            }
            else if (takingAmount == 0) {
                if (makingAmount > remainingMakerAmount) {
                    makingAmount = remainingMakerAmount;
                }
                takingAmount = _callGetTakerAmount(order, makingAmount);
                require(takingAmount <= thresholdAmount, "LOP: taking amount too high");
            }
            else {
                makingAmount = _callGetMakerAmount(order, takingAmount);
                if (makingAmount > remainingMakerAmount) {
                    makingAmount = remainingMakerAmount;
                    takingAmount = _callGetTakerAmount(order, makingAmount);
                }
                require(makingAmount >= thresholdAmount, "LOP: making amount too low");
            }

            require(makingAmount > 0 && takingAmount > 0, "LOP: can't swap 0 amount");

            // Update remaining amount in storage
            unchecked {
                remainingMakerAmount = remainingMakerAmount - makingAmount;
                _remaining[orderHash] = remainingMakerAmount + 1;
            }
            emit OrderFilled(msg.sender, orderHash, remainingMakerAmount);
        }

        // Taker => Maker
        _callTakerAssetTransferFrom(order.takerAsset, order.takerAssetData, takingAmount);

        // Maker can handle funds interactively
        if (order.interaction.length > 0) {
            (address interactionTarget, bytes memory interactionData) = order.interaction.decodeTargetAndCalldata();
            InteractiveNotificationReceiver(interactionTarget).notifyFillOrder(
                msg.sender, order.makerAsset, order.takerAsset, makingAmount, takingAmount, interactionData
            );
        }

        // Maker => Taker
        _callMakerAssetTransferFrom(order.makerAsset, order.makerAssetData, target, makingAmount);

        return (makingAmount, takingAmount);
    }

    function _permit(bytes memory encodedTokenPermitPair) private {
        (address token, bytes memory permit) = encodedTokenPermitPair.decodeTargetAndCalldata();
        _permit(IERC20(token), permit);
    }

    function _hash(Order memory order) private view returns(bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    LIMIT_ORDER_TYPEHASH,
                    order.salt,
                    order.makerAsset,
                    order.takerAsset,
                    keccak256(order.makerAssetData),
                    keccak256(order.takerAssetData),
                    keccak256(order.getMakerAmount),
                    keccak256(order.getTakerAmount),
                    keccak256(order.predicate),
                    keccak256(order.permit),
                    keccak256(order.interaction)
                )
            )
        );
    }

    function _hash(OrderRFQ memory order) private view returns(bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    LIMIT_ORDER_RFQ_TYPEHASH,
                    order.info,
                    order.makerAsset,
                    order.takerAsset,
                    keccak256(order.makerAssetData),
                    keccak256(order.takerAssetData)
                )
            )
        );
    }

    function _validate(bytes memory makerAssetData, bytes memory takerAssetData, bytes memory signature, bytes32 orderHash) private view {
        require(makerAssetData.length >= 100, "LOP: bad makerAssetData.length");
        require(takerAssetData.length >= 100, "LOP: bad takerAssetData.length");
        bytes4 makerSelector = makerAssetData.decodeSelector();
        bytes4 takerSelector = takerAssetData.decodeSelector();
        require(makerSelector >= IERC20.transferFrom.selector && makerSelector <= _MAX_SELECTOR, "LOP: bad makerAssetData.selector");
        require(takerSelector >= IERC20.transferFrom.selector && takerSelector <= _MAX_SELECTOR, "LOP: bad takerAssetData.selector");

        address maker = address(makerAssetData.decodeAddress(_FROM_INDEX));
        require(SignatureChecker.isValidSignatureNow(maker, orderHash, signature), "LOP: bad signature");
    }

    function _callMakerAssetTransferFrom(address makerAsset, bytes memory makerAssetData, address taker, uint256 makingAmount) private {
        // Patch receiver or validate private order
        address orderTakerAddress = makerAssetData.decodeAddress(_TO_INDEX);
        if (orderTakerAddress != address(0)) {
            require(orderTakerAddress == msg.sender, "LOP: private order");
        }
        if (orderTakerAddress != taker) {
            makerAssetData.patchAddress(_TO_INDEX, taker);
        }
        _makeCall(makerAsset, makerAssetData, makingAmount);
    }

    function _callTakerAssetTransferFrom(address takerAsset, bytes memory takerAssetData, uint256 takingAmount) private {
        // Patch spender
        takerAssetData.patchAddress(_FROM_INDEX, msg.sender);
        _makeCall(takerAsset, takerAssetData, takingAmount);
    }

    function _makeCall(address asset, bytes memory assetData, uint256 amount) private {
        assetData.patchUint256(_AMOUNT_INDEX, amount);
        bytes memory result = asset.functionCall(assetData, "LOP: asset.call failed");
        if (result.length > 0) {
            require(abi.decode(result, (bool)), "LOP: asset.call bad result");
        }
    }

    function _callGetMakerAmount(Order memory order, uint256 takerAmount) private view returns(uint256 makerAmount) {
        if (order.getMakerAmount.length == 0) {
            // On empty order.getMakerAmount calldata only whole fills are allowed
            require(takerAmount == order.takerAssetData.decodeUint256(_AMOUNT_INDEX), "LOP: wrong taker amount");
            return order.makerAssetData.decodeUint256(_AMOUNT_INDEX);
        }
        bytes memory result = address(this).functionStaticCall(abi.encodePacked(order.getMakerAmount, takerAmount), "LOP: getMakerAmount call failed");
        require(result.length == 32, "LOP: invalid getMakerAmount ret");
        return abi.decode(result, (uint256));
    }

    function _callGetTakerAmount(Order memory order, uint256 makerAmount) private view returns(uint256 takerAmount) {
        if (order.getTakerAmount.length == 0) {
            // On empty order.getTakerAmount calldata only whole fills are allowed
            require(makerAmount == order.makerAssetData.decodeUint256(_AMOUNT_INDEX), "LOP: wrong maker amount");
            return order.takerAssetData.decodeUint256(_AMOUNT_INDEX);
        }
        bytes memory result = address(this).functionStaticCall(abi.encodePacked(order.getTakerAmount, makerAmount), "LOP: getTakerAmount call failed");
        require(result.length == 32, "LOP: invalid getTakerAmount ret");
        return abi.decode(result, (uint256));
    }
}
