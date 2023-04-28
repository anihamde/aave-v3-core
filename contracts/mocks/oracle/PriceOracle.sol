// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.10;

import {IPriceOracle} from '../../interfaces/IPriceOracle.sol';
import {PythStructs} from '../../dependencies/pyth/PythStructs.sol';

contract PriceOracle is IPriceOracle {
  // Map of asset prices (asset => price)
  mapping(address => uint256) internal prices;

  uint256 internal ethPriceUsd;

  event AssetPriceUpdated(address asset, uint256 price, uint256 timestamp);
  event EthPriceUpdated(uint256 price, uint256 timestamp);

  function getAssetPrice(address asset) external view override returns (uint256) {
    return prices[asset];
  }

  function setAssetPrice(address asset, uint256 price) public override {
    prices[asset] = price;
    emit AssetPriceUpdated(asset, price, block.timestamp);
  }

  function getEthUsdPrice() external view returns (uint256) {
    return ethPriceUsd;
  }

  function setEthUsdPrice(uint256 price) external {
    ethPriceUsd = price;
    emit EthPriceUpdated(price, block.timestamp);
  }

  function updatePythPrice(bytes[] calldata priceUpdateData) external payable {
    // require msg.value == 0 to prevent incidental ETH transfer
    require(msg.value == 0, "Don't send ETH to this contract!");

    // update price via setAssetPrice
    for (uint i = 0; i < priceUpdateData.length; i++) {
      PythStructs.PriceFeed memory priceFeed = abi.decode(
        priceUpdateData[i],
        (PythStructs.PriceFeed)
      );
      uint256 price = uint256(uint64(priceFeed.price.price));
      // IMPORTANT: need to pass this in as the asset itself, not the Pyth source/ID!!
      address asset = address(uint160(uint256(priceFeed.id)));

      setAssetPrice(asset, price);
    }
  }

  receive() external payable {}
}
