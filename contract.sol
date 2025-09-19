// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/*
  Full ZStakingPoolV3 + ZStakingFactoryV3 (self-contained)

  - Keeps previous features: ZPR formula, bond, activation split, per-user 60-min updates
  - Fix: initialize pattern matching V2 (protect impl with constructor and require(!initialized))
*/

import "@openzeppelin/contracts/proxy/Clones.sol";

/// -------------------------------------------------------------------------
/// Minimal IERC20 interface
/// -------------------------------------------------------------------------
interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// -------------------------------------------------------------------------
/// SafeERC20 (minimal)
/// -------------------------------------------------------------------------
library SafeERC20 {
    function _callOptionalReturn(IERC20 token, bytes memory data) private {
        (bool success, bytes memory ret) = address(token).call(data);
        require(success, "SafeERC20: low-level call failed");
        if (ret.length > 0) {
            require(abi.decode(ret, (bool)), "SafeERC20: ERC20 op failed");
        }
    }
    function safeTransfer(IERC20 token, address to, uint256 value) internal {
        bytes memory data = abi.encodeWithSelector(token.transfer.selector, to, value);
        _callOptionalReturn(token, data);
    }
    function safeTransferFrom(IERC20 token, address from, address to, uint256 value) internal {
        bytes memory data = abi.encodeWithSelector(token.transferFrom.selector, from, to, value);
        _callOptionalReturn(token, data);
    }
    function safeApprove(IERC20 token, address spender, uint256 value) internal {
        bytes memory data = abi.encodeWithSelector(token.approve.selector, spender, value);
        _callOptionalReturn(token, data);
    }
}

/// -------------------------------------------------------------------------
/// ReentrancyGuard (clone-friendly)
/// -------------------------------------------------------------------------
abstract contract ReentrancyGuard {
    uint256 internal _status;
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    constructor() { _status = _NOT_ENTERED; }
    function _initReentrancyGuard() internal { _status = _NOT_ENTERED; }
    modifier nonReentrant() {
        require(_status == _NOT_ENTERED, "Reentrant");
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }
}

/// -------------------------------------------------------------------------
/// Ownable (manual)
/// -------------------------------------------------------------------------
contract Ownable {
    address public owner;
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    constructor() {
        owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);
    }
    modifier onlyOwner() {
        require(msg.sender == owner, "Ownable: not owner");
        _;
    }
    function _setOwner(address newOwner) internal {
        require(newOwner != address(0), "Ownable: zero owner");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }
    function transferOwnership(address newOwner) external onlyOwner {
        _setOwner(newOwner);
    }
}

/// -------------------------------------------------------------------------
/// Interface for pool (factory uses this)
/// -------------------------------------------------------------------------
interface IStakingPool {
    function owner() external view returns (address);
    function stakingToken() external view returns (address);
    function rewardToken() external view returns (address);
    function onActivation(uint256 bondProvided, uint256 rewardProvided) external;
}

/// -------------------------------------------------------------------------
/// ZStakingPoolV3
/// -------------------------------------------------------------------------
contract ZStakingPoolV3 is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    bool public initialized;

    IERC20 public stakingToken;
    IERC20 public rewardToken;

    address public factory;

    uint256 public lockDuration;
    uint256 public stakingRatioK;
    uint256 public bondAmount;
    bool public active;

    uint256 public totalRewards;
    uint256 public distributed;
    uint256 public totalStaked;

    struct UserInfo {
        uint256 amount;
        uint256 rewardDebt;
        uint256 lastUpdate;
        uint256 unlockTime;
    }
    mapping(address => UserInfo) public users;

    event Initialized(address indexed stakingToken, address indexed rewardToken, uint256 lockDuration, uint256 stakingRatioK, address factory, address owner);
    event Activated(uint256 bondProvided, uint256 rewardProvided);
    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 principal, uint256 reward);
    event RewardAdded(uint256 amount);
    event UserRewardUpdated(address indexed user, uint256 addedReward);
    event BondUpdated(uint256 newBond);
    event ForceDeactivate();
    event RewardPaid(address indexed user, uint256 reward);

    uint256 public constant UPDATE_INTERVAL = 60 minutes;
    uint256 public constant K_SCALE = 1e18;

    modifier onlyFactory() {
        require(msg.sender == factory, "Only factory");
        _;
    }
    modifier onlyActive() {
        require(active, "Pool not active");
        _;
    }

    constructor() { initialized = true; }

    function initialize(
        address _stakingToken,
        address _rewardToken,
        uint256 _lockDuration,
        uint256 _stakingRatioK,
        address _owner,
        address _factory
    ) external {
        require(!initialized, "Already initialized");
        require(_factory != address(0), "Zero factory");
        require(_stakingToken != address(0) && _rewardToken != address(0), "Zero token");
        require(_owner != address(0), "Zero owner");
        require(_stakingRatioK > 0, "k>0");

        _initReentrancyGuard();

        stakingToken = IERC20(_stakingToken);
        rewardToken = IERC20(_rewardToken);
        lockDuration = _lockDuration;
        stakingRatioK = _stakingRatioK;
        factory = _factory;

        _setOwner(_owner);

        active = false;
        totalRewards = 0;
        distributed = 0;
        bondAmount = 0;
        totalStaked = 0;

        initialized = true;

        emit Initialized(_stakingToken, _rewardToken, _lockDuration, _stakingRatioK, _factory, _owner);
    }

    function onActivation(uint256 bondProvided, uint256 rewardProvided) external onlyFactory {
        require(!active, "Already active");
        require(bondProvided > 0 && rewardProvided > 0, "Invalid activation amounts");
        require(address(stakingToken) == address(rewardToken), "Activation requires same token");

        bondAmount += bondProvided;
        totalRewards += rewardProvided;
        active = true;

        emit BondUpdated(bondAmount);
        emit Activated(bondProvided, rewardProvided);
    }

    function currentZPR() public view returns (uint256) {
        uint256 base = bondAmount + totalStaked;
        if (base == 0) return 0;
        if (totalRewards <= distributed) return 0;
        uint256 numerator = (totalRewards - distributed) * 1e18;
        uint256 denominator = (stakingRatioK * base) / K_SCALE;
        if (denominator == 0) return 0;
        return numerator / denominator;
    }

    modifier updateUser(address account) {
        UserInfo storage u = users[account];
        if (u.amount > 0) {
            if (u.lastUpdate == 0) {
                u.lastUpdate = block.timestamp;
            } else if (block.timestamp >= u.lastUpdate + UPDATE_INTERVAL) {
                uint256 timeElapsed = block.timestamp - u.lastUpdate;
                uint256 zpr = currentZPR();
                uint256 reward = (u.amount * zpr * timeElapsed) / K_SCALE;
                uint256 remaining = totalRewards > distributed ? totalRewards - distributed : 0;
                if (reward > remaining) reward = remaining;
                if (reward > 0) {
                    u.rewardDebt += reward;
                    distributed += reward;
                    emit UserRewardUpdated(account, reward);
                }
                u.lastUpdate = block.timestamp;
            }
        }
        _;
    }

    function stake(uint256 amount) external nonReentrant onlyActive updateUser(msg.sender) {
        require(amount > 0, "Zero amount");
        uint256 beforeBal = stakingToken.balanceOf(address(this));
        SafeERC20.safeTransferFrom(stakingToken, msg.sender, address(this), amount);
        uint256 afterBal = stakingToken.balanceOf(address(this));
        uint256 received = afterBal - beforeBal;
        require(received > 0, "Transfer failed");

        UserInfo storage u = users[msg.sender];
        u.amount += received;
        u.unlockTime = block.timestamp + lockDuration;
        if (u.lastUpdate == 0) u.lastUpdate = block.timestamp;
        totalStaked += received;

        emit Staked(msg.sender, received);
    }

    function withdraw() external nonReentrant onlyActive updateUser(msg.sender) {
        UserInfo storage u = users[msg.sender];
        require(u.amount > 0, "No stake");
        require(block.timestamp >= u.unlockTime, "Still locked");

        uint256 principal = u.amount;
        uint256 reward = u.rewardDebt;

        u.amount = 0;
        u.rewardDebt = 0;
        u.lastUpdate = 0;
        u.unlockTime = 0;
        totalStaked -= principal;

        if (principal > 0) SafeERC20.safeTransfer(stakingToken, msg.sender, principal);
        if (reward > 0) {
            SafeERC20.safeTransfer(rewardToken, msg.sender, reward);
            emit RewardPaid(msg.sender, reward);
        }
        emit Withdrawn(msg.sender, principal, reward);
    }

    function addReward(uint256 amount) external nonReentrant onlyOwner {
        require(amount > 0, "Zero");
        uint256 beforeBal = rewardToken.balanceOf(address(this));
        SafeERC20.safeTransferFrom(rewardToken, msg.sender, address(this), amount);
        uint256 afterBal = rewardToken.balanceOf(address(this));
        uint256 received = afterBal - beforeBal;
        require(received > 0, "No tokens received");
        totalRewards += received;
        emit RewardAdded(received);
    }

    function pendingReward(address user) external view returns (uint256) {
        UserInfo memory u = users[user];
        uint256 pending = u.rewardDebt;
        if (u.amount > 0 && u.lastUpdate > 0 && block.timestamp >= u.lastUpdate + UPDATE_INTERVAL) {
            uint256 timeElapsed = block.timestamp - u.lastUpdate;
            uint256 zpr = currentZPR();
            uint256 extra = (u.amount * zpr * timeElapsed) / K_SCALE;
            uint256 remaining = totalRewards > distributed ? totalRewards - distributed : 0;
            if (extra > remaining) extra = remaining;
            pending += extra;
        }
        return pending;
    }

    function remainingRewards() external view returns (uint256) {
        if (totalRewards <= distributed) return 0;
        return totalRewards - distributed;
    }

    function setBond(uint256 newBond) external {
        require(msg.sender == owner || msg.sender == factory, "Not authorized");
        bondAmount = newBond;
        emit BondUpdated(newBond);
    }

    function forceDeactivate() external onlyOwner {
        active = false;
        emit ForceDeactivate();
    }
}

/// -------------------------------------------------------------------------
/// ZStakingFactoryV3
/// -------------------------------------------------------------------------
contract ZStakingFactoryV3 is Ownable {
    using Clones for address;

    address public implementation;
    address public treasury;
    uint256 public defaultActivationFee;

    mapping(address => uint256) public poolActivationFee;
    address[] public allPools;

    event PoolCreated(address indexed pool, address indexed stakingToken, address indexed rewardToken, address owner);
    event ActivatedPool(address indexed pool, address indexed caller, uint256 fee, uint256 bond, uint256 reward, uint256 treasuryShare);
    event TreasuryUpdated(address indexed newTreasury);
    event ImplementationUpdated(address indexed newImpl);

    constructor(address _implementation, address _treasury, uint256 _defaultActivationFee) {
        require(_implementation != address(0), "Zero implementation");
        require(_treasury != address(0), "Zero treasury");
        implementation = _implementation;
        treasury = _treasury;
        defaultActivationFee = _defaultActivationFee;
    }

    function createPool(
        address stakingToken,
        address rewardToken,
        uint256 lockDuration,
        uint256 stakingRatioK,
        address poolOwner,
        uint256 activationFee
    ) external onlyOwner returns (address pool) {
        require(poolOwner != address(0), "Zero pool owner");
        address impl = implementation;
        require(impl != address(0), "No implementation");
        pool = impl.clone();

        ZStakingPoolV3(pool).initialize(stakingToken, rewardToken, lockDuration, stakingRatioK, poolOwner, address(this));

        poolActivationFee[pool] = activationFee == 0 ? defaultActivationFee : activationFee;
        allPools.push(pool);
        emit PoolCreated(pool, stakingToken, rewardToken, poolOwner);
    }

    struct FeeSplit { uint256 bond; uint256 reward; uint256 treas; }

    function _getPoolOwner(address pool) internal view returns (address) {
        return IStakingPool(pool).owner();
    }
    function _getStakingTokenAddr(address pool) internal view returns (address) {
        return IStakingPool(pool).stakingToken();
    }
    function _getRewardTokenAddr(address pool) internal view returns (address) {
        return IStakingPool(pool).rewardToken();
    }

    function _transferFeeToFactory(IERC20 token, address payer, uint256 fee) internal {
        SafeERC20.safeTransferFrom(token, payer, address(this), fee);
    }

    function _splitFee(uint256 fee) internal pure returns (FeeSplit memory s) {
        s.bond = (fee * 45) / 100;
        s.reward = (fee * 45) / 100;
        s.treas = fee - s.bond - s.reward;
    }

    function _sendToTreasury(IERC20 token, uint256 amount) internal {
        if (amount > 0) {
            SafeERC20.safeTransfer(token, treasury, amount);
        }
    }

    function _sendToPool(IERC20 token, address pool, uint256 amount) internal {
        if (amount > 0) {
            SafeERC20.safeTransfer(token, pool, amount);
        }
    }

    function _callOnActivation(address pool, uint256 bond, uint256 reward) internal {
        IStakingPool(pool).onActivation(bond, reward);
    }

    function activatePool(address pool) external {
        require(pool != address(0), "Zero pool");
        uint256 fee = poolActivationFee[pool];
        require(fee > 0, "Activation fee not set");

        address poolOwner = _getPoolOwner(pool);
        require(msg.sender == poolOwner, "Not pool owner");

        address stakingTokenAddr = _getStakingTokenAddr(pool);
        address rewardTokenAddr = _getRewardTokenAddr(pool);
        require(stakingTokenAddr == rewardTokenAddr, "Token mismatch; swap not implemented");

        IERC20 stakingT = IERC20(stakingTokenAddr);

        _transferFeeToFactory(stakingT, msg.sender, fee);

        FeeSplit memory s = _splitFee(fee);

        _sendToTreasury(stakingT, s.treas);
        _sendToPool(stakingT, pool, s.bond);
        _sendToPool(stakingT, pool, s.reward);

        _callOnActivation(pool, s.bond, s.reward);

        emit ActivatedPool(pool, msg.sender, fee, s.bond, s.reward, s.treas);
    }

    function setDefaultActivationFee(uint256 fee) external onlyOwner {
        defaultActivationFee = fee;
    }
    function setPoolActivationFee(address pool, uint256 fee) external onlyOwner {
        poolActivationFee[pool] = fee;
    }
    function setTreasury(address _treasury) external onlyOwner {
        require(_treasury != address(0), "Zero treasury");
        treasury = _treasury;
        emit TreasuryUpdated(_treasury);
    }
    function setImplementation(address impl) external onlyOwner {
        require(impl != address(0), "Zero impl");
        implementation = impl;
        emit ImplementationUpdated(impl);
    }

    function allPoolsLength() external view returns (uint256) {
        return allPools.length;
    }

    function withdrawFactoryToken(address token) external onlyOwner {
        IERC20 t = IERC20(token);
        uint256 bal = t.balanceOf(address(this));
        require(bal > 0, "No balance");
        SafeERC20.safeTransfer(t, treasury, bal);
    }
}
