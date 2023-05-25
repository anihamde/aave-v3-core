import { Wallet, BigNumber } from 'ethers';
import { HardhatRuntimeEnvironment } from 'hardhat/types';
import Web3 from 'web3';

declare var hre: HardhatRuntimeEnvironment;

export const createRandomAddress = () => Wallet.createRandom().address;

export const timeLatest = async () => {
  const block = await hre.ethers.provider.getBlock('latest');
  return BigNumber.from(block.timestamp);
};

export const setBlocktime = async (time: number) => {
  await hre.ethers.provider.send('evm_setNextBlockTimestamp', [time]);
};

export const setAutomine = async (activate: boolean) => {
  await hre.network.provider.send('evm_setAutomine', [activate]);
  if (activate) await hre.network.provider.send('evm_mine', []);
};

export const setAutomineEvm = async (activate: boolean) => {
  await hre.network.provider.send('evm_setAutomine', [activate]);
};

export const impersonateAccountsHardhat = async (accounts: string[]) => {
  if (process.env.TENDERLY === 'true') {
    return;
  }
  // eslint-disable-next-line no-restricted-syntax
  for (const account of accounts) {
    // eslint-disable-next-line no-await-in-loop
    await hre.network.provider.request({
      method: 'hardhat_impersonateAccount',
      params: [account],
    });
  }
};

export const convertAddressToBytes32 = (address: string) => {
  var web3 = new Web3(Web3.givenProvider);

  let bytes32Address = '0x' + web3.utils.padLeft(address.replace('0x', ''), 64);

  return bytes32Address.toLowerCase();
};
