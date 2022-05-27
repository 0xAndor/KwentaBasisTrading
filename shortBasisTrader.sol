// SPDX-License-Identifier: MIT

pragma solidity 0.8.7;

import "@openzeppelin/contracts/access/Ownable.sol";

/// @title Kwenta Short Basis Trade Manager
/// @author 0xAndor
/// @custom:experimental This is an experimental contract.

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

contract ShortBasisTrader is Ownable {

  ISpotExchange immutable spotExchange;
  IERC20 immutable quoteAsset;
  IExchangeHelper immutable exchangeHelper;

  bytes32 constant quoteAssetKey = 'sUSD';

  bool public isActive;

  IERC20 internal  baseAsset;
  IFuturesMarket internal futuresMarket;
  bytes32 internal baseAssetKey;
  uint internal baseAssetBalance;
  uint internal quoteAssetBalance;
  uint internal startingBalance;

  /// @dev default market is sETH, can switch to other markets by calling changeMarket 
  constructor () {
    quoteAsset = IERC20(0xaA5068dC2B3AADE533d3e52C6eeaadC6a8154c57);
    baseAsset = IERC20(0x94B41091eB29b36003aC1C6f0E55a5225633c884);
    spotExchange = ISpotExchange(0x0064A673267696049938AA47595dD0B3C2e705A1);
    exchangeHelper = IExchangeHelper(0xfff685537fdbD9CA07BD863Ac0b422863BF3114f);
    futuresMarket = IFuturesMarket(0x698E403AaC625345C6E5fC2D0042274350bEDf78);
    baseAssetKey = 'sETH';
  }

  function inActiveBalance() external view returns (uint) {
      return quoteAsset.balanceOf(address(this));
  }
  
  /// @notice returns the estimated value of an open position, does not deduct position closing fees
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
    require(isActive, 'no open position...');
    uint futuresBalance;
    uint baseAssetValue;
    uint estimatedBalance;
    int estimatedPnL;
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
    estimatedPnL = int(estimatedBalance) - int(startingBalance);
    return estimatedPnL;
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

  /// @notice buy spot baseAsset with 50% of sUSD and short same size on futures with the remainder
  /// @dev overall position is still considered isActive when liquidated on futures until spot balance is also sold   
  function openNewPosition() external onlyOwner {
    require(isActive == false, 'only one open position at a time...');
    isActive = true;
    quoteAssetBalance = quoteAsset.balanceOf(address(this));
    startingBalance = quoteAssetBalance;
    uint halfPositionSize = quoteAssetBalance / 2;
    quoteAsset.approve(address(spotExchange), halfPositionSize);
    quoteAssetBalance -= halfPositionSize;
    baseAssetBalance =
      spotExchange.exchange(
        quoteAssetKey,
        halfPositionSize,
        baseAssetKey
      );
    int shortPositionSize = int(baseAssetBalance) - (int(baseAssetBalance) * 2);
    quoteAssetBalance -= halfPositionSize;
    futuresMarket.transferMargin(int(halfPositionSize));
    futuresMarket.modifyPosition(shortPositionSize);
  }

  /// @notice close futures trade (unless already liquidated) and sell spot asset back to sUSD
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
    quoteAssetBalance =
      spotExchange.exchange(
        baseAssetKey,
        baseAsset.balanceOf(address(this)),
        quoteAssetKey
      );
  }

   /// @notice switch baseAsset and corresponding futuresMarket if there is no open position
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
