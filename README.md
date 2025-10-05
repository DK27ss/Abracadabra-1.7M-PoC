# Abracadabra-1.7M-PoC
Abracadabra Protocol exploit PoC

Abracadabra, a DeFi lending protocol which also issues the decentralized Magic Internet Money (MIM) stablecoin, lost nearly $1.8 million worth of MIM after an attacker exploited a flaw in one of the protocol's functions. 

In the attack, which occurred late Saturday night, an unknown threat actor leveraged a smart contract vulnerability to bypass solvency checks, allowing them to extract 1.79 million MIM from the protocol, according to security firm BlockSec Phalcon. The attack wallet's initial funding came from mixing protocol Tornado Cash; following the attack, the attacker swapped the tokens for ETH and sent it back to Tornado. 

The exploit abused a flawed implementation of the `cook()` function in `CauldronV4`, where the combined call `[5, 0]` allowed resetting the `needsSolvencyCheck` flag and completely bypassing solvency checks, thus enabling the borrowing of ~1.79M MIM without collateral.

The Abracadabra Money protocol uses a `Cauldron` architecture (borrowing logic) called via a `Degenbox` proxy.
Complex operations are orchestrated through the versatile `cook()` function, which executes a sequence of encoded actions (actions[], values[], datas[]) in a single call.

Each action corresponds to an internal operation:

    Action ID	         Meaning
    5	ACTION_BORROW → MIM borrowing
    0	ACTION_CUSTOM / _additionalCookAction() → additional "custom" action

ACTION_BORROW (5) sets `status.needsSolvencyCheck = true`, to force the solvency check at the end.

But action 0 (ACTION_CUSTOM) calls `_additionalCookAction()`, an empty function that returns a new status structure where all fields are reset to false

    function _additionalCookAction(CookStatus memory, bytes memory) internal pure returns (CookStatus memory) {
        return CookStatus(false);
    }

As a result, the `needsSolvencyCheck` flag is cleared after a borrow.

At the end of `cook()`, the contract checks:

    if (status.needsSolvencyCheck) _ensureSolvent(user);

But since the flag was reset to false, no solvency check is performed — the user can therefore borrow without any collateral.

The attacker exploited this flaw by calling:

    actions = [5, 0]
    datas = [ encodeBorrowParams(amount, attacker), "" ]

`ACTION_BORROW` → borrows a large amount of MIM.
`ACTION_0` → calls the empty _additionalCookAction() function → clears the flag.
End of `cook()` → no check → the attacker keeps the borrowed MIM.
They repeated this sequence on `6 different cauldrons`, each executing a massive borrow.

    Stolen tokens: ≈ 1,793,755 MIM (~$1.79M)
    
    Main attacker: 0x1AaaDe3e9062d124B7DeB0eD6DDC7055EFA7354d
    Vulnerable contract: 0xd96f48665a1410c0cd669a88898eca36b9fc2cce (Degenbox)
    Cauldron 1 : 0x46f54d434063e5F1a2b2CC6d9AAa657b1B9ff82c (CauldronV4)
    Cauldron 2 : 0x289424aDD4A1A503870EB475FD8bF1D586b134ED (CauldronV4)
    Cauldron 3 : 0xce450a23378859fB5157F4C4cCCAf48faA30865B (CauldronV4)
    Cauldron 4 : 0x40d95C4b34127CF43438a963e7C066156C5b87a3 (CauldronV4)
    Cauldron 5 : 0x6bcd99D6009ac1666b58CB68fB4A50385945CDA2 (CauldronV4)
    Cauldron 6 : 0xC6D3b82f9774Db8F92095b5e4352a8bB8B0dC20d (CauldronV4)
    
    Tx: 0x842aae91c89a9e5043e64af34f53dc66daf0f033ad8afbf35ef0c93f99a9e5e6
    https://app.blocksec.com/explorer/tx/eth/0x842aae91c89a9e5043e64af34f53dc66daf0f033ad8afbf35ef0c93f99a9e5e6

    Post-Mortem Ressources
    ----------
    https://x.com/GoPlusSecurity/status/1974716994516877452
    https://x.com/Phalcon_xyz/status/1974533451408986417
    https://x.com/hklst4r/status/1974477630171734327
