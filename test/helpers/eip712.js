const { BN } = require('@openzeppelin/test-helpers');
const ethSigUtil = require('eth-sig-util');
const { fromRpcSig } = require('ethereumjs-util');
const ERC20Permit = artifacts.require('@openzeppelin/contracts/token/ERC20/extensions/draft-ERC20Permit.sol:ERC20Permit');
const { cutSelector, trim0x } = require('./utils.js');

const EIP712Domain = [
    { name: 'name', type: 'string' },
    { name: 'version', type: 'string' },
    { name: 'chainId', type: 'uint256' },
    { name: 'verifyingContract', type: 'address' },
];

const Permit = [
    { name: 'owner', type: 'address' },
    { name: 'spender', type: 'address' },
    { name: 'value', type: 'uint256' },
    { name: 'nonce', type: 'uint256' },
    { name: 'deadline', type: 'uint256' },
];

function domainSeparator (name, version, chainId, verifyingContract) {
    return '0x' + ethSigUtil.TypedDataUtils.hashStruct(
        'EIP712Domain',
        { name, version, chainId, verifyingContract },
        { EIP712Domain },
    ).toString('hex');
}

const defaultDeadline = new BN('18446744073709551615');

function buildData (owner, name, version, chainId, verifyingContract, spender, nonce, value, deadline) {
    return {
        primaryType: 'Permit',
        types: { EIP712Domain, Permit },
        domain: { name, version, chainId, verifyingContract },
        message: { owner, spender, value, nonce, deadline },
    };
}

async function getPermit (owner, ownerPrivateKey, token, tokenVersion, chainId, spender, value, deadline = defaultDeadline) {
    const permitContract = await ERC20Permit.at(token.address);
    const nonce = await permitContract.nonces(owner);
    const name = await permitContract.name();
    const data = buildData(owner, name, tokenVersion, chainId, token.address, spender, nonce, value, deadline);
    const signature = ethSigUtil.signTypedMessage(Buffer.from(ownerPrivateKey, 'hex'), { data });
    const { v, r, s } = fromRpcSig(signature);
    const permitCall = permitContract.contract.methods.permit(owner, spender, value, deadline, v, r, s).encodeABI();
    return cutSelector(permitCall);
}

function withTarget(target, data) {
    return target.toString() + trim0x(data);
}

module.exports = {
    EIP712Domain,
    Permit,
    domainSeparator,
    getPermit,
    withTarget
};
