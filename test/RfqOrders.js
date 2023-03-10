const { ethers } = require('hardhat');
const { expect, time, profileEVM, trackReceivedTokenAndTx, getPermit2, permit2Contract } = require('@1inch/solidity-utils');
const { loadFixture } = require('@nomicfoundation/hardhat-network-helpers');
const { buildOrderRFQ, signOrder, compactSignature, makeMakingAmount, makeUnwrapWeth, buildConstraints, buildOrderData } = require('./helpers/orderUtils');
const { getPermit } = require('./helpers/eip712');
const { deploySwapTokens } = require('./helpers/fixtures');
const { constants } = require('ethers');

describe('RFQ Orders in LimitOrderProtocol', function () {
    const emptyInteraction = '0x';
    let addr, addr1, addr2;

    before(async function () {
        [addr, addr1, addr2] = await ethers.getSigners();
    });

    const initContracts = async function () {
        const { dai, weth, swap, chainId, usdc } = await loadFixture(deploySwapTokens);

        await dai.mint(addr.address, '1000000');
        await dai.mint(addr1.address, '1000000');
        await weth.deposit({ value: '1000000' });
        await weth.connect(addr1).deposit({ value: '1000000' });

        await dai.approve(swap.address, '1000000');
        await weth.approve(swap.address, '1000000');
        await dai.connect(addr1).approve(swap.address, '1000000');
        await weth.connect(addr1).approve(swap.address, '1000000');

        await usdc.mint(addr.address, '1000000');
        await usdc.approve(swap.address, '1000000');

        return { dai, weth, swap, chainId, usdc };
    };

    it('@skip-on-coverage should swap fully based on RFQ signature', async function () {
        // Order: 1 DAI => 1 WETH
        // Swap:  1 DAI => 1 WETH
        const { dai, weth, swap, chainId } = await loadFixture(initContracts);

        for (const nonce of [1, 2]) {
            const order = buildOrderRFQ({
                maker: addr1.address,
                makerAsset: dai.address,
                takerAsset: weth.address,
                makingAmount: 1,
                takingAmount: 1,
                constraints: buildConstraints({ nonce }),
            });
            const signature = await signOrder(order, chainId, swap.address, addr1);

            const { r, vs } = compactSignature(signature);
            const receipt = await swap.fillOrder(order, r, vs, 1, makeMakingAmount(1));

            expect(
                await profileEVM(ethers.provider, receipt.hash, ['CALL', 'STATICCALL', 'SSTORE', 'SLOAD', 'EXTCODESIZE']),
            ).to.be.deep.equal([2, 1, 7, 7, 0]);

            // await gasspectEVM(receipt.hash);

            expect(receipt)
                .to.changeTokenBalances(dai, [addr, addr1], [1, -1])
                .to.changeTokenBalances(weth, [addr, addr1], [-1, 1]);
        }
    });

    describe('Permit', function () {
        describe('fillOrderToWithPermit', function () {
            it('DAI => WETH', async function () {
                const { dai, weth, swap, chainId } = await loadFixture(initContracts);
                const order = buildOrderRFQ({
                    maker: addr1.address,
                    makerAsset: dai.address,
                    takerAsset: weth.address,
                    makingAmount: 1,
                    takingAmount: 1,
                    constraints: buildConstraints({ nonce: 1 }),
                });
                const signature = await signOrder(order, chainId, swap.address, addr1);

                const permit = await getPermit(addr.address, addr, weth, '1', chainId, swap.address, '1');

                const { r, vs } = compactSignature(signature);
                await expect(swap.fillOrderToWithPermit(order, r, vs, 1, makeMakingAmount(1), addr.address, emptyInteraction, permit))
                    .to.changeTokenBalances(dai, [addr, addr1], [1, -1])
                    .to.changeTokenBalances(weth, [addr, addr1], [-1, 1]);
            });

            it('DAI => WETH, permit2', async function () {
                const { dai, weth, swap, chainId } = await loadFixture(initContracts);
                const order = buildOrderRFQ({
                    maker: addr1.address,
                    makerAsset: dai.address,
                    takerAsset: weth.address,
                    makingAmount: 1,
                    takingAmount: 1,
                    constraints: buildConstraints({ nonce: 1, usePermit2: true }),
                });
                const signature = await signOrder(order, chainId, swap.address, addr1);

                const permit2 = await permit2Contract();
                await dai.connect(addr1).approve(permit2.address, 1);
                const permit = await getPermit2(addr1, dai.address, chainId, swap.address, 1);

                const { r, vs } = compactSignature(signature);
                await expect(swap.fillOrderToWithPermit(order, r, vs, 1, makeMakingAmount(1), addr.address, emptyInteraction, permit))
                    .to.changeTokenBalances(dai, [addr, addr1], [1, -1])
                    .to.changeTokenBalances(weth, [addr, addr1], [-1, 1]);
            });

            it('rejects reused signature', async function () {
                const { dai, weth, swap, chainId } = await loadFixture(initContracts);
                const order = buildOrderRFQ({
                    maker: addr1.address,
                    makerAsset: dai.address,
                    takerAsset: weth.address,
                    makingAmount: 1,
                    takingAmount: 1,
                    constraints: buildConstraints({ nonce: 1 }),
                });
                const signature = await signOrder(order, chainId, swap.address, addr1);

                const permit = await getPermit(addr.address, addr, weth, '1', chainId, swap.address, '1');
                const { r, vs } = compactSignature(signature);
                const requestFunc = () => swap.fillOrderToWithPermit(order, r, vs, 1, 1, addr.address, emptyInteraction, permit);
                await requestFunc();
                await expect(requestFunc()).to.be.revertedWith('ERC20Permit: invalid signature');
            });

            it('rejects other signature', async function () {
                const { dai, weth, swap, chainId } = await loadFixture(initContracts);
                const order = buildOrderRFQ({
                    maker: addr1.address,
                    makerAsset: dai.address,
                    takerAsset: weth.address,
                    makingAmount: 1,
                    takingAmount: 1,
                    constraints: buildConstraints({ nonce: 1 }),
                });
                const signature = await signOrder(order, chainId, swap.address, addr1);

                const permit = await getPermit(addr.address, addr2, weth, '1', chainId, swap.address, '1');
                const { r, vs } = compactSignature(signature);
                const requestFunc = () => swap.fillOrderToWithPermit(order, r, vs, 1, 1, addr.address, emptyInteraction, permit);
                await expect(requestFunc()).to.be.revertedWith('ERC20Permit: invalid signature');
            });

            it('rejects expired permit', async function () {
                const deadline = (await time.latest()) - time.duration.weeks(1);
                const { dai, weth, swap, chainId } = await loadFixture(initContracts);
                const order = buildOrderRFQ({
                    maker: addr1.address,
                    makerAsset: dai.address,
                    takerAsset: weth.address,
                    makingAmount: 1,
                    takingAmount: 1,
                    constraints: buildConstraints({ nonce: 1 }),
                });
                const signature = await signOrder(order, chainId, swap.address, addr1);

                const permit = await getPermit(addr.address, addr1, weth, '1', chainId, swap.address, '1', deadline);
                const { r, vs } = compactSignature(signature);
                const requestFunc = () => swap.fillOrderToWithPermit(order, r, vs, 1, 1, addr.address, emptyInteraction, permit);
                await expect(requestFunc()).to.be.revertedWith('ERC20Permit: expired deadline');
            });
        });
    });

    describe('Order Cancelation', function () {
        it('should cancel own order', async function () {
            const { swap, dai, weth, chainId } = await loadFixture(initContracts);

            const orderNonce = 1;
            const order = buildOrderRFQ({
                maker: addr1.address,
                makerAsset: dai.address,
                takerAsset: weth.address,
                makingAmount: 1,
                takingAmount: 1,
                constraints: buildConstraints({ nonce: orderNonce, allowMultipleFills: false }),
            });
            const data = buildOrderData(chainId, swap.address, order);
            const orderHash = ethers.utils._TypedDataEncoder.hash(data.domain, data.types, data.value);

            await swap.cancelOrder(order.constraints, orderHash);
            const invalidator = await swap.bitInvalidatorForOrder(addr.address, orderNonce);
            expect(invalidator).to.equal('2');
        });

        it('should cancel own order with huge number', async function () {
            const { swap, dai, weth, chainId } = await loadFixture(initContracts);
            const order = buildOrderRFQ({
                maker: addr1.address,
                makerAsset: dai.address,
                takerAsset: weth.address,
                makingAmount: 1,
                takingAmount: 1,
                constraints: buildConstraints({ nonce: 1023, allowMultipleFills: false }),
            });
            const data = buildOrderData(chainId, swap.address, order);
            const orderHash = ethers.utils._TypedDataEncoder.hash(data.domain, data.types, data.value);

            await swap.cancelOrder(order.constraints, orderHash);
            const invalidator = await swap.bitInvalidatorForOrder(addr.address, '1023');
            expect(invalidator).to.equal(1n << 255n);
        });

        it('should not fill cancelled order', async function () {
            const { dai, weth, swap, chainId } = await loadFixture(initContracts);
            const order = buildOrderRFQ({
                maker: addr1.address,
                makerAsset: dai.address,
                takerAsset: weth.address,
                makingAmount: 1,
                takingAmount: 1,
                constraints: buildConstraints({ nonce: 1, allowMultipleFills: false }),
            });
            const data = buildOrderData(chainId, swap.address, order);
            const orderHash = ethers.utils._TypedDataEncoder.hash(data.domain, data.types, data.value);

            const signature = await signOrder(order, chainId, swap.address, addr1);
            await swap.connect(addr1).cancelOrder(order.constraints, orderHash);

            const { r, vs } = compactSignature(signature);
            await expect(
                swap.fillOrder(order, r, vs, 1, makeMakingAmount(1)),
            ).to.be.revertedWithCustomError(swap, 'BitInvalidatedOrder');
        });
    });

    describe('Expiration', function () {
        it('should fill RFQ order when not expired', async function () {
            const { dai, weth, swap, chainId } = await loadFixture(initContracts);
            const order = buildOrderRFQ({
                maker: addr1.address,
                makerAsset: dai.address,
                takerAsset: weth.address,
                makingAmount: 1,
                takingAmount: 1,
                constraints: buildConstraints({ nonce: 1 }),
            });
            const signature = await signOrder(order, chainId, swap.address, addr1);

            const { r, vs } = compactSignature(signature);
            await expect(swap.fillOrder(order, r, vs, 1, makeMakingAmount(1)))
                .to.changeTokenBalances(dai, [addr, addr1], [1, -1])
                .to.changeTokenBalances(weth, [addr, addr1], [-1, 1]);
        });

        it('should partial fill RFQ order', async function () {
            const { dai, weth, swap, chainId } = await loadFixture(initContracts);
            const order = buildOrderRFQ({
                maker: addr1.address,
                makerAsset: dai.address,
                takerAsset: weth.address,
                makingAmount: 2,
                takingAmount: 2,
                constraints: buildConstraints({ nonce: 1 }),
            });
            const signature = await signOrder(order, chainId, swap.address, addr1);

            const { r, vs } = compactSignature(signature);
            await expect(swap.fillOrder(order, r, vs, 1, makeMakingAmount(1)))
                .to.changeTokenBalances(dai, [addr, addr1], [1, -1])
                .to.changeTokenBalances(weth, [addr, addr1], [-1, 1]);
        });

        it('should fully fill RFQ order', async function () {
            const { dai, weth, swap, chainId } = await loadFixture(initContracts);
            const order = buildOrderRFQ({
                maker: addr1.address,
                makerAsset: dai.address,
                takerAsset: weth.address,
                makingAmount: 1,
                takingAmount: 1,
                constraints: buildConstraints({ nonce: 1 }),
            });
            const signature = await signOrder(order, chainId, swap.address, addr1);

            const { r, vs } = compactSignature(signature);
            await expect(swap.fillOrder(order, r, vs, 1, 1))
                .to.changeTokenBalances(dai, [addr, addr1], [1, -1])
                .to.changeTokenBalances(weth, [addr, addr1], [-1, 1]);
        });

        it('should not partial fill RFQ order when 0', async function () {
            const { dai, weth, swap, chainId } = await loadFixture(initContracts);
            const order = buildOrderRFQ({
                maker: addr1.address,
                makerAsset: dai.address,
                takerAsset: weth.address,
                makingAmount: 5,
                takingAmount: 10,
                constraints: buildConstraints({ nonce: 1 }),
            });
            const signature = await signOrder(order, chainId, swap.address, addr1);

            const { r, vs } = compactSignature(signature);
            await expect(
                swap.fillOrder(order, r, vs, 1, 0),
            ).to.be.revertedWithCustomError(swap, 'SwapWithZeroAmount');
        });

        it('should not fill RFQ order when expired', async function () {
            const { dai, weth, swap, chainId } = await loadFixture(initContracts);
            const order = buildOrderRFQ({
                maker: addr1.address,
                makerAsset: dai.address,
                takerAsset: weth.address,
                makingAmount: 1,
                takingAmount: 1,
                constraints: buildConstraints({ expiry: await time.latest() }),
            });
            const signature = await signOrder(order, chainId, swap.address, addr1);

            const { r, vs } = compactSignature(signature);
            await expect(
                swap.fillOrder(order, r, vs, makeMakingAmount(1), 1),
            ).to.be.revertedWithCustomError(swap, 'OrderExpired');
        });
    });

    describe('ETH fill', function () {
        it('should fill with ETH', async function () {
            const { dai, weth, swap, chainId } = await loadFixture(initContracts);
            const order = buildOrderRFQ({
                maker: addr1.address,
                makerAsset: dai.address,
                takerAsset: weth.address,
                makingAmount: 900,
                takingAmount: 3,
                constraints: buildConstraints({ nonce: 1 }),
            });

            const signature = await signOrder(order, chainId, swap.address, addr1);

            const { r, vs } = compactSignature(signature);
            await expect(swap.fillOrder(order, r, vs, 3, 900, { value: 3 }))
                .to.changeTokenBalances(dai, [addr, addr1], [900, -900])
                .to.changeTokenBalances(weth, [addr, addr1], [0, 3]);
        });

        it('should receive ETH after fill', async function () {
            const { dai, weth, swap, chainId } = await loadFixture(initContracts);
            const order = buildOrderRFQ({
                maker: addr1.address,
                makerAsset: weth.address,
                takerAsset: dai.address,
                makingAmount: 3,
                takingAmount: 900,
                constraints: buildConstraints({ nonce: 1 }),
            });
            const signature = await signOrder(order, chainId, swap.address, addr1);

            const { r, vs } = compactSignature(signature);
            await expect(swap.fillOrder(order, r, vs, 3, makeUnwrapWeth(makeMakingAmount(900))))
                .to.changeTokenBalances(dai, [addr, addr1], [900, -900])
                .to.changeTokenBalances(weth, [addr, addr1], [0, -3]);
        });

        it('should revert if taker provided insufficient ETH', async function () {
            const { dai, weth, swap, chainId } = await loadFixture(initContracts);
            const order = buildOrderRFQ({
                maker: addr1.address,
                makerAsset: dai.address,
                takerAsset: weth.address,
                makingAmount: 900,
                takingAmount: 3,
                constraints: buildConstraints({ nonce: 1 }),
            });
            const signature = await signOrder(order, chainId, swap.address, addr1);

            const { r, vs } = compactSignature(signature);
            await expect(
                swap.fillOrder(order, r, vs, 900, makeMakingAmount(3), { value: 2 }),
            ).to.be.revertedWithCustomError(swap, 'InvalidMsgValue');
        });

        it('should refund taker with exceeding ETH', async function () {
            const { dai, weth, swap, chainId } = await loadFixture(initContracts);
            const order = buildOrderRFQ({
                maker: addr1.address,
                makerAsset: dai.address,
                takerAsset: weth.address,
                makingAmount: 900,
                takingAmount: 3,
                constraints: buildConstraints({ nonce: 1 }),
            });
            const signature = await signOrder(order, chainId, swap.address, addr1);

            const { r, vs } = compactSignature(signature);
            const promise = () => swap.fillOrder(order, r, vs, 900, makeMakingAmount(3), { value: 4 });
            const [ethDiff] = await trackReceivedTokenAndTx(ethers.provider, { address: constants.AddressZero }, addr.address, promise);
            expect(ethDiff).to.equal(-3n);
        });

        it('should reverted with takerAsset non-WETH and msg.value greater than 0', async function () {
            const { dai, swap, chainId, usdc } = await loadFixture(initContracts);

            const order = buildOrderRFQ({
                maker: addr1.address,
                makerAsset: dai.address,
                takerAsset: usdc.address,
                makingAmount: 900,
                takingAmount: 900,
                constraints: buildConstraints({ nonce: 1 }),
            });
            const signature = await signOrder(order, chainId, swap.address, addr1);

            const { r, vs } = compactSignature(signature);
            await expect(
                swap.fillOrder(order, r, vs, 900, makeMakingAmount(900), { value: 1 }),
            ).to.be.revertedWithCustomError(swap, 'InvalidMsgValue');
        });
    });
});
