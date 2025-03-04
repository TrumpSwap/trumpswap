pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";


contract TrumpBar is ERC20("TrumpBar", "xTRUMP"){
    using SafeMath for uint256;
    IERC20 public trump;

    constructor(IERC20 _trump) public {
        trump = _trump;
    }

    // Enter the bar. Pay some Trumps. Earn some shares.
    function enter(uint256 _amount) public {
        uint256 totalToken = trump.balanceOf(address(this));
        uint256 totalShares = totalSupply();
        if (totalShares == 0 || totalToken == 0) {
            _mint(msg.sender, _amount);
        } else {
            uint256 what = _amount.mul(totalShares).div(totalToken);
            _mint(msg.sender, what);
        }
        trump.transferFrom(msg.sender, address(this), _amount);
    }

    // Leave the bar. Claim back your Tokens.
    function leave(uint256 _share) public {
        uint256 totalShares = totalSupply();
        uint256 what = _share.mul(trump.balanceOf(address(this))).div(totalShares);
        _burn(msg.sender, _share);
        trump.transfer(msg.sender, what);
    }
}