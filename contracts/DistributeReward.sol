// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

contract DistributeReward {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    address public constant owner = 0x3299999a2b0E3d012176a7c722485404dfdfA4aB; // 70%
    address public constant admin = 0xEC4f5134624416eE10DFE0936fbb70669a6c9669; // 5%
    address public constant dev = 0xA911a6D47f5344c43C2d5A0861172cA7cD219841; // 25%
    IERC20 public stableM;

    constructor(address _stableM) public {
        stableM = IERC20(_stableM);
    }

    function distribute() external {
        uint256 balance = IERC20(stableM).balanceOf(address(this));
        uint256 ownerReward = balance.mul(70).div(100);
        uint256 adminReward = balance.mul(5).div(100);
        uint256 devReward =  balance.sub(ownerReward).sub(adminReward);

        stableM.safeTransfer(owner, ownerReward);
        stableM.safeTransfer(admin, adminReward);
        stableM.safeTransfer(dev, devReward);
    }
}
