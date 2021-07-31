// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// inherite
import "./interfaces/IFairLaunch.sol";
import "./StableMToken.sol";

contract FairLaunch is IFairLaunch, Ownable {
  using SafeMath for uint256;
  using SafeERC20 for IERC20;

  // Info of each user.
  struct UserInfo {
    uint256 amount; // How many Staking tokens the user has provided.
    uint256 rewardDebt; // Reward debt. See explanation below.
    uint256 bonusDebt; // Last block that user exec something to the pool.
    address fundedBy; // Funded by who?
    //
    // We do some fancy math here. Basically, any point in time, the amount of StableM
    // entitled to a user but is pending to be distributed is:
    //
    //   pending reward = (user.amount * pool.accStableMPerShare) - user.rewardDebt
    //
    // Whenever a user deposits or withdraws Staking tokens to a pool. Here's what happens:
    //   1. The pool's `accStableMPerShare` (and `lastRewardBlock`) gets updated.
    //   2. User receives the pending reward sent to his/her address.
    //   3. User's `amount` gets updated.
    //   4. User's `rewardDebt` gets updated.
  }

  // Info of each pool.
  struct PoolInfo {
    address stakeToken; // Address of Staking token contract.
    uint256 allocPoint; // How many allocation points assigned to this pool. StableM to distribute per block.
    uint256 lastRewardBlock; // Last block number that StableM distribution occurs.
    uint256 accStableMPerShare; // Accumulated StableM per share, times 1e12. See below.
    uint256 accStableMPerShareTilBonusEnd; // Accumated StableM per share until Bonus End.
  }

  // The StableM TOKEN!
  StableMToken public stableM;
  uint256 public StableMMaxSupply = 80000000e18;
  // Dev address.
  address public devaddr;

  // StableM tokens created per block.
  uint256 public stableMPerBlock;
  // Bonus muliplier for early StableM makers.
  uint256 public bonusMultiplier;
  // Block number when bonus StableM period ends.
  uint256 public bonusEndBlock;
  //limit perBlock
  uint256 public capPerBlock = 6e18;

  // Info of each pool.
  PoolInfo[] public poolInfo;
  // Info of each user that stakes Staking tokens.
  mapping(uint256 => mapping(address => UserInfo)) public userInfo;
  // Total allocation poitns. Must be the sum of all allocation points in all pools.
  uint256 public totalAllocPoint;
  // The block number when StableM mining starts.
  uint256 public startBlock;

  mapping (address => bool) public whitelist;

  event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
  event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
  event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
  event AddWhitelist(address user);
  event RemoveWhitelist(address user);

  constructor(
    StableMToken _stableM,
    uint256 _stableMPerBlock,
    uint256 _startBlock,
    address _devaddr
  ) public {
    bonusMultiplier = 1;
    totalAllocPoint = 0;
    stableM = _stableM;
    stableMPerBlock = _stableMPerBlock;
    bonusEndBlock = 0;
    startBlock = _startBlock;
    devaddr = _devaddr;
  }

  modifier onlyWhitelist() {
        require(whitelist[msg.sender] , "Caller is not in whitelist!");
        _;
  }

  /*
    ########    ###    ########  ##     ##     ######  ######## ######## ######## #### ##    ##  ######
    ##         ## ##   ##     ## ###   ###    ##    ## ##          ##       ##     ##  ###   ## ##    ##
    ##        ##   ##  ##     ## #### ####    ##       ##          ##       ##     ##  ####  ## ##
    ######   ##     ## ########  ## ### ##     ######  ######      ##       ##     ##  ## ## ## ##   ####
    ##       ######### ##   ##   ##     ##          ## ##          ##       ##     ##  ##  #### ##    ##
    ##       ##     ## ##    ##  ##     ##    ##    ## ##          ##       ##     ##  ##   ### ##    ##
    ##       ##     ## ##     ## ##     ##     ######  ########    ##       ##    #### ##    ##  ######
  */

  // Update dev address by the previous dev.
  function setDev(address _devaddr) public onlyOwner {
    devaddr = _devaddr;
  }

  function setCapPerBlock(uint256 _cap) public onlyOwner {
    require(_cap >= stableMPerBlock, "must be over stableMPerBlock!");
    capPerBlock = _cap;
  }

  function setStableMPerBlock(uint256 _stableMPerBlock) public onlyOwner {
    require(_stableMPerBlock <= capPerBlock, "over capPerBlock!");
    stableMPerBlock = _stableMPerBlock;
  }

  //setPerBlock +1% daily onlyWhitelisted
  function setStableMPerBlockDaily() public onlyWhitelist {
    require(stableMPerBlock <= capPerBlock, "over capPerBlock!");
    stableMPerBlock = stableMPerBlock.add(stableMPerBlock.mul(1).div(100));
  }

  function addWhitelist(address _dev) public onlyOwner {
        whitelist[_dev] = true;
        emit AddWhitelist(_dev);
  }

  function removeWhitelist(address _dev) public onlyOwner {
      whitelist[_dev] = false;
      emit RemoveWhitelist(_dev);
  }

  // Set Bonus params. bonus will start to accu on the next block that this function executed
  // See the calculation and counting in test file.
  function setBonus(
    uint256 _bonusMultiplier,
    uint256 _bonusEndBlock
  ) public onlyOwner {
    require(_bonusEndBlock > block.number, "setBonus: bad bonusEndBlock");
    require(_bonusMultiplier >= 1, "setBonus: bad bonusMultiplier");
    bonusMultiplier = _bonusMultiplier;
    bonusEndBlock = _bonusEndBlock;
  }

  function setStartBlock(uint256 _startBlock) public onlyOwner {
    require(startBlock > block.number, "setStartBlock: bad startBlock!");
    require(_startBlock > block.number, "setStartBlock: bad startBlock!");
    startBlock = _startBlock;
  }

  // Add a new lp to the pool. Can only be called by the owner.
  function addPool(
    uint256 _allocPoint,
    address _stakeToken,
    bool _withUpdate
  ) public override onlyOwner {
    if (_withUpdate) {
      massUpdatePools();
    }
    require(_stakeToken != address(0), "add: not stakeToken addr");
    require(!isDuplicatedPool(_stakeToken), "add: stakeToken dup");
    uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
    totalAllocPoint = totalAllocPoint.add(_allocPoint);
    poolInfo.push(
      PoolInfo({
        stakeToken: _stakeToken,
        allocPoint: _allocPoint,
        lastRewardBlock: lastRewardBlock,
        accStableMPerShare: 0,
        accStableMPerShareTilBonusEnd: 0
      })
    );
  }

  // Update the given pool's StableM allocation point. Can only be called by the owner.
  function setPool(
    uint256 _pid,
    uint256 _allocPoint,
    bool _withUpdate
  ) public override onlyOwner {
    if (_withUpdate) {
      massUpdatePools();
    }
    totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(_allocPoint);
    poolInfo[_pid].allocPoint = _allocPoint;
  }

  /*
    ########    ###    ########  ##     ##    ######## ##     ##  ######  ######## ####  #######  ##    ##
    ##         ## ##   ##     ## ###   ###    ##       ##     ## ##    ##    ##     ##  ##     ## ###   ##
    ##        ##   ##  ##     ## #### ####    ##       ##     ## ##          ##     ##  ##     ## ####  ##
    ######   ##     ## ########  ## ### ##    ######   ##     ## ##          ##     ##  ##     ## ## ## ##
    ##       ######### ##   ##   ##     ##    ##       ##     ## ##          ##     ##  ##     ## ##  ####
    ##       ##     ## ##    ##  ##     ##    ##       ##     ## ##    ##    ##     ##  ##     ## ##   ###
    ##       ##     ## ##     ## ##     ##    ##        #######   ######     ##    ####  #######  ##    ##
  */

  function isDuplicatedPool(address _stakeToken) public view returns (bool) {
    uint256 length = poolInfo.length;
    for (uint256 _pid = 0; _pid < length; _pid++) {
      if(poolInfo[_pid].stakeToken == _stakeToken) return true;
    }
    return false;
  }

  function poolLength() external override view returns (uint256) {
    return poolInfo.length;
  }

  // Return reward multiplier over the given _from to _to block.
  function getMultiplier(uint256 _lastRewardBlock, uint256 _currentBlock) public view returns (uint256) {
    if (_currentBlock <= bonusEndBlock) {
      return _currentBlock.sub(_lastRewardBlock).mul(bonusMultiplier);
    }
    if (_lastRewardBlock >= bonusEndBlock) {
      return _currentBlock.sub(_lastRewardBlock);
    }
    // StableM over max supply
    if (stableM.totalSupply() >= StableMMaxSupply) {
      return 0;
    }
    // This is the case where bonusEndBlock is in the middle of _lastRewardBlock and _currentBlock block.
    return bonusEndBlock.sub(_lastRewardBlock).mul(bonusMultiplier).add(_currentBlock.sub(bonusEndBlock));
  }

  // View function to see pending StableM on frontend.
  function pendingStableM(uint256 _pid, address _user) external override view returns (uint256) {
    PoolInfo storage pool = poolInfo[_pid];
    UserInfo storage user = userInfo[_pid][_user];
    uint256 accStableMPerShare = pool.accStableMPerShare;
    uint256 lpSupply = IERC20(pool.stakeToken).balanceOf(address(this));
    if (block.number > pool.lastRewardBlock && lpSupply != 0) {
      uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
      uint256 stableMReward = multiplier.mul(stableMPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
      accStableMPerShare = accStableMPerShare.add(stableMReward.mul(1e12).div(lpSupply));
    }
    return user.amount.mul(accStableMPerShare).div(1e12).sub(user.rewardDebt);
  }

  // Update reward vairables for all pools. Be careful of gas spending!
  function massUpdatePools() public {
    uint256 length = poolInfo.length;
    for (uint256 pid = 0; pid < length; ++pid) {
      updatePool(pid);
    }
  }

  // Update reward variables of the given pool to be up-to-date.
  function updatePool(uint256 _pid) public override {
    PoolInfo storage pool = poolInfo[_pid];
    if (block.number <= pool.lastRewardBlock) {
      return;
    }
    uint256 lpSupply = IERC20(pool.stakeToken).balanceOf(address(this));
    if (lpSupply == 0) {
      pool.lastRewardBlock = block.number;
      return;
    }
    uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
    uint256 stableMReward = multiplier.mul(stableMPerBlock).mul(pool.allocPoint).div(totalAllocPoint);

    stableM.mint(devaddr, stableMReward.mul(10).div(100)); // 10%

    // remainingReward
    uint256 remainingReward = stableMReward.sub(stableMReward.mul(10).div(100));
    stableM.mint(address(this), remainingReward);

    pool.accStableMPerShare = pool.accStableMPerShare.add(remainingReward.mul(1e12).div(lpSupply));

    // update accStableMPerShareTilBonusEnd
    if (block.number <= bonusEndBlock) {
      pool.accStableMPerShareTilBonusEnd = pool.accStableMPerShare;
    }
    if(block.number > bonusEndBlock && pool.lastRewardBlock < bonusEndBlock) {
      uint256 stableMBonusPortion =
      bonusEndBlock.sub(pool.lastRewardBlock).mul(bonusMultiplier).mul(stableMPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
      pool.accStableMPerShareTilBonusEnd = pool.accStableMPerShareTilBonusEnd.add(stableMBonusPortion.mul(1e12).div(lpSupply));
    }
    
    pool.lastRewardBlock = block.number;
  }

  // Deposit Staking tokens to FairLaunchToken for StableM allocation.
  function deposit(uint256 _pid, uint256 _amount) public override {
    PoolInfo storage pool = poolInfo[_pid];
    UserInfo storage user = userInfo[_pid][msg.sender];
    if (user.fundedBy != address(0)) require(user.fundedBy == msg.sender, "bad sof");
    require(pool.stakeToken != address(0), "deposit: not accept deposit");
    updatePool(_pid);
    if (user.amount > 0) _harvest(msg.sender, _pid);
    if (user.fundedBy == address(0)) user.fundedBy = msg.sender;
    IERC20(pool.stakeToken).safeTransferFrom(address(msg.sender), address(this), _amount);
    user.amount = user.amount.add(_amount);
    user.rewardDebt = user.amount.mul(pool.accStableMPerShare).div(1e12);
    user.bonusDebt = user.amount.mul(pool.accStableMPerShareTilBonusEnd).div(1e12);
    emit Deposit(msg.sender, _pid, _amount);
  }

  // Withdraw Staking tokens from FairLaunchToken.
  function withdraw(uint256 _pid, uint256 _amount) public override {
    _withdraw(msg.sender, _pid, _amount);
  }

  function withdrawAll(uint256 _pid) public override {
    _withdraw(msg.sender, _pid, userInfo[_pid][msg.sender].amount);
  }

  function _withdraw(address _for, uint256 _pid, uint256 _amount) internal {
    PoolInfo storage pool = poolInfo[_pid];
    UserInfo storage user = userInfo[_pid][_for];
    require(user.fundedBy == msg.sender, "only funder");
    require(user.amount >= _amount, "withdraw: not good");
    updatePool(_pid);
    _harvest(_for, _pid);
    user.amount = user.amount.sub(_amount);
    user.rewardDebt = user.amount.mul(pool.accStableMPerShare).div(1e12);
    user.bonusDebt = user.amount.mul(pool.accStableMPerShareTilBonusEnd).div(1e12);
    if (pool.stakeToken != address(0)) {
      IERC20(pool.stakeToken).safeTransfer(address(msg.sender), _amount);
    }
    emit Withdraw(msg.sender, _pid, user.amount);
  }

  // Harvest StableM earn from the pool.
  function harvest(uint256 _pid) public override {
    PoolInfo storage pool = poolInfo[_pid];
    UserInfo storage user = userInfo[_pid][msg.sender];
    updatePool(_pid);
    _harvest(msg.sender, _pid);
    user.rewardDebt = user.amount.mul(pool.accStableMPerShare).div(1e12);
    user.bonusDebt = user.amount.mul(pool.accStableMPerShareTilBonusEnd).div(1e12);
  }

  function _harvest(address _to, uint256 _pid) internal {
    PoolInfo storage pool = poolInfo[_pid];
    UserInfo storage user = userInfo[_pid][_to];
    require(user.amount > 0, "nothing to harvest");
    uint256 pending = user.amount.mul(pool.accStableMPerShare).div(1e12).sub(user.rewardDebt);
    require(pending <= stableM.balanceOf(address(this)), "Not enough stableM");
    uint256 bonus = user.amount.mul(pool.accStableMPerShareTilBonusEnd).div(1e12).sub(user.bonusDebt);
    safeStableMTransfer(_to, pending);
    if(bonus > 0){
      safeStableMTransfer(_to, bonus);
    }
  }

  // Withdraw without caring about rewards. EMERGENCY ONLY.
  function emergencyWithdraw(uint256 _pid) public {
    PoolInfo storage pool = poolInfo[_pid];
    UserInfo storage user = userInfo[_pid][msg.sender];
    IERC20(pool.stakeToken).safeTransfer(address(msg.sender), user.amount);
    emit EmergencyWithdraw(msg.sender, _pid, user.amount);
    user.amount = 0;
    user.rewardDebt = 0;
  }

    // Safe StableM transfer function, just in case if rounding error causes pool to not have enough StableM.
  function safeStableMTransfer(address _to, uint256 _amount) internal {
    uint256 stableMBal = stableM.balanceOf(address(this));
    if (_amount > stableMBal) {
      stableM.transfer(_to, stableMBal);
    } else {
      stableM.transfer(_to, _amount);
    }
  }

}
