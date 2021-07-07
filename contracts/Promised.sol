// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;

import "hardhat/console.sol";

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20Burnable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

// Interfaces
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./interfaces/IERC20Metadata.sol";
import "./interfaces/IERC20Burnable.sol";
import "./interfaces/IOracle.sol";
import "./interfaces/IAggregatorV3.sol";

contract Promised is ReentrancyGuard, Ownable {
    using SafeMath for uint256;
    using SafeERC20 for ERC20;

    // STATE VARIABLES
    address public oracle;
    address public collateral_oracle;
    address public dollar;
    address public collateral;
    address public share;

    // Constants for various precisions
    uint256 private constant PRICE_PRECISION = 1e18;
    uint256 private constant COLLATERAL_RATIO_PRECISION = 1e18;
    uint256 private constant COLLATERAL_RATIO_MAX = 1e18;

    mapping(address => uint256) public last_interaction;
    uint256 public interaction_delay;

    // Number of decimals needed to get to 18
    uint256 private missing_decimals;

    // Number of blocks to wait before being able to collectRedemption()
    uint256 public redemption_delay = 1;

    uint256 public tcr; // 80%
    uint256 public ecr; // 80%

    uint256 public minting_fee = 3e15; //0.3%
    uint256 public redemption_fee = 7e15; //0.7%

    address public reserve_addr;

    uint256 public constant REDEMPTION_FEE_MAX = 1e16; // 1%
    uint256 public constant MINTING_FEE_MAX = 1e16; // 1%

    bool public mint_paused = false;
    bool public redeem_paused = false;

    event Mint(
        uint256 collateral_amount,
        uint256 share_amount,
        uint256 dollar_out
    );
    event Redeem(
        uint256 collateral_out,
        uint256 share_amount,
        uint256 dollar_amount
    );

    constructor(
        address _oracle,
        address _dollar,
        address _collateral_oracle,
        address _collateral,
        address _share,
        uint256 _minting_fee,
        uint256 _redemption_fee,
        address _reserve_addr
    ) public {
        console.log("Deploying a Promised oracle:", _oracle);
        console.log("Deploying a Promised dollar:", _dollar);
        console.log("Deploying a Promised collateral:", _collateral);
        console.log("Deploying a Promised share:", _share);

        oracle = _oracle;
        dollar = _dollar;
        collateral_oracle = _collateral_oracle;
        collateral = _collateral;
        share = _share;
        tcr = 8e17;
        ecr = 8e17;
        minting_fee = _minting_fee;
        redemption_fee = _redemption_fee;
        reserve_addr = _reserve_addr;
        missing_decimals = 18 - IERC20Metadata(_collateral).decimals();
        interaction_delay = 1; //block
    }

    function info()
        external
        view
        returns (
            uint256,
            bool,
            bool
        )
    {
        return (
            getCollateralPrice(), // collateral price
            mint_paused,
            redeem_paused
        );
    }

    /* ========== PUBLIC FUNCTIONS ========== */

    function getCollateralPrice() public view returns (uint256 _price) {
        IAggregatorV3 _collateral_oracle = IAggregatorV3(collateral_oracle);
        _price = getRatioOf(
            uint256(_collateral_oracle.latestAnswer()),
            10**uint256(_collateral_oracle.decimals())
        );
    }

    function getSharePrice() public view returns (uint256) {
        return
            IOracle(oracle).consult(
                share,
                10**uint256(IERC20Metadata(share).decimals())
            );
    }

    function checkAvailability() private view {
        require(
            last_interaction[msg.sender] + interaction_delay <= block.number,
            "<interaction_delay"
        );
    }

    function mint(
        uint256 _collateral_amount,
        uint256 _share_amount,
        uint256 _dollar_out_min
    ) external nonReentrant {
        console.log("minting");
        console.log("_collateral_amount", _collateral_amount);
        require(mint_paused == false, "Minting is paused");

        checkAvailability();

        uint256 _price_collateral = getCollateralPrice();
        uint256 _total_dollar_value = 0;
        uint256 _required_share_amount = 0;
        uint256 _share_price = getSharePrice();

        uint256 _collateral_value = getProductOf(
            _collateral_amount.mul((10**missing_decimals)),
            _price_collateral
        );
        console.log("colateral_value", _collateral_value);
        _total_dollar_value = getRatioOf(_collateral_value, tcr);
        console.log("_total_dollar_value", _total_dollar_value);
        _required_share_amount = getRatioOf(
            _total_dollar_value.sub(_collateral_value),
            _share_price
        );
        console.log("_required_share_amount", _required_share_amount);
        uint256 _fee = getProductOf(_total_dollar_value, minting_fee);
        uint256 _actual_dollar_amount = _total_dollar_value.sub(_fee);
        console.log("_actual_dollar_amount", _actual_dollar_amount);

        require(_dollar_out_min <= _actual_dollar_amount, "slippage");

        console.log("collateral to transfer", _collateral_amount);

        last_interaction[msg.sender] = block.number;

        if (_collateral_amount > 0) {
            IERC20(collateral).transferFrom(
                msg.sender,
                address(this),
                _collateral_amount
            );
        }
        if (_required_share_amount > 0) {
            require(
                _required_share_amount <= _share_amount,
                "Not enough SHARE input"
            );
            IERC20Burnable(share).burnFrom(msg.sender, _required_share_amount);
        }

        IERC20Burnable(dollar).mint(msg.sender, _actual_dollar_amount);
        IERC20Burnable(dollar).mint(reserve_addr, _fee);

        emit Mint(
            _collateral_amount,
            _required_share_amount,
            _actual_dollar_amount
        );
    }

    function redeem(
        uint256 _dollar_amount,
        uint256 _share_out_min,
        uint256 _collateral_out_min
    ) external nonReentrant {
        require(redeem_paused == false, "Redeeming is paused");
        checkAvailability();

        console.log("Redeeming");

        uint256 _share_price = getSharePrice();
        uint256 _collateral_price = getCollateralPrice();
        require(_collateral_price > 0, "Invalid collateral price");
        require(_share_price > 0, "Invalid share price");
        uint256 _fee = getProductOf(_dollar_amount, redemption_fee);
        uint256 _dollar_amount_post_fee = _dollar_amount.sub(_fee);
        uint256 _collateral_output_amount = 0;
        uint256 _share_output_amount = 0;
        uint256 _share_fee = 0;
        uint256 _collateral_fee = 0;

        if (ecr < COLLATERAL_RATIO_MAX) {
            uint256 _share_output_value = _dollar_amount_post_fee.sub(
                (_dollar_amount_post_fee.mul(ecr)).div(PRICE_PRECISION)
            );
            uint256 _share_output_pre_fee = _dollar_amount.sub(
                getProductOf(_dollar_amount, ecr)
            );
            _share_output_amount = getRatioOf(
                _share_output_value,
                _share_price
            );
            uint256 _share_output_amount_pre_fee = getRatioOf(
                _share_output_pre_fee,
                _share_price
            );
            _share_fee = getProductOf(
                redemption_fee,
                _share_output_amount_pre_fee
            );
        }

        console.log("_share_fee", _share_fee);

        if (ecr > 0) {
            uint256 _collateral_output_pre_fee_value = (
                getProductOf(_dollar_amount, ecr)
            )
            .div(10**missing_decimals);

            uint256 _collateral_output_value = (
                getProductOf(_dollar_amount_post_fee, ecr)
            )
            .div(10**missing_decimals);

            _collateral_output_amount = getRatioOf(
                _collateral_output_value,
                _collateral_price
            );
            uint256 _collateral_output_pre_fee_amount = getRatioOf(
                _collateral_output_pre_fee_value,
                _collateral_price
            );

            _collateral_fee = getProductOf(
                redemption_fee,
                _collateral_output_pre_fee_amount
            );
        }
        console.log("_collateral_fee", _collateral_fee);

        // Check if collateral balance meets and meet output expectation
        uint256 _total_collateral_balance = IERC20(collateral).balanceOf(
            address(this)
        );

        console.log("_collateral_out_min = ", _collateral_out_min);
        console.log("_share_out_min = ", _share_out_min);

        require(
            _collateral_output_amount <= _total_collateral_balance,
            "<collateralBalance"
        );
        require(
            _collateral_out_min <= _collateral_output_amount &&
                _share_out_min <= _share_output_amount,
            ">slippage"
        );

        last_interaction[msg.sender] = block.number;

        if (_collateral_output_amount > 0) {
            IERC20(collateral).transfer(msg.sender, _collateral_output_amount);
        }

        console.log("_share_output_amount", _share_output_amount);
        console.log("_collateral_output_amount", _collateral_output_amount);
        if (_share_output_amount > 0) {
            IERC20Burnable(share).mint(msg.sender, _share_output_amount);
        }

        IERC20Burnable(dollar).burnFrom(msg.sender, _dollar_amount);

        console.log("_share_fee", _share_fee);
        console.log("_collateral_fee", _collateral_fee);
        if (_share_fee > 0) {
            IERC20Burnable(share).mint(reserve_addr, _share_fee);
        }
        if (_collateral_fee > 0) {
            IERC20(collateral).transfer(reserve_addr, _collateral_fee);
        }

        emit Redeem(
            _collateral_output_amount,
            _share_output_amount,
            _dollar_amount
        );
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    function setInteractionDelay(uint256 _interaction_delay)
        external
        onlyOwner
    {
        require(_interaction_delay > 0, "delay should be higher than 0");
        interaction_delay = _interaction_delay;
    }

    function toggleMinting() external onlyOwner {
        mint_paused = !mint_paused;
    }

    function toggleRedeeming() external onlyOwner {
        redeem_paused = !redeem_paused;
    }

    function setOracle(address _oracle) external onlyOwner {
        require(_oracle != address(0), "Invalid address");
        oracle = _oracle;
    }

    function setCollateralOracle(address _oracle) external onlyOwner {
        require(_oracle != address(0), "Invalid address");
        collateral_oracle = _oracle;
    }

    function setRedemptionFee(uint256 _redemption_fee) public onlyOwner {
        require(_redemption_fee <= REDEMPTION_FEE_MAX, ">REDEMPTION_FEE_MAX");
        redemption_fee = _redemption_fee;
    }

    function setMintingFee(uint256 _minting_fee) public onlyOwner {
        require(_minting_fee <= MINTING_FEE_MAX, ">MINTING_FEE_MAX");
        minting_fee = _minting_fee;
    }

    function setTCRandECR(uint256 _tcr, uint256 _ecr) public onlyOwner {
        require(_tcr <= COLLATERAL_RATIO_MAX, ">COLLATERAL_RATIO_MAX");
        require(_ecr <= COLLATERAL_RATIO_MAX, ">COLLATERAL_RATIO_MAX");

        tcr = _tcr;
        ecr = _ecr;
    }

    function getProductOf(uint256 _amount, uint256 _multiplier)
        public
        pure
        returns (uint256)
    {
        return (_amount.mul(_multiplier)).div(PRICE_PRECISION);
    }

    function getRatioOf(uint256 _amount, uint256 _divider)
        public
        pure
        returns (uint256)
    {
        return
            (
                ((_amount.mul(PRICE_PRECISION)).div(_divider)).mul(
                    PRICE_PRECISION
                )
            )
                .div(PRICE_PRECISION);
    }
}
