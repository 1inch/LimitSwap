const { constants, trim0x } = require('@1inch/solidity-utils');
const { assert } = require('chai');
const { ethers } = require('ethers');
const { setn } = require('./utils');

const OrderRFQ = [
    { name: 'info', type: 'uint256' },
    { name: '_raw1', type: 'uint256' },
    { name: '_raw2', type: 'uint256' },
    { name: '_raw3', type: 'uint256' },
];

const ABIOrderRFQ = {
    type: 'tuple',
    name: 'order',
    components: OrderRFQ,
};

const Order = [
    { name: 'salt', type: 'uint256' },
    { name: 'makerAsset', type: 'address' },
    { name: 'takerAsset', type: 'address' },
    { name: 'maker', type: 'address' },
    { name: 'receiver', type: 'address' },
    { name: 'allowedSender', type: 'address' },
    { name: 'makingAmount', type: 'uint256' },
    { name: 'takingAmount', type: 'uint256' },
    { name: 'offsets', type: 'uint256' },
    { name: 'interactions', type: 'bytes' },
];

const ABIOrder = {
    type: 'tuple',
    name: 'order',
    components: Order,
};

const name = '1inch Limit Order Protocol';
const version = '3';

function buildOrder (
    {
        makerAsset,
        takerAsset,
        makingAmount,
        takingAmount,
        allowedSender = constants.ZERO_ADDRESS,
        receiver = constants.ZERO_ADDRESS,
        from: maker = constants.ZERO_ADDRESS,
    },
    {
        makerAssetData = '0x',
        takerAssetData = '0x',
        getMakingAmount = '0x',
        getTakingAmount = '0x',
        predicate = '0x',
        permit = '0x',
        preInteraction = '0x',
        postInteraction = '0x',
    } = {},
) {
    if (getMakingAmount === '') {
        getMakingAmount = '0x78'; // "x"
    }
    if (getTakingAmount === '') {
        getTakingAmount = '0x78'; // "x"
    }

    const allInteractions = [
        makerAssetData,
        takerAssetData,
        getMakingAmount,
        getTakingAmount,
        predicate,
        permit,
        preInteraction,
        postInteraction,
    ];

    const interactions = '0x' + allInteractions.map(trim0x).join('');

    // https://stackoverflow.com/a/55261098/440168
    const cumulativeSum = (sum => value => { sum += value; return sum; })(0);
    const offsets = allInteractions
        .map(a => a.length / 2 - 1)
        .map(cumulativeSum)
        .reduce((acc, a, i) => acc + (BigInt(a) << BigInt(32 * i)), 0n);

    return {
        salt: '1',
        makerAsset,
        takerAsset,
        maker,
        receiver,
        allowedSender,
        makingAmount: makingAmount.toString(),
        takingAmount: takingAmount.toString(),
        offsets: offsets.toString(),
        interactions,
    };
}

function buildOrderRFQ (
    info,
    makerAsset,
    takerAsset,
    makingAmount,
    takingAmount,
    allowedSender = constants.ZERO_ADDRESS,
) {
    const blob = BigInt(info).toString(16).padStart(64, '0') +
        BigInt(makerAsset).toString(16).padStart(40, '0') +
        BigInt(takerAsset).toString(16).padStart(40, '0') +
        BigInt(allowedSender).toString(16).padStart(40, '0') +
        BigInt(makingAmount).toString(16).padStart(28, '0') +
        BigInt(takingAmount).toString(16).padStart(28, '0') +
        '0000000000000000';
    assert(blob.length === 256, 'Invalid blob length');

    return {
        info: '0x' + blob.slice(0, 64),
        _raw1: '0x' + blob.slice(64, 128),
        _raw2: '0x' + blob.slice(128, 192),
        _raw3: '0x' + blob.slice(192, 256),
    };
}

function buildOrderData (chainId, verifyingContract, order) {
    return {
        domain: { name, version, chainId, verifyingContract },
        types: { Order },
        value: order,
    };
}

function buildOrderRFQData (chainId, verifyingContract, order) {
    return {
        domain: { name, version, chainId, verifyingContract },
        types: { OrderRFQ },
        value: order,
    };
}

async function signOrder (order, chainId, target, wallet) {
    const orderData = buildOrderData(chainId, target, order);
    return await wallet._signTypedData(orderData.domain, orderData.types, orderData.value);
}

async function signOrderRFQ (order, chainId, target, wallet) {
    const orderData = buildOrderRFQData(chainId, target, order);
    return await wallet._signTypedData(orderData.domain, orderData.types, orderData.value);
}

function compactSignature (signature) {
    const sig = ethers.utils.splitSignature(signature);
    return {
        r: sig.r,
        vs: sig._vs,
    };
}

function unwrapWeth (amount) {
    return setn(BigInt(amount), 254, 1).toString();
}

function makingAmount (amount) {
    return setn(BigInt(amount), 255, 1).toString();
}

function takingAmount (amount) {
    return BigInt(amount).toString();
}

module.exports = {
    ABIOrder,
    ABIOrderRFQ,
    buildOrder,
    buildOrderRFQ,
    buildOrderData,
    buildOrderRFQData,
    signOrder,
    signOrderRFQ,
    compactSignature,
    makingAmount,
    takingAmount,
    unwrapWeth,
    name,
    version,
};
