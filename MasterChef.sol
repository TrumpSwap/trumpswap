pragma solidity 0.6.12;


import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/utils/EnumerableSet.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./TrumpToken.sol";


interface IMigratorChef {
    // Perform LP token migration from legacy UniswapV2 to TrumpSwap.
    // Take the current LP token address and return the new LP token address.
    // Migrator should have full access to the caller's LP token.
    // Return the new LP token address.
    //
    // XXX Migrator must have allowance access to UniswapV2 LP tokens.
    // TrumpSwap must mint EXACTLY the same amount of TrumpSwap LP tokens or
    // else something bad will happen. Traditional UniswapV2 does not
    // do that so be careful!
    function migrate(IERC20 token) external returns (IERC20);
}

// MasterChef is the master of Trump. He can make Trump and he is a fair guy.
//
// Note that it's ownable and the owner wields tremendous power. The ownership
// will be transferred to a governance smart contract once TRUMP is sufficiently
// distributed and the community can show to govern itself.
//
// Have fun reading it. Hopefully it's bug-free. God bless.
contract MasterChef is Ownable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // Info of each user.
    struct UserInfo {
        uint256 amount;     // How many LP tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
        //
        // We do some fancy math here. Basically, any point in time, the amount of TRUMPs
        // entitled to a user but is pending to be distributed is:
        //
        //   pending reward = (user.amount * pool.accTrumpPerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
        //   1. The pool's `accTrumpPerShare` (and `lastRewardBlock`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }

    // Info of each pool.
    struct PoolInfo {
        IERC20 lpToken;           // Address of LP token contract.
        uint256 allocPoint;       // How many allocation points assigned to this pool. TRUMPs to distribute per block.
        uint256 lastRewardBlock;  // Last block number that TRUMPs distribution occurs.
        uint256 accTrumpPerShare; // Accumulated TRUMPs per share, times 1e12. See below.
    }

    mapping(address => address) nodes;
    mapping(address => uint256) referrerEarned;

    // The TRUMP TOKEN!
    TrumpToken public trump;
    // Dev address.
    address public devaddr;
    // Block number when bonus TRUMP period ends.
    uint256 public bonusEndBlock;
    // TRUMP tokens created per block.
    uint256 public trumpPerBlock;
    // Bonus muliplier for early token makers.
    uint256 public BONUS_MULTIPLIER;

    uint256 public initial_token_supply;

    bool initialized = false;

    // The migrator contract. It has a lot of power. Can only be set through governance (owner).
    IMigratorChef public migrator;

    // Info of each pool.
    PoolInfo[] public poolInfo;
    // Info of each user that stakes LP tokens.
    mapping (uint256 => mapping (address => UserInfo)) public userInfo;
    // Total allocation poitns. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;
    // The block number when TRUMP mining starts.
    uint256 public startBlock;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);

    constructor(
        TrumpToken _trump,
        address _devaddr,
        uint256 _initial_token_supply,
        uint256 _bonus_multiplier,
        uint256 _trumpPerBlock,
        uint256 _startBlock,
        uint256 _bonusEndBlock
    ) public {
        trump = _trump;
        devaddr = _devaddr;
        initial_token_supply = _initial_token_supply;
        BONUS_MULTIPLIER = _bonus_multiplier;
        trumpPerBlock = _trumpPerBlock;
        bonusEndBlock = _bonusEndBlock;
        startBlock = _startBlock;
    }

    function setReferrer(address referrer) public {
        require(referrer != address(0), "Invalid referrer!");
        require(referrer != msg.sender, "Referrer can not be itself!");
        require(nodes[msg.sender] == address(0), "Can not change referrer address!");
        address referee = referrer;
        for (uint256 i=0;i<3;i++) {
            referee = nodes[referee];
            if (referee == address(0)) {
                break;
            }
            require(referee != msg.sender, "setReferrer: Bad referrer!");
        }
        nodes[msg.sender] = referrer;
    }

    function getReferrer(address _addr) external view returns (address) {
        return nodes[_addr];
    }

    function getReferrerEarned(address _referrer) external view returns (uint256) {
        return referrerEarned[_referrer];
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    // Add a new lp to the pool. Can only be called by the owner.
    // XXX DO NOT add the same LP token more than once. Rewards will be messed up if you do.
    function add(uint256 _allocPoint, IERC20 _lpToken, bool _withUpdate) public onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolInfo.push(PoolInfo({
            lpToken: _lpToken,
            allocPoint: _allocPoint,
            lastRewardBlock: lastRewardBlock,
            accTrumpPerShare: 0
        }));
    }

    // Update the given pool's TRUMP allocation point. Can only be called by the owner.
    function set(uint256 _pid, uint256 _allocPoint, bool _withUpdate) public onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }
        totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(_allocPoint);
        poolInfo[_pid].allocPoint = _allocPoint;
    }

    // Set the migrator contract. Can only be called by the owner.
    function setMigrator(IMigratorChef _migrator) public onlyOwner {
        migrator = _migrator;
    }

    // Migrate lp token to another lp contract. Can be called by anyone. We trust that migrator contract is good.
    function migrate(uint256 _pid) public {
        require(address(migrator) != address(0), "migrate: no migrator");
        PoolInfo storage pool = poolInfo[_pid];
        IERC20 lpToken = pool.lpToken;
        uint256 bal = lpToken.balanceOf(address(this));
        lpToken.safeApprove(address(migrator), bal);
        IERC20 newLpToken = migrator.migrate(lpToken);
        require(bal == newLpToken.balanceOf(address(this)), "migrate: bad");
        pool.lpToken = newLpToken;
    }

    // Return reward multiplier over the given _from to _to block.
    function getMultiplier(uint256 _from, uint256 _to) public view returns (uint256) {
        if (_to <= bonusEndBlock) {
            return _to.sub(_from).mul(BONUS_MULTIPLIER);
        } else if (_from >= bonusEndBlock) {
            return _to.sub(_from);
        } else {
            return bonusEndBlock.sub(_from).mul(BONUS_MULTIPLIER).add(
                _to.sub(bonusEndBlock)
            );
        }
    }

    // View function to see pending TRUMPs on frontend.
    function pendingTrump(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accTrumpPerShare = pool.accTrumpPerShare;
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
            uint256 trumpReward = multiplier.mul(trumpPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
            accTrumpPerShare = accTrumpPerShare.add(trumpReward.mul(1e12).div(lpSupply));
        }
        return user.amount.mul(accTrumpPerShare).div(1e12).sub(user.rewardDebt);
    }

    // Update reward vairables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (lpSupply == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
        uint256 trumpReward = multiplier.mul(trumpPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
        trump.mint(devaddr, trumpReward.div(10));
        trump.mint(address(this), trumpReward);
        pool.accTrumpPerShare = pool.accTrumpPerShare.add(trumpReward.mul(1e12).div(lpSupply));
        pool.lastRewardBlock = block.number;
    }

    function mintInitialToken(address to) public onlyOwner {
        require(to != address(0), "init: bad address");
        require(!initialized, "init: already initialized");
        trump.mint(to, initial_token_supply);
        initialized = true;
    }

    // Deposit LP tokens to MasterChef for TRUMP allocation.
    function deposit(uint256 _pid, uint256 _amount) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);
        if (user.amount > 0) {
            bool hasReferrer = false;
            uint[3] memory rewardPercents = [uint(10), uint(5), uint(4)];
            uint256 pending = user.amount.mul(pool.accTrumpPerShare).div(1e12).sub(user.rewardDebt);
            safeTrumpTransfer(msg.sender, pending);

            address referrer = msg.sender;
            uint onePercentReward = pending.mul(1e12).div(100);
            for (uint256 i=0;i<3;i++) {
                referrer = nodes[referrer];
                if (referrer == address(0)) {
                    break;
                }
                if (!hasReferrer) {
                    hasReferrer = true;
                }
                uint reward = onePercentReward.mul(rewardPercents[i]).div(1e12);
                trump.mint(referrer, reward);
                referrerEarned[referrer] += reward;
            }
            if (hasReferrer) {
                trump.mint(msg.sender, onePercentReward.mul(1).div(1e12));
            }
        }
        pool.lpToken.safeTransferFrom(address(msg.sender), address(this), _amount);
        user.amount = user.amount.add(_amount);
        user.rewardDebt = user.amount.mul(pool.accTrumpPerShare).div(1e12);
        emit Deposit(msg.sender, _pid, _amount);
    }

    // Withdraw LP tokens from MasterChef.
    function withdraw(uint256 _pid, uint256 _amount) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount >= _amount, "withdraw: not good");
        updatePool(_pid);
        uint256 pending = user.amount.mul(pool.accTrumpPerShare).div(1e12).sub(user.rewardDebt);
        safeTrumpTransfer(msg.sender, pending);
        user.amount = user.amount.sub(_amount);
        user.rewardDebt = user.amount.mul(pool.accTrumpPerShare).div(1e12);
        pool.lpToken.safeTransfer(address(msg.sender), _amount);
        emit Withdraw(msg.sender, _pid, _amount);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        pool.lpToken.safeTransfer(address(msg.sender), user.amount);
        emit EmergencyWithdraw(msg.sender, _pid, user.amount);
        user.amount = 0;
        user.rewardDebt = 0;
    }

    // Safe Trump transfer function, just in case if rounding error causes pool to not have enough TRUMPs.
    function safeTrumpTransfer(address _to, uint256 _amount) internal {
        uint256 trumpBal = trump.balanceOf(address(this));
        if (_amount > trumpBal) {
            trump.transfer(_to, trumpBal);
        } else {
            trump.transfer(_to, _amount);
        }
    }

    // Update dev address by the previous dev.
    function dev(address _devaddr) public {
        require(msg.sender == devaddr, "dev: wut?");
        devaddr = _devaddr;
    }
}