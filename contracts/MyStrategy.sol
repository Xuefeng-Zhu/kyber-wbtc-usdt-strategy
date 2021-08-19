// SPDX-License-Identifier: MIT

pragma solidity ^0.6.11;
pragma experimental ABIEncoderV2;

import "../deps/@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "../deps/@openzeppelin/contracts-upgradeable/math/SafeMathUpgradeable.sol";
import "../deps/@openzeppelin/contracts-upgradeable/math/MathUpgradeable.sol";
import "../deps/@openzeppelin/contracts-upgradeable/utils/AddressUpgradeable.sol";
import "../deps/@openzeppelin/contracts-upgradeable/token/ERC20/SafeERC20Upgradeable.sol";

import "../interfaces/badger/IController.sol";
import "../interfaces/kyber/kyber.sol";
import "../interfaces/kyber/IKyberFairLaunch.sol";

import {BaseStrategy} from "../deps/BaseStrategy.sol";

contract StrategyKyberBadgerWBtcUsdt is BaseStrategy {
    using SafeERC20Upgradeable for IERC20Upgradeable;
    using AddressUpgradeable for address;
    using SafeMathUpgradeable for uint256;

    // address public want // Inherited from BaseStrategy, the token the strategy wants, swaps into and tries to grow
    // we provide liquidity with want
    address public reward; // Token we farm and swap to want / lpComponent

    address public constant STAKING_REWARDS =
        0x31de05f28568e3d3d612bfa6a78b356676367470;
    address public constant KYBER_ROUTER =
        0x1c87257f5e8609940bc751a07bb085bb7f8cdbe6;

    address public constant wbtc = 0x1BFD67037B42Cf73acF2047067bd4F2C47D9BfD6;
    address public constant usdt = 0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174;
    address public constant weth = 0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619;

    uint256 public slippage;
    uint256 public constant MAX_BPS = 10000;

    function initialize(
        address _governance,
        address _strategist,
        address _controller,
        address _keeper,
        address _guardian,
        address[2] memory _wantConfig,
        uint256[3] memory _feeConfig
    ) public initializer {
        __BaseStrategy_init(
            _governance,
            _strategist,
            _controller,
            _keeper,
            _guardian
        );

        /// @dev Add config here
        want = _wantConfig[0];
        reward = _wantConfig[1];

        performanceFeeGovernance = _feeConfig[0];
        performanceFeeStrategist = _feeConfig[1];
        withdrawalFee = _feeConfig[2];

        // Set the default slippage tolerance to 5% (divide by MAX_BPS)
        slippage = 50;

        /// @dev do one off approvals here
        IERC20Upgradeable(want).safeApprove(STAKING_REWARDS, type(uint256).max);

        IERC20Upgradeable(reward).safeApprove(KYBER_ROUTER, type(uint256).max);
    }

    /// ===== View Functions =====

    // @dev Specify the name of the strategy
    function getName() external pure override returns (string memory) {
        return "StrategyKyberBadgerWBtcUsdt";
    }

    // @dev Specify the version of the Strategy, for upgrades
    function version() external pure returns (string memory) {
        return "1.0";
    }

    /// @dev Balance of want currently held in strategy positions
    function balanceOfPool() public view override returns (uint256) {
        return IKyberFairLaunch(STAKING_REWARDS).balanceOf(address(this));
    }

    function balanceOfToken(address _token) public view returns (uint256) {
        return IERC20Upgradeable(_token).balanceOf(address(this));
    }

    /// @dev Returns true if this strategy requires tending
    function isTendable() public view override returns (bool) {
        return true;
    }

    // @dev These are the tokens that cannot be moved except by the vault
    function getProtectedTokens()
        public
        view
        override
        returns (address[] memory)
    {
        address[] memory protectedTokens = new address[](4);
        protectedTokens[0] = want;
        protectedTokens[1] = reward;
        protectedTokens[2] = STAKING_REWARDS;
        protectedTokens[3] = weth;
        return protectedTokens;
    }

    /// ===== Permissioned Actions: Governance =====
    /// @notice Delete if you don't need!
    function setKeepReward(uint256 _setKeepReward) external {
        _onlyGovernance();
    }

    /// ===== Internal Core Implementations =====

    /// @dev security check to avoid moving tokens that would cause a rugpull, edit based on strat
    function _onlyNotProtectedTokens(address _asset) internal override {
        address[] memory protectedTokens = getProtectedTokens();

        for (uint256 x = 0; x < protectedTokens.length; x++) {
            require(
                address(protectedTokens[x]) != _asset,
                "Asset is protected"
            );
        }
    }

    /// @dev invest the amount of want
    /// @notice When this function is called, the controller has already sent want to this
    /// @notice Just get the current balance and then invest accordingly
    /// @notice stake the want tokens in the LP pool
    function _deposit(uint256 _amount) internal override {
        IKyberFairLaunch(STAKING_REWARDS).deposit(1, _amount, false);
    }

    /// @dev utility function to withdraw everything for migration
    function _withdrawAll() internal override {
        uint256 _totalWant = balanceOfPool();
        if (_totalWant > 0) {
            _withdrawSome(_totalWant);
        }
    }

    /// @dev withdraw the specified amount of want, liquidate from lpComponent to want, paying off any necessary debt for the conversion
    function _withdrawSome(uint256 _amount)
        internal
        override
        returns (uint256)
    {
        uint256 _totalWant = balanceOfPool();
        if (_amount > _totalWant) {
            _amount = _totalWant;
        }
        IKyberFairLaunch(STAKING_REWARDS).withdraw(1, _amount);
        return _amount;
    }

    /// @notice check unclaimed kyber rewards
    function checkPendingReward() public view returns (uint256) {
        return
            IKyberFairLaunch(STAKING_REWARDS).pendingRewards(1, address(this))[
                0
            ];
    }

    /// @dev Harvest from strategy mechanics, realizing increase in underlying position
    function harvest() external whenNotPaused returns (uint256 harvested) {
        _onlyAuthorizedActors();

        uint256 _before = IERC20Upgradeable(want).balanceOf(address(this));

        uint256 _reward = checkPendingReward();

        if (_reward == 0) {
            return 0;
        }

        // take out reward kyber tokens
        IKyberFairLaunch(STAKING_REWARDS).harvest(1);

        // exchange kyber tokens for WBTC-USDC tokens
        _kncToLP();

        uint256 earned =
            IERC20Upgradeable(want).balanceOf(address(this)).sub(_before);

        /// @notice Keep this in so you get paid!
        (uint256 governancePerformanceFee, uint256 strategistPerformanceFee) =
            _processPerformanceFees(earned);

        /// @dev Harvest event that every strategy MUST have, see BaseStrategy
        emit Harvest(earned, block.number);

        return earned;
    }

    /// @dev Rebalance, Compound or Pay off debt here
    function tend() external whenNotPaused {
        _onlyAuthorizedActors();
        // restake want into the rewards contract
        uint256 _want = balanceOfWant();
        if (_want > 0) {
            _deposit(_want);
        }
    }

    /// ===== Internal Helper Functions =====

    /// @dev used to manage the governance and strategist fee, make sure to use it to get paid!
    function _processPerformanceFees(uint256 _amount)
        internal
        returns (
            uint256 governancePerformanceFee,
            uint256 strategistPerformanceFee
        )
    {
        governancePerformanceFee = _processFee(
            want,
            _amount,
            performanceFeeGovernance,
            IController(controller).rewards()
        );

        strategistPerformanceFee = _processFee(
            want,
            _amount,
            performanceFeeStrategist,
            strategist
        );
    }

    /// @dev KNC TO WBTC-USDC LP
    function _kncToLP() internal {
        uint256 _tokens = balanceOfToken(reward);
        uint256 _half = _tokens.mul(5000).div(MAX_BPS);

        // kyber to weth to wbtc
        address[] memory path = new address[](3);
        path[0] = reward;
        path[1] = weth;
        path[2] = wbtc;
        kyber(KYBER_ROUTER).swapExactTokensForTokens(
            _half,
            0,
            path,
            address(this),
            now
        );

        // kyber to usdt
        path = new address[](2);
        path[0] = reward;
        path[1] = usdt;
        kyber(KYBER_ROUTER).swapExactTokensForTokens(
            _tokens.sub(_half),
            0,
            path,
            address(this),
            now
        );

        uint256 _wbtcIn = balanceOfToken(wbtc);
        uint256 _usdcIn = balanceOfToken(usdt);
        // add to WBTC-USDC LP pool for pool tokens
        kyber(KYBER_ROUTER).addLiquidity(
            wbtc,
            usdt,
            _wbtcIn,
            _usdcIn,
            _wbtcIn.mul(slippage).div(MAX_BPS),
            _usdcIn.mul(slippage).div(MAX_BPS),
            address(this),
            now
        );
    }

    function setSlippageTolerance(uint256 _s) external {
        _onlyGovernanceOrStrategist();
        slippage = _s;
    }
}
