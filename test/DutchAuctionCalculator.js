const { expect, trim0x, time, assertRoughlyEqualValues } = require('@1inch/solidity-utils');
const { loadFixture } = require('@nomicfoundation/hardhat-network-helpers');
const { cutLastArg, ether, toBN } = require('./helpers/utils');
const { deploySwapTokens } = require('./helpers/fixtures');
const { buildOrder, signOrder } = require('./helpers/orderUtils');
const { ethers } = require('hardhat');

describe('Dutch auction', async () => {
    const [addr, addr1] = await ethers.getSigners();

    before(async () => {
        const DutchAuctionCalculator = await ethers.getContractFactory('DutchAuctionCalculator');
        this.dutchAuctionCalculator = await DutchAuctionCalculator.deploy();
        await this.dutchAuctionCalculator.deployed();
    });

    const deployAndBuildOrder = async () => {
        const { dai, weth, swap, chainId } = await loadFixture(deploySwapTokens);

        await dai.mint(addr.address, ether('100'));
        await dai.mint(addr1.address, ether('100'));
        await weth.deposit({ value: ether('1') });
        await weth.connect(addr1).deposit({ value: ether('1') });

        await dai.approve(swap.address, ether('100'));
        await dai.connect(addr1).approve(swap.address, ether('100'));
        await weth.approve(swap.address, ether('1'));
        await weth.connect(addr1).approve(swap.address, ether('1'));

        const ts = await time.latest();
        const startEndTs = toBN(ts).shln(128).or(toBN(ts).addn(86400));
        const order = buildOrder(
            {
                makerAsset: dai.address,
                takerAsset: weth.address,
                makingAmount: ether('100'),
                takingAmount: ether('0.1'),
                from: addr.address,
            },
            {
                getMakingAmount: this.dutchAuctionCalculator.address + cutLastArg(trim0x(this.dutchAuctionCalculator.interface.encodeFunctionData('getMakingAmount',
                    [startEndTs.toString(), ether('0.1'), ether('0.05'), ether('100'), 0],
                )), 64),
                getTakingAmount: this.dutchAuctionCalculator.address + cutLastArg(trim0x(this.dutchAuctionCalculator.interface.encodeFunctionData('getTakingAmount',
                    [startEndTs.toString(), ether('0.1'), ether('0.05'), ether('100'), 0],
                )), 64),
            },
        );
        const signature = await signOrder(order, chainId, swap.address, addr);

        const makerDaiBefore = await dai.balanceOf(addr.address);
        const takerDaiBefore = await dai.balanceOf(addr1.address);
        const makerWethBefore = await weth.balanceOf(addr.address);
        const takerWethBefore = await weth.balanceOf(addr1.address);
        return { dai, weth, swap, ts, order, signature, makerDaiBefore, takerDaiBefore, makerWethBefore, takerWethBefore };
    };

    it('swap with makingAmount 50% time passed', async () => {
        const { dai, weth, swap, ts, order, signature, makerDaiBefore, takerDaiBefore, makerWethBefore, takerWethBefore } = await loadFixture(deployAndBuildOrder);

        await time.increaseTo(toBN(ts).addn(43200)); // 50% auction time
        await swap.connect(addr1).fillOrder(order, signature, '0x', ether('100'), '0', ether('0.08'));

        expect(await dai.balanceOf(addr.address)).to.equal(makerDaiBefore.sub(ether('100')));
        expect(await dai.balanceOf(addr1.address)).to.equal(takerDaiBefore.add(ether('100')));
        assertRoughlyEqualValues(await weth.balanceOf(addr.address), makerWethBefore.add(ether('0.075')), 1e-6);
        assertRoughlyEqualValues(await weth.balanceOf(addr1.address), takerWethBefore.sub(ether('0.075')), 1e-6);
    });

    it('swap with takingAmount 50% time passed', async () => {
        const { dai, weth, swap, ts, order, signature, makerDaiBefore, takerDaiBefore, makerWethBefore, takerWethBefore } = await loadFixture(deployAndBuildOrder);

        await time.increaseTo(toBN(ts).addn(43200)); // 50% auction time
        await swap.connect(addr1).fillOrder(order, signature, '0x', '0', ether('0.075'), ether('100'));

        expect(await dai.balanceOf(addr.address)).to.equal(makerDaiBefore.sub(ether('100')));
        expect(await dai.balanceOf(addr1.address)).to.equal(takerDaiBefore.add(ether('100')));
        assertRoughlyEqualValues(await weth.balanceOf(addr.address), makerWethBefore.add(ether('0.075')), 1e-6);
        assertRoughlyEqualValues(await weth.balanceOf(addr1.address), takerWethBefore.sub(ether('0.075')), 1e-6);
    });

    it('swap with makingAmount 0% time passed', async () => {
        const { dai, weth, swap, order, signature, makerDaiBefore, takerDaiBefore, makerWethBefore, takerWethBefore } = await loadFixture(deployAndBuildOrder);

        await swap.connect(addr1).fillOrder(order, signature, '0x', ether('100'), '0', ether('0.1'));

        expect(await dai.balanceOf(addr.address)).to.equal(makerDaiBefore.sub(ether('100')));
        expect(await dai.balanceOf(addr1.address)).to.equal(takerDaiBefore.add(ether('100')));
        assertRoughlyEqualValues(await weth.balanceOf(addr.address), makerWethBefore.add(ether('0.1')), 1e-6);
        assertRoughlyEqualValues(await weth.balanceOf(addr1.address), takerWethBefore.sub(ether('0.1')), 1e-6);
    });

    it('swap with takingAmount 0% time passed', async () => {
        const { dai, weth, swap, order, signature, makerDaiBefore, takerDaiBefore, makerWethBefore, takerWethBefore } = await loadFixture(deployAndBuildOrder);

        await swap.connect(addr1).fillOrder(order, signature, '0x', '0', ether('0.1'), ether('100'));

        expect(await dai.balanceOf(addr.address)).to.equal(makerDaiBefore.sub(ether('100')));
        expect(await dai.balanceOf(addr1.address)).to.equal(takerDaiBefore.add(ether('100')));
        assertRoughlyEqualValues(await weth.balanceOf(addr.address), makerWethBefore.add(ether('0.1')), 1e-6);
        assertRoughlyEqualValues(await weth.balanceOf(addr1.address), takerWethBefore.sub(ether('0.1')), 1e-6);
    });

    it('swap with makingAmount 100% time passed', async () => {
        const { dai, weth, swap, ts, order, signature, makerDaiBefore, takerDaiBefore, makerWethBefore, takerWethBefore } = await loadFixture(deployAndBuildOrder);

        await time.increaseTo(toBN(ts).addn(86500)); // >100% auction time
        await swap.connect(addr1).fillOrder(order, signature, '0x', ether('100'), '0', ether('0.05'));

        expect(await dai.balanceOf(addr.address)).to.equal(makerDaiBefore.sub(ether('100')));
        expect(await dai.balanceOf(addr1.address)).to.equal(takerDaiBefore.add(ether('100')));
        assertRoughlyEqualValues(await weth.balanceOf(addr.address), makerWethBefore.add(ether('0.05')), 1e-6);
        assertRoughlyEqualValues(await weth.balanceOf(addr1.address), takerWethBefore.sub(ether('0.05')), 1e-6);
    });

    it('swap with takingAmount 100% time passed', async () => {
        const { dai, weth, swap, ts, order, signature, makerDaiBefore, takerDaiBefore, makerWethBefore, takerWethBefore } = await loadFixture(deployAndBuildOrder);

        await time.increaseTo(toBN(ts).addn(86500)); // >100% auction time
        await swap.connect(addr1).fillOrder(order, signature, '0x', '0', ether('0.05'), ether('100'));

        expect(await dai.balanceOf(addr.address)).to.equal(makerDaiBefore.sub(ether('100')));
        expect(await dai.balanceOf(addr1.address)).to.equal(takerDaiBefore.add(ether('100')));
        assertRoughlyEqualValues(await weth.balanceOf(addr.address), makerWethBefore.add(ether('0.05')), 1e-6);
        assertRoughlyEqualValues(await weth.balanceOf(addr1.address), takerWethBefore.sub(ether('0.05')), 1e-6);
    });
});