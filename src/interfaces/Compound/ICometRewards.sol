// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.18;

interface ICometRewards {
    struct RewardConfig {
        address token;
        uint64 rescaleFactor;
        bool shouldUpscale;
    }

    struct RewardOwed {
        address token;
        uint256 owed;
    }

    function getRewardOwed(
        address comet,
        address account
    ) external returns (RewardOwed memory);

    function claim(address comet, address src, bool shouldAccrue) external;

    function rewardsClaimed(
        address comet,
        address account
    ) external view returns (uint256);

    function rewardConfig(
        address comet
    ) external view returns (RewardConfig memory);
}
