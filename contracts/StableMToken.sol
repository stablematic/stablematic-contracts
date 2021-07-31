// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";


// StableM with Governance.
contract StableMToken is ERC20("StableM Token", "STABLEM"), Ownable {

    uint256 private _cap = 80000000e18; //100M

    function maxSupply() public view returns (uint256) {
      return _cap;
    }

    /// @notice Creates `_amount` token to `_to`. Must only be called by the owner (FairLaunch).
    function mint(address _to, uint256 _amount) public onlyOwner {
        require(totalSupply().add(_amount) <= maxSupply(), "maxSupply exceeded");
        _mint(_to, _amount);
    }


}
