// SPDX-License-Identifier: MIT

/// @title Kwenta Basis Trader
/// @author 0xAndor
/// @custom:experimental This is an experimental contract

pragma solidity 0.8.7;

import "@openzeppelin/contracts/access/Ownable.sol";

interface ISpotExchange {
    function exchange(
      bytes32 sourceCurrencyKey,
      uint256 sourceAmount,
      bytes32 destinationCurrencyKey
    ) external returns (uint);
}

interface IExchangeHelper {
    function getAmountsForExchange(
      uint sourceAmount,
      bytes32 sourceCurrencyKey,
      bytes32 destinationCurrencyKey
    )
      external
      view
      returns (
        uint,
        uint,
        uint
      );
}

interface IERC20 {
    function balanceOf(address owner) external view returns (uint);
    function approve(address spender, uint value) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint);
    function transfer(address to, uint value) external returns (bool);
    function transferFrom(
      address from,
      address to,
      uint value
    ) external returns (bool);
}

interface IFuturesMarket {
    function transferMargin(int marginDelta) external;
    function modifyPosition(int sizeDelta) external;
    function closePosition() external;
    function withdrawAllMargin() external;
    function currentFundingRate() external view returns (int);
    function accessibleMargin(address account) external view returns (uint, bool);
    function remainingMargin(address account) external view returns (uint, bool);
    function liquidationPrice(address account) external view returns (uint, bool);
    function positions(address account)
    external
    view
    returns (
      uint64,
      uint64,
      uint128,
      uint128,
      int128
    );
}

contract BasisTrader is Ownable {

  ISpotExchange immutable spotExchange;
  IERC20 immutable quoteAsset;
  IExchangeHelper immutable exchangeHelper;

  bytes32 constant quoteAssetKey = 'sUSD';

  bool public isActive;

  IERC20 internal  baseAsset;
  IFuturesMarket internal futuresMarket;
  bytes32 internal baseAssetKey;
  uint internal baseAssetBalance;
  uint internal startingBalance;

  /// @notice default market is sETH (can switch to other markets by calling changeMarket)
  /// @dev OP mainnet addresses
  constructor () {
    quoteAsset = IERC20(0x8c6f28f2F1A3C87F0f938b96d27520d9751ec8d9);
    baseAsset = IERC20(0xE405de8F52ba7559f9df3C368500B6E6ae6Cee49);
    spotExchange = ISpotExchange(0x8700dAec35aF8Ff88c16BdF0418774CB3D7599B4);
    exchangeHelper = IExchangeHelper(0xcC02F000b0aA8a0eFC2B55C9cf2305Fb3531cca1);
    futuresMarket = IFuturesMarket(0xf86048DFf23cF130107dfB4e6386f574231a5C65);
    baseAssetKey = 'sETH';
  }

  /// @notice returns idle sUSD balance of this contract
  function inactiveBalance() external view returns (uint) {
      return quoteAsset.balanceOf(address(this));
  }

  /// @notice returns futures liquidaton price of an open position
  function futuresLiquidationPrice() external view returns (uint) {
    require(isActive, 'no open position...');
    (uint price, ) = futuresMarket.liquidationPrice(address(this));
      return price;
  }

  /// @notice returns the estimated sUSD value of an open position (spot + futures)
  function currentPositionValue() external view returns (uint) {
    require(isActive, 'no open position...');
    uint futuresBalance;
    uint baseAssetValue;
    uint estimatedBalance;
    (uint openPositionId, , , , ) = futuresMarket.positions(address(this));
    if (openPositionId > 0) {
      (futuresBalance, ) = futuresMarket.remainingMargin(address(this));
    }
    if (baseAssetBalance > 0) {
      (baseAssetValue, , ) =
      exchangeHelper.getAmountsForExchange(
        baseAssetBalance,
        baseAssetKey,
        quoteAssetKey
      );
    }
    estimatedBalance = futuresBalance + baseAssetValue;
    return estimatedBalance;
  }

  function currentPositionPnL() external view returns (int) {
    return int(this.currentPositionValue()) - int(startingBalance);

  }

  function deposit(uint _amountToDeposit) external onlyOwner {
    quoteAsset.transferFrom(msg.sender, address(this), _amountToDeposit);
  }

  function withdrawAll() external onlyOwner {
    require(isActive == false, 'position is still open...');
    quoteAsset.transfer(
      msg.sender,
      quoteAsset.balanceOf(address(this))
    );
  }

  /// @notice buy spot baseAsset with 2/3 of sUSD and short same size on futures with the remaining 1/3 (apx. 2x leverage)
  /// @dev overall position is considered isActive even if liquidated on futures (until spot balance is also sold)
  function openNewPosition() external onlyOwner {
    require(isActive == false, 'only one open position at a time...');
    startingBalance = quoteAsset.balanceOf(address(this));
    require(startingBalance > 0, 'no sUSD in the contract...');
    int futuresMarginSize = int(startingBalance/3);
    uint spotPositionSize = startingBalance - uint(futuresMarginSize);
    isActive = true;
    quoteAsset.approve(address(spotExchange), spotPositionSize);
    baseAssetBalance =
      spotExchange.exchange(
        quoteAssetKey,
        spotPositionSize,
        baseAssetKey
      );
    int shortPositionSize = int(baseAssetBalance) - (int(baseAssetBalance) * 2);
    futuresMarket.transferMargin(futuresMarginSize);
    futuresMarket.modifyPosition(shortPositionSize);
  }

  /// @notice close futures position (unless already liquidated) and sell spot baseAsset back to sUSD
  function closeActivePosition() external onlyOwner {
    require(isActive, 'no position to close...');
    isActive = false;
    (uint openPositionId, , , , ) = futuresMarket.positions(address(this));
    if (openPositionId > 0) {
      futuresMarket.closePosition();
    }
    (uint remaining, ) = futuresMarket.accessibleMargin(address(this));
    if (remaining > 0 ) {
      futuresMarket.withdrawAllMargin();
    }
    baseAsset.approve(address(spotExchange), baseAssetBalance);
    baseAssetBalance = 0;
    spotExchange.exchange(
        baseAssetKey,
        baseAsset.balanceOf(address(this)),
        quoteAssetKey
      );
  }

   /// @notice switch baseAsset and corresponding futuresMarket
  function changeMarket (
    address _baseAsset,
    address _futuresMarket,
    bytes32 _baseAssetKey
    ) external
    onlyOwner {
    require(isActive == false, 'open position must be closed first...');
    baseAsset = IERC20(_baseAsset);
    futuresMarket = IFuturesMarket(_futuresMarket);
    baseAssetKey = _baseAssetKey;
  }

}
