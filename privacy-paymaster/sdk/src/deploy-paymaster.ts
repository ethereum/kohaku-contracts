import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import type { Hex } from "viem";

export interface DeployPaymasterOptions {
    forkUrl: string;
    privateKey: Hex;
    deployEnv?: string;
    stakeAmount?: string;
    unstakeDelay?: string;
    depositAmount?: string;
}

export interface DeploymentResult {
    paymasterAddress: `0x${string}`;
}

function findProjectRoot(startDir: string): string {
    let dir = startDir;
    while (true) {
        if (existsSync(join(dir, "foundry.toml"))) return dir;
        const parent = dirname(dir);
        if (parent === dir) throw new Error("Could not find foundry.toml — run from inside the privacy-paymaster project");
        dir = parent;
    }
}

/// Runs forge, resolving with its stdout.
function forge(args: string[], env: NodeJS.ProcessEnv, cwd: string): Promise<string> {
    return new Promise((resolve, reject) => {
        console.log(`Running: forge ${args.join(" ")}`);
        const proc = spawn("forge", args, { env, cwd, stdio: ["ignore", "pipe", "pipe"] });
        let stdout = "";
        let stderr = "";
        proc.stdout!.on("data", (chunk: Buffer) => { stdout += chunk.toString(); });
        proc.stderr!.on("data", (chunk: Buffer) => { stderr += chunk.toString(); });
        proc.on("close", (code) => {
            if (code !== 0) reject(new Error(`forge ${args.join(" ")} failed:\n${stderr}`));
            else resolve(stdout);
        });
    });
}

export async function deployPaymaster(options: DeployPaymasterOptions): Promise<DeploymentResult> {
    const {
        forkUrl,
        privateKey,
        deployEnv = "anvil-test",
        stakeAmount = "100000000000000000",
        unstakeDelay = "3600",
        depositAmount = "100000000000000000",
    } = options;

    const projectRoot = findProjectRoot(dirname(fileURLToPath(import.meta.url)));
    const env: NodeJS.ProcessEnv = { ...process.env, DEPLOY_ENV: deployEnv, PRIVATE_KEY: privateKey };

    const deployOutput = await forge(
        ["script", "DeployTornado", "--fork-url", forkUrl, "--broadcast", "--json"], env, projectRoot,
    );
    const paymasterAddress = scriptReturn(deployOutput, "paymaster");
    const paymasterEnv: NodeJS.ProcessEnv = { ...env, PAYMASTER_ADDRESS: paymasterAddress };

    await forge(["script", "SetupTornado", "--fork-url", forkUrl, "--broadcast"], paymasterEnv, projectRoot);

    await forge(["script", "StakePaymaster", "--fork-url", forkUrl, "--broadcast"], {
        ...paymasterEnv, STAKE_AMOUNT: stakeAmount, UNSTAKE_DELAY: unstakeDelay, DEPOSIT_AMOUNT: depositAmount,
    }, projectRoot);

    return { paymasterAddress };
}

/// Reads a named return value of a script's `run()` from `forge script --json`
/// output, which prints one JSON object per line.
function scriptReturn(output: string, name: string): `0x${string}` {
    for (const line of output.split("\n")) {
        if (!line.startsWith("{")) continue;
        const value = JSON.parse(line).returns?.[name]?.value;
        if (value) return value;
    }
    throw new Error(`forge script output has no "${name}" return value:\n${output}`);
}
