import { DeployFunction } from "hardhat-deploy/types";
import { saveForSafeBatchExecution } from "../helpers/safe";

const ADAPTER = "VeHemiAragonAdapter";
const VOTE_DELEGATION = "VeHemiVoteDelegation";
const VE_HEMI = "VeHemi";

// ERC-165 interface IDs verified against the adapter's supportsInterface().
const IFACE_ID_IVOTES = "0xe90fb3f6";
const IFACE_ID_ERC165 = "0x01ffc9a7";
const IFACE_ID_ERC6372 = "0xda287a1d";

// ── Deployment documentation ───────────────────────────────────────────────
// This script deploys the VeHemiAragonAdapter and configures it as the
// trusted adapter on VeHemiVoteDelegation. Two steps:
//
//   1. Deploy VeHemiAragonAdapter (immutable, not a proxy).
//      Constructor takes the VeHemi proxy address. The adapter reads
//      voteDelegation dynamically from VeHemi, so it automatically
//      picks up any future delegation contract upgrades.
//
//   2. Call setTrustedAdapter(adapterAddress) on VeHemiVoteDelegation.
//      This is an owner-only call (VeHemi's owner = Gnosis Safe).
//      Without this, adapter.delegate() cannot call delegateAllFor().
//
// Prerequisites:
//   - VeHemi proxy is deployed and upgraded to V2 (script 04)
//   - VeHemiVoteDelegation proxy is deployed and upgraded to the
//     Aragon-compatible implementation with autoDelegate, delegateAllFor,
//     hourly checkpoints, and setTrustedAdapter (script 04)
//   - seedAndFinalizeNonTransferablePositions has been called (script 04)

const func: DeployFunction = async function (hre) {
    const { deployments, getNamedAccounts, network } = hre;
    const { deploy, catchUnknownSigner, get, execute, read } = deployments;
    const { deployer } = await getNamedAccounts();

    // Only run on Hemi mainnet or localhost
    if (network.config.chainId !== 43111 && network.config.chainId !== 31337) {
        throw new Error(
            `This deployment script is only for Hemi and Localhost. Current chain ID: ${network.config.chainId}`
        );
    }

    // ── Pre-flight checks ──────────────────────────────────────────────────
    console.log("=== Pre-flight checks ===");

    const { address: veHemiAddress } = await get(VE_HEMI);
    console.log("VeHemi proxy:           ", veHemiAddress);

    // 1. VeHemi must reference a non-zero VoteDelegation. The adapter reads
    //    this dynamically at every call, so a zero address would brick the
    //    Aragon UX without any easy recovery path.
    const currentVoteDelegation = (await read(VE_HEMI, "voteDelegation")) as string;
    if (currentVoteDelegation === "0x0000000000000000000000000000000000000000") {
        throw new Error("VeHemi.voteDelegation() is the zero address — run script 01 first.");
    }
    console.log("VeHemi.voteDelegation:   OK (", currentVoteDelegation, ")");

    // 2. VeHemi must already hold real positions. Deploying the adapter on
    //    a fresh proxy would expose a totalSupply() of zero to Aragon, which
    //    would render the DAO unusable.
    const totalSupply = (await read(VE_HEMI, "totalVeHemiSupply")) as bigint;
    if (totalSupply === 0n) {
        throw new Error("VeHemi.totalVeHemiSupply() is zero — wrong network or fresh proxy?");
    }
    console.log("VeHemi.totalSupply:      ", totalSupply.toString());

    console.log("");

    // Step 1: Deploy the adapter (immutable, no proxy)
    const adapterDeployment = await deploy(ADAPTER, {
        from: deployer,
        log: true,
        args: [veHemiAddress],
    });

    console.log("VeHemiAragonAdapter deployed at:", adapterDeployment.address);

    // ── Post-deploy verification (ERC-165) ─────────────────────────────────
    // Newly-deployed adapter must announce all three interfaces. Verifying
    // here catches accidental ABI breakage from a botched recompile before
    // we ask the Safe to register it.
    const supportsIVotes = (await read(ADAPTER, "supportsInterface", IFACE_ID_IVOTES)) as boolean;
    if (!supportsIVotes) {
        throw new Error(`Adapter does not advertise IVotes (${IFACE_ID_IVOTES})`);
    }
    const supportsErc165 = (await read(ADAPTER, "supportsInterface", IFACE_ID_ERC165)) as boolean;
    if (!supportsErc165) {
        throw new Error(`Adapter does not advertise ERC165 (${IFACE_ID_ERC165})`);
    }
    const supportsErc6372 = (await read(ADAPTER, "supportsInterface", IFACE_ID_ERC6372)) as boolean;
    if (!supportsErc6372) {
        throw new Error(`Adapter does not advertise ERC6372 (${IFACE_ID_ERC6372})`);
    }
    console.log("Adapter interfaces:      OK (IVotes + ERC165 + ERC6372)");

    // Step 2: Set the adapter as trusted on VeHemiVoteDelegation.
    // This call must come from the VeHemi owner (Gnosis Safe).
    const setAdapterFunction = () =>
        execute(
            VOTE_DELEGATION,
            { from: deployer, log: true },
            "setTrustedAdapter",
            adapterDeployment.address
        );

    const multiSigTx = await catchUnknownSigner(setAdapterFunction, { log: true });

    if (multiSigTx) {
        await saveForSafeBatchExecution(multiSigTx);
    }
};

func.tags = [ADAPTER];
func.dependencies = [VE_HEMI, VOTE_DELEGATION, "VeHemiV2Upgrade"];
export default func;
