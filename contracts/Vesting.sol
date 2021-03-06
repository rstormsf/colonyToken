/*
  This file is part of The Colony Network.

  The Colony Network is free software: you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation, either version 3 of the License, or
  (at your option) any later version.

  The Colony Network is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with The Colony Network. If not, see <http://www.gnu.org/licenses/>.
*/

pragma solidity ^0.4.23;
pragma experimental "v0.5.0";

import "./Token.sol";
import "../lib/dappsys/math.sol";
import "../lib/dappsys/erc20.sol";


contract Vesting is DSMath {
  Token public token;
  address public colonyMultiSig;

  uint constant internal SECONDS_PER_MONTH = 2628000;

  event GrantAdded(address recipient, uint256 startTime, uint128 amount, uint16 vestingDuration, uint16 vestingCliff);
  event GrantRemoved(address recipient, uint128 amountVested, uint128 amountNotVested);
  event GrantTokensClaimed(address recipient, uint128 amountClaimed);

  struct Grant {
    uint startTime;
    uint128 amount;
    uint16 vestingDuration;
    uint16 vestingCliff;
    uint16 monthsClaimed;
    uint128 totalClaimed;
  }
  mapping (address => Grant) public tokenGrants;

  modifier onlyColonyMultiSig {
    require(msg.sender == colonyMultiSig);
    _;
  }

  modifier nonZeroAddress(address x) {
    require(x != 0);
    _;
  }

  modifier noGrantExistsForUser(address _user) {
    require(tokenGrants[_user].startTime == 0);
    _;
  }

  constructor(address _token, address _colonyMultiSig) public
  nonZeroAddress(_token)
  nonZeroAddress(_colonyMultiSig)
  {
    token = Token(_token);
    colonyMultiSig = _colonyMultiSig;
  }

  /// @notice Add a new token grant for user `_recipient`. Only one grant per user is allowed
  /// The amount of CLNY tokens here need to be preapproved for transfer by this `Vesting` contract before this call
  /// Secured to the Colony MultiSig only
  /// @param _recipient Address of the token grant recipient entitled to claim the grant funds
  /// @param _startTime Grant start time as seconds since unix epoch
  /// Allows backdating grants by passing time in the past. If `0` is passed here current blocktime is used. 
  /// @param _amount Total number of tokens in grant
  /// @param _vestingDuration Number of months of the grant's duration
  /// @param _vestingCliff Number of months of the grant's vesting cliff
  function addTokenGrant(address _recipient, uint256 _startTime, uint128 _amount, uint16 _vestingDuration, uint16 _vestingCliff) public 
  onlyColonyMultiSig
  noGrantExistsForUser(_recipient)
  {
    require(_vestingCliff > 0);
    require(_vestingDuration > _vestingCliff);
    uint amountVestedPerMonth = _amount / _vestingDuration;
    require(amountVestedPerMonth > 0);

    // Transfer the grant tokens under the control of the vesting contract
    token.transferFrom(colonyMultiSig, address(this), _amount);

    Grant memory grant = Grant({
      startTime: _startTime == 0 ? now : _startTime,
      amount: _amount,
      vestingDuration: _vestingDuration,
      vestingCliff: _vestingCliff,
      monthsClaimed: 0,
      totalClaimed: 0
    });

    tokenGrants[_recipient] = grant;
    emit GrantAdded(_recipient, grant.startTime, _amount, _vestingDuration, _vestingCliff);
  }

  /// @notice Terminate token grant transferring all vested tokens to the `_recipient`
  /// and returning all non-vested tokens to the Colony MultiSig
  /// Secured to the Colony MultiSig only
  /// @param _recipient Address of the token grant recipient
  function removeTokenGrant(address _recipient) public 
  onlyColonyMultiSig
  {
    Grant storage tokenGrant = tokenGrants[_recipient];
    uint16 monthsVested;
    uint128 amountVested;
    (monthsVested, amountVested) = calculateGrantClaim(_recipient);
    uint128 amountNotVested = uint128(sub(sub(tokenGrant.amount, tokenGrant.totalClaimed), amountVested));

    require(token.transfer(_recipient, amountVested));
    require(token.transfer(colonyMultiSig, amountNotVested));

    tokenGrant.startTime = 0;
    tokenGrant.amount = 0;
    tokenGrant.vestingDuration = 0;
    tokenGrant.vestingCliff = 0;
    tokenGrant.monthsClaimed = 0;
    tokenGrant.totalClaimed = 0;

    emit GrantRemoved(_recipient, amountVested, amountNotVested);
  }

  /// @notice Allows a grant recipient to claim their vested tokens. Errors if no tokens have vested
  /// It is advised recipients check they are entitled to claim via `calculateGrantClaim` before calling this
  function claimVestedTokens() public {
    uint16 monthsVested;
    uint128 amountVested;
    (monthsVested, amountVested) = calculateGrantClaim(msg.sender);
    require(amountVested > 0);

    Grant storage tokenGrant = tokenGrants[msg.sender];
    tokenGrant.monthsClaimed = uint16(add(tokenGrant.monthsClaimed, monthsVested));
    tokenGrant.totalClaimed = uint128(add(tokenGrant.totalClaimed, amountVested));
    
    require(token.transfer(msg.sender, amountVested));
    emit GrantTokensClaimed(msg.sender, amountVested);
  }

  /// @notice Calculate the vested and unclaimed months and tokens available for `_recepient` to claim
  /// Due to rounding errors once grant duration is reached, returns the entire left grant amount
  /// Returns (0, 0) if cliff has not been reached
  function calculateGrantClaim(address _recipient) public view returns (uint16, uint128) {
    Grant storage tokenGrant = tokenGrants[_recipient];

    // Check cliff was reached
    uint elapsedTime = sub(now, tokenGrant.startTime);
    uint elapsedMonths = elapsedTime / SECONDS_PER_MONTH;
    
    if (elapsedMonths < tokenGrant.vestingCliff) {
      return (0, 0);
    }

    // If over vesting duration, all tokens vested
    if (elapsedMonths >= tokenGrant.vestingDuration) {
      uint128 remainingGrant = tokenGrant.amount - tokenGrant.totalClaimed;
      return (tokenGrant.vestingDuration, remainingGrant);
    } else {
      uint16 monthsVested = uint16(sub(elapsedMonths, tokenGrant.monthsClaimed));
      uint amountVestedPerMonth = tokenGrant.amount / tokenGrant.vestingDuration;
      uint128 amountVested = uint128(mul(monthsVested, amountVestedPerMonth));
      return (monthsVested, amountVested);
    }
  }
}
