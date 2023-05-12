// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.10;

import '../dependencies/pyth/IPyth.sol';
import '../dependencies/pyth/PythStructs.sol';
import '../dependencies/pyth/MockPyth.sol';
import {Errors} from '../protocol/libraries/helpers/Errors.sol';
import {IACLManager} from '../interfaces/IACLManager.sol';
import {IPoolAddressesProvider} from '../interfaces/IPoolAddressesProvider.sol';
import {IPriceOracleGetter} from '../interfaces/IPriceOracleGetter.sol';
import {IAaveOracle} from '../interfaces/IAaveOracle.sol';

/**
 * @title AaveOracle
 * @author Aave
 * @notice Contract to get asset prices, manage price sources and update the fallback oracle
 * - Use of Pyth as first source of price
 * - If the returned price by Pyth is <= 0 or if the Pyth price is too stale, the call is forwarded to a fallback oracle
 * - Owned by the Aave governance
 */
contract AaveOracle is IAaveOracle {
  IPoolAddressesProvider public immutable ADDRESSES_PROVIDER;

  // Map of asset price IDs (asset => priceID)
  mapping(address => bytes32) private assetsIDs;
  address _pythOracleAddress;
  IPyth _pythOracle;
  uint _oracleMinFreshness;

  IPriceOracleGetter private _fallbackOracle;
  address public immutable override BASE_CURRENCY;
  uint256 public immutable override BASE_CURRENCY_UNIT;

  /**
   * @dev Only asset listing or pool admin can call functions marked by this modifier.
   */
  modifier onlyAssetListingOrPoolAdmins() {
    _onlyAssetListingOrPoolAdmins();
    _;
  }

  /**
   * @notice Constructor
   * @param provider The address of the new PoolAddressesProvider
   * @param assets The addresses of the assets
   * @param sources The bytes32 of the priceID of each asset
   * @param fallbackOracle The address of the fallback oracle to use if Pyth data is not consistent
   * @param baseCurrency The base currency used for the price quotes. If USD is used, base currency is 0x0
   * @param baseCurrencyUnit The unit of the base currency
   * @param pythOracle The address of the Pyth oracle in this network
   * @param oracleMinFreshness The minimum freshness of Pyth price to be able to use that in the protocol
   */
  constructor(
    IPoolAddressesProvider provider,
    address[] memory assets,
    bytes32[] memory sources,
    address fallbackOracle,
    address baseCurrency,
    uint256 baseCurrencyUnit,
    address pythOracle,
    uint oracleMinFreshness
  ) {
    ADDRESSES_PROVIDER = provider;
    _setFallbackOracle(fallbackOracle);
    _setAssetsSources(assets, sources);
    BASE_CURRENCY = baseCurrency;
    BASE_CURRENCY_UNIT = baseCurrencyUnit;
    emit BaseCurrencySet(baseCurrency, baseCurrencyUnit);
    _setPythOracle(pythOracle, oracleMinFreshness);
  }

  /// @inheritdoc IAaveOracle
  function setAssetSources(
    address[] calldata assets,
    bytes32[] calldata sources
  ) external override onlyAssetListingOrPoolAdmins {
    _setAssetsSources(assets, sources);
  }

  /// @inheritdoc IAaveOracle
  function setFallbackOracle(
    address fallbackOracle
  ) external override onlyAssetListingOrPoolAdmins {
    _setFallbackOracle(fallbackOracle);
  }

  /**
   * @notice Internal function to set the sources for each asset
   * @param assets The addresses of the assets
   * @param sources The address of the priceID of each asset
   */
  function _setAssetsSources(address[] memory assets, bytes32[] memory sources) internal {
    require(assets.length == sources.length, Errors.INCONSISTENT_PARAMS_LENGTH);
    for (uint256 i = 0; i < assets.length; i++) {
      bytes32 priceID = sources[i];
      assetsIDs[assets[i]] = priceID;
      emit AssetSourceUpdated(assets[i], sources[i]);
    }
  }

  /**
   * @notice Internal function to set the fallback oracle
   * @param fallbackOracle The address of the fallback oracle
   */
  function _setFallbackOracle(address fallbackOracle) internal {
    _fallbackOracle = IPriceOracleGetter(payable(fallbackOracle));
    emit FallbackOracleUpdated(fallbackOracle);
  }

  /**
   * @notice Internal function to set the Pyth oracle
   * @param pythOracle The address of the Pyth oracle
   * @param oracleMinFreshness The minimum freshness of Pyth price to be able to use that in the protocol
   */
  function _setPythOracle(address pythOracle, uint oracleMinFreshness) internal {
    _pythOracleAddress = pythOracle;
    _pythOracle = IPyth(pythOracle);
    _oracleMinFreshness = oracleMinFreshness;
    emit PythOracleUpdated(pythOracle, oracleMinFreshness);
  }

  function getPythOracleAddress() external view returns (address) {
    return _pythOracleAddress;
  }

  function updatePythPrice(bytes[] calldata priceUpdateData) public payable override {
    // Update the prices to the latest available values and pay the required fee for it. The `priceUpdateData` data
    // should be retrieved from a Pyth off-chain Price Service API using the `pyth-evm-js` package.
    if (priceUpdateData.length > 0) {
      uint fee = _pythOracle.getUpdateFee(priceUpdateData);
      _pythOracle.updatePriceFeeds{value: fee}(priceUpdateData);
    }
  }

  function getLastUpdateTime(address asset) public view returns (uint) {
    bytes32 priceID = assetsIDs[asset];
    PythStructs.Price memory pythPrice;
    pythPrice = _pythOracle.getPriceUnsafe(priceID);
    return pythPrice.publishTime;
  }

  function getPythPriceStruct(
    address asset,
    bool isEma
  ) public view returns (PythStructs.Price memory pythPriceStruct) {
    bytes32 priceID = assetsIDs[asset];
    if (isEma) {
      pythPriceStruct = _pythOracle.getEmaPriceUnsafe(priceID);
    } else {
      pythPriceStruct = _pythOracle.getPriceUnsafe(priceID);
    }
  }

  /// @inheritdoc IPriceOracleGetter
  function getAssetPrice(address asset) public view override returns (uint256) {
    bytes32 priceID = assetsIDs[asset];

    if (asset == BASE_CURRENCY) {
      return BASE_CURRENCY_UNIT;
    } else if (priceID == bytes32(0)) {
      return _fallbackOracle.getAssetPrice(asset);
    } else {
      PythStructs.Price memory pythPrice;
      uint validTime;
      // TODO: use getPriceNoOlderThan if figure out how to handle specific reverts--not sure how to in Solidity
      pythPrice = _pythOracle.getPriceUnsafe(priceID);
      validTime = _pythOracle.getValidTimePeriod();

      int256 price = int256(pythPrice.price);
      bool stalePyth;
      bool staleProtocol;
      if (block.timestamp >= pythPrice.publishTime) {
        stalePyth = (block.timestamp - pythPrice.publishTime) > validTime;
        staleProtocol = (block.timestamp - pythPrice.publishTime) > _oracleMinFreshness;
      } else {
        stalePyth = (pythPrice.publishTime - block.timestamp) > validTime;
        staleProtocol = (pythPrice.publishTime - block.timestamp) > _oracleMinFreshness;
      }
      if (price > 0 && !stalePyth && !staleProtocol) {
        return uint256(price);
      } else {
        return _fallbackOracle.getAssetPrice(asset);
      }
    }
  }

  /// @inheritdoc IAaveOracle
  function getAssetsPrices(
    address[] calldata assets
  ) external view override returns (uint256[] memory) {
    uint256[] memory prices = new uint256[](assets.length);
    for (uint256 i = 0; i < assets.length; i++) {
      prices[i] = getAssetPrice(assets[i]);
    }
    return prices;
  }

  /// @inheritdoc IAaveOracle
  function getSourceOfAsset(address asset) external view override returns (bytes32) {
    return assetsIDs[asset];
  }

  /// @inheritdoc IAaveOracle
  function getFallbackOracle() external view returns (address) {
    return address(_fallbackOracle);
  }

  function _onlyAssetListingOrPoolAdmins() internal view {
    IACLManager aclManager = IACLManager(ADDRESSES_PROVIDER.getACLManager());
    require(
      aclManager.isAssetListingAdmin(msg.sender) || aclManager.isPoolAdmin(msg.sender),
      Errors.CALLER_NOT_ASSET_LISTING_OR_POOL_ADMIN
    );
  }

  receive() external payable {}
}
