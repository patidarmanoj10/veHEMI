import { DeployFunction } from "hardhat-deploy/types";
import { execSync } from "child_process";
import { Addresses } from "../helpers/addresses";
import { saveForSafeBatchExecution } from "../helpers/safe";

const VE_HEMI = "VeHemi";
const VOTE_DELEGATION = "VeHemiVoteDelegation";

// ── Deployment documentation ───────────────────────────────────────────────
// This script upgrades the veHEMI system to V2 (subcurves + Aragon support).
// It bundles three transactions for the Gnosis Safe, executed atomically:
//
//   1. upgrade(VeHemiVoteDelegation proxy, new delegation impl) - upgrades the
//      delegation contract to add hourly checkpoints, autoDelegate /
//      delegateAllFor / clearAutoDelegate, and the trusted-adapter hook
//      consumed by the Aragon adapter (script 05). NO initializer call —
//      reusing initialize() would revert because of the `initializer` modifier.
//
//   2. upgrade(VeHemi proxy, new VeHemi V2 impl) - upgrades VeHemi to the V2
//      implementation. NO initializer call. The V2 locked-curve functionality
//      is gated behind `nonTransferableSeedingFinalized` (defaults to false), so the
//      contract behaves identically to V1 until step 3 runs.
//
//   3. seedAndFinalizeNonTransferablePositions(tokenIds) - seeds all active
//      non-transferable positions and enables locked-curve tracking. One-shot
//      and irreversible: the function reverts on subsequent calls.
//
// All three transactions are saved to the Safe batch file so they execute in
// a single multisig proposal. Steps 1 and 2 are independently safe (the
// delegation upgrade adds new functions without removing old ones; the VeHemi
// V2 upgrade is dormant until seeding) but they are executed together to keep
// the operational story simple. The recommended order is delegation first,
// then VeHemi, then seeding — VeHemi's try/catch on autoDelegate() means the
// reverse order is also safe but redundant work would be needed to recover.
//
// IMPORTANT: The tokenIds array MUST include ALL active non-transferable
// positions. Omitted positions would permanently understate the non-transferable supply
// with no recovery path other than a full V3 upgrade. Verify the calldata
// against on-chain state before governance execution.

// 126 active non-transferable token IDs as of block ~2026-04-08.
// Sourced from on-chain query: transferableAfter != 0, lock.end > block.timestamp, amount > 0.
// Sorted ascending. Range 28660-28805 (6 of the original 132 have expired).
// IMPORTANT: Re-verify against on-chain state before governance execution.
// prettier-ignore
const NON_TRANSFERABLE_TOKEN_IDS: number[] = [
    28660, 28661, 28662, 28663, 28664, 28665, 28666, 28667, 28668, 28669,
    28670, 28671, 28672, 28673, 28674, 28675, 28676, 28677, 28678, 28679,
    28680, 28681, 28682, 28683, 28684, 28685, 28686, 28687, 28688, 28689,
    28690, 28691, 28692, 28693, 28694, 28695, 28696, 28697, 28698, 28699,
    28700, 28705, 28706, 28707, 28708, 28709, 28710, 28711, 28712, 28713,
    28714, 28715, 28716, 28717, 28718, 28719, 28720, 28721, 28726, 28727,
    28728, 28729, 28730, 28731, 28732, 28733, 28734, 28735, 28736, 28737,
    28738, 28739, 28740, 28741, 28742, 28743, 28744, 28745, 28746, 28747,
    28748, 28749, 28750, 28751, 28752, 28753, 28754, 28755, 28756, 28757,
    28758, 28759, 28760, 28761, 28762, 28763, 28764, 28765, 28766, 28771,
    28772, 28773, 28774, 28775, 28776, 28777, 28778, 28779, 28780, 28781,
    28782, 28783, 28784, 28785, 28786, 28787, 28792, 28793, 28794, 28795,
    28796, 28801, 28802, 28803, 28804, 28805,
];

const func: DeployFunction = async function (hre) {
    const { deployments, getNamedAccounts, network } = hre;
    const { deploy, catchUnknownSigner, execute, get, read } = deployments;
    const { deployer } = await getNamedAccounts();

    // Only run on Hemi mainnet or localhost
    if (network.config.chainId !== 43111 && network.config.chainId !== 31337) {
        throw new Error(
            `This deployment script is only for Hemi and Localhost. Current chain ID: ${network.config.chainId}`
        );
    }

    // ── Pre-flight checks ──────────────────────────────────────────────────
    // Validate the on-chain state of both proxies before queueing any
    // upgrade transactions. Failing here is much cheaper than catching a
    // bad upgrade after the Safe has already executed it.
    console.log("=== Pre-flight checks ===");

    const { address: veHemiAddress } = await get(VE_HEMI);
    const { address: voteDelegationAddress } = await get(VOTE_DELEGATION);
    console.log("VeHemi proxy:           ", veHemiAddress);
    console.log("VoteDelegation proxy:   ", voteDelegationAddress);

    // 1. VeHemi must reference the expected VoteDelegation proxy.
    const currentVoteDelegation = (await read(VE_HEMI, "voteDelegation")) as string;
    if (currentVoteDelegation.toLowerCase() !== voteDelegationAddress.toLowerCase()) {
        throw new Error(
            `VeHemi.voteDelegation() mismatch: expected ${voteDelegationAddress}, got ${currentVoteDelegation}`
        );
    }
    console.log("VeHemi.voteDelegation:   OK (matches deployment)");

    // 2. VeHemi must already hold real positions — guards against running on
    //    a fresh proxy where seeding would silently produce a zero subcurve.
    const totalSupply = (await read(VE_HEMI, "totalVeHemiSupply")) as bigint;
    if (totalSupply === 0n) {
        throw new Error("VeHemi.totalVeHemiSupply() is zero — wrong network or fresh proxy?");
    }
    console.log("VeHemi.totalSupply:      ", totalSupply.toString());

    // 3. VeHemi.owner() must be the Gnosis Safe (required for step 3 +
    //    setTrustedAdapter in script 05).
    const veHemiOwner = (await read(VE_HEMI, "owner")) as string;
    if (veHemiOwner.toLowerCase() !== Addresses.Hemi.GNOSIS_SAFE.toLowerCase()) {
        throw new Error(
            `VeHemi.owner() mismatch: expected ${Addresses.Hemi.GNOSIS_SAFE}, got ${veHemiOwner}`
        );
    }
    console.log("VeHemi.owner:            OK (matches Safe)");

    // 4. VeHemiVoteDelegation must already point at the same VeHemi proxy.
    const delegationVeHemi = (await read(VOTE_DELEGATION, "veHemi")) as string;
    if (delegationVeHemi.toLowerCase() !== veHemiAddress.toLowerCase()) {
        throw new Error(
            `VeHemiVoteDelegation.veHemi() mismatch: expected ${veHemiAddress}, got ${delegationVeHemi}`
        );
    }
    console.log("Delegation.veHemi:       OK (matches VeHemi proxy)");

    // 4a. VeHemi.HEMI() immutable must match the value this script will pass to
    //     the new implementation's constructor. `immutable` lives in bytecode,
    //     not storage; if a future edit renamed the constructor arg or reordered
    //     the base list, a mismatched new impl would return the wrong HEMI
    //     address on every call. Caught here, not post-upgrade.
    //
    //     Sanity-check the constant itself first: a misconfigured Addresses file
    //     with HEMI_TOKEN == address(0) would make the equality check below
    //     silently pass if the live HEMI were also zero (it isn't, but belt-and-
    //     suspenders against a future config slip).
    if (Addresses.Hemi.HEMI_TOKEN === "0x0000000000000000000000000000000000000000") {
        throw new Error("Addresses.Hemi.HEMI_TOKEN is zero — refusing to upgrade");
    }
    const currentHemi = (await read(VE_HEMI, "HEMI")) as string;
    if (currentHemi.toLowerCase() !== Addresses.Hemi.HEMI_TOKEN.toLowerCase()) {
        throw new Error(
            `VeHemi.HEMI() mismatch: expected ${Addresses.Hemi.HEMI_TOKEN}, got ${currentHemi}`
        );
    }
    console.log("VeHemi.HEMI:             OK (matches new impl constructor arg)");

    // 5. Storage layout pre-flight. The new implementation's storage layout
    //    MUST match the committed golden fixture under test/fixtures/storage-layouts/.
    //    Any drift here would silently corrupt the live proxy on upgrade.
    //    The check script normalizes AST IDs (which change on any source edit)
    //    and diffs the resulting layout against the golden file.
    //
    //    Regenerating the golden (after an intentional layout change):
    //      ./scripts/update-storage-layouts.sh
    //    Then commit the fixture diff alongside the source change.
    console.log("Running storage layout pre-flight...");
    try {
        execSync("./scripts/check-storage-layouts.sh", { stdio: "inherit" });
        console.log("Storage layouts:         OK (match golden fixtures)");
    } catch {
        throw new Error(
            "Storage layout regression detected. Aborting upgrade. " +
                "Run ./scripts/check-storage-layouts.sh for details."
        );
    }

    console.log("");

    // ── Step 1: Upgrade VeHemiVoteDelegation ───────────────────────────────
    // Bare upgrade — no initializer call. hardhat-deploy detects the
    // bytecode change and queues `ProxyAdmin.upgrade(proxy, newImpl)`.
    // Adding `execute.init` here would make hardhat-deploy queue
    // `upgradeAndCall(proxy, newImpl, initialize())` which reverts because
    // initialize() carries the `initializer` modifier.
    const upgradeDelegationFunction = () =>
        deploy(VOTE_DELEGATION, {
            from: deployer,
            log: true,
            args: [veHemiAddress],
            proxy: {
                owner: Addresses.Hemi.GNOSIS_SAFE,
                proxyContract: "OpenZeppelinTransparentProxy",
            }
        });

    const multiSigDelegationUpgradeTx = await catchUnknownSigner(upgradeDelegationFunction, { log: true });

    if (multiSigDelegationUpgradeTx) {
        await saveForSafeBatchExecution(multiSigDelegationUpgradeTx);
    }

    // ── Step 2: Upgrade VeHemi to V2 ───────────────────────────────────────
    // Same pattern: bare upgrade with no initializer call. The V2
    // locked-curve logic is dormant until step 3 (seedAndFinalizeNonTransferablePositions).
    const upgradeVeHemiFunction = () =>
        deploy(VE_HEMI, {
            from: deployer,
            log: true,
            args: [Addresses.Hemi.HEMI_TOKEN],
            proxy: {
                owner: Addresses.Hemi.GNOSIS_SAFE,
                proxyContract: "OpenZeppelinTransparentProxy",
            }
        });

    const multiSigVeHemiUpgradeTx = await catchUnknownSigner(upgradeVeHemiFunction, { log: true });

    if (multiSigVeHemiUpgradeTx) {
        await saveForSafeBatchExecution(multiSigVeHemiUpgradeTx);
    }

    // ── Step 3: Seed and finalize all non-transferable positions ───────────
    // Activates locked-curve tracking. One-shot and irreversible.
    const seedFunction = () =>
        execute(VE_HEMI, { from: deployer, log: true }, "seedAndFinalizeNonTransferablePositions", NON_TRANSFERABLE_TOKEN_IDS);

    const multiSigSeedTx = await catchUnknownSigner(seedFunction, { log: true });

    if (multiSigSeedTx) {
        await saveForSafeBatchExecution(multiSigSeedTx);
    }
};

func.tags = ["VeHemiV2Upgrade"];
func.dependencies = [VE_HEMI, VOTE_DELEGATION];
export default func;
