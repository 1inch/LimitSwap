const { BN, ether } = require('@openzeppelin/test-helpers');

const addr1PrivateKey = 'ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80';

function price (val) {
    return ether(val).toString();
}

function toBN (num) {
    return new BN(num);
}

function trim0x (bigNumber) {
    const s = bigNumber.toString();
    if (s.startsWith('0x')) {
        return s.substring(2);
    }
    return s;
}

function cutSelector (data) {
    const hexPrefix = '0x';
    return hexPrefix + data.substr(hexPrefix.length + 8);
}

function cutLastArg (data, padding=0) {
    return data.substr(0, data.length - 64 - padding);
}

module.exports = {
    addr1PrivateKey,
    price,
    toBN,
    cutSelector,
    cutLastArg,
    trim0x,
};
