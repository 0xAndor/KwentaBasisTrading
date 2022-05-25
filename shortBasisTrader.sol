// SPDX-License-Identifier: MIT

pragma solidity 0.8.7;

import "@openzeppelin/contracts/access/Ownable.sol";

interface ISpotExchange {
    function exchange(
      bytes32 sourceCurrencyKey,
      uint256 sourceAmount,
      bytes32 destinationCurrencyKey
    ) external;
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

contract shortBasisTrader is Ownable {

  ISpotExchange spotExchange;
  IERC20 quoteAsset;
  IERC20 baseAsset;
  IFuturesMarket futuresMarket;
  IExchangeHelper exchangeHelper;

  bytes32 quoteAssetKey;
  bytes32 baseAssetKey;

  bool public isActive;

  constructor (
    address _baseAsset,
    address _futuresMarket,
    bytes32 _baseAssetKey
    ) {
    spotExchange = ISpotExchange(0x0064A673267696049938AA47595dD0B3C2e705A1);
    quoteAsset = IERC20(0xaA5068dC2B3AADE533d3e52C6eeaadC6a8154c57);
    exchangeHelper = IExchangeHelper(0xfff685537fdbD9CA07BD863Ac0b422863BF3114f);
    baseAsset = IERC20(_baseAsset);
    futuresMarket = IFuturesMarket(_futuresMarket);
    baseAssetKey = _baseAssetKey;
    quoteAssetKey = 0x7355534400000000000000000000000000000000000000000000000000000000;
  }

  function deposit(uint _amountToDeposit) external {
    quoteAsset.transferFrom(msg.sender, address(this), _amountToDeposit);
  }

  function start() external onlyOwner {
    uint balanceQuoteAsset = quoteAsset.balanceOf(address(this));
    uint spotSize = balanceQuoteAsset / 2;
    quoteAsset.approve(address(spotExchange), spotSize);
    spotExchange.exchange(
      quoteAssetKey,
      spotSize,
      baseAssetKey
    );
    int remainingQuoteAsset = int(quoteAsset.balanceOf(address(this)));
    futuresMarket.transferMargin(remainingQuoteAsset);
    int baseAssetBalance = int(baseAsset.balanceOf(address(this)));
    int futuresSize = baseAssetBalance - (baseAssetBalance * 2);
    futuresMarket.modifyPosition(futuresSize);
    isActive = true;
  }

  function stop() external onlyOwner {
    (uint openPositionId, , , , ) = futuresMarket.positions(address(this));
    if (openPositionId > 0) {
      futuresMarket.closePosition();
    }
    (uint remaining, ) = futuresMarket.accessibleMargin(address(this));
    if (remaining > 0 ) {
      futuresMarket.withdrawAllMargin();
    }
    uint balanceBaseAsset = baseAsset.balanceOf(address(this));
    baseAsset.approve(address(spotExchange), balanceBaseAsset);
    spotExchange.exchange(
      baseAssetKey,
      balanceBaseAsset,
      quoteAssetKey
    );
    isActive = false;
  }

  function withdraw() external onlyOwner {
    require(isActive == false, 'position is still open...');
    uint balanceQuoteAsset = quoteAsset.balanceOf(address(this));
    quoteAsset.transfer(
      owner,
      balanceQuoteAsset
    );
  }

  function currentBalance() external view returns (uint) {
    uint futuresBalance;
    uint baseBalance;
    uint quoteBalance;
    (uint openPositionId, , , , ) = futuresMarket.positions(address(this));
    if (openPositionId > 0) {
      (uint futuresMarginRemaining, ) = futuresMarket.remainingMargin(address(this));
      futuresBalance = futuresMarginRemaining;
    } 
    if (baseAsset.balanceOf(address(this)) > 0) {
      (uint spotBalanceValue, , ) = 
      exchangeHelper.getAmountsForExchange(
        baseAsset.balanceOf(address(this)),
        baseAssetKey,
        quoteAssetKey
      );
      baseBalance = spotBalanceValue;
    } 
    if (quoteAsset.balanceOf(address(this)) > 0) {
      uint quoteBalanceValue = quoteAsset.balanceOf(address(this));
      quoteBalance = quoteBalanceValue;
    }
    uint currentEstimatedBalance = 
      futuresBalance + baseBalance + quoteBalance;
    return currentEstimatedBalance;
  }

}
