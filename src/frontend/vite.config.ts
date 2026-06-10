// Vite config. The icpBindgen plugin regenerates src/bindings/backend.ts from
// the committed backend Candid interface on every dev/build run, so the typed
// actor can never drift from the .did without a type error.
//
// `vite dev` needs a running local network with the backend deployed
// (`icp network start -d && icp deploy backend`) — getDevServerConfig()
// simulates the `ic_env` cookie the asset canister sets in production. The
// `command === "serve"` guard keeps production builds from shelling out to
// `icp`.
import { execSync } from "node:child_process";
import { defineConfig } from "vite";
import { icpBindgen } from "@icp-sdk/bindgen/plugins/vite";

const environment = process.env.ICP_ENVIRONMENT || "local";

function getCanisterId(name: string): string {
  return execSync(`icp canister status ${name} -e ${environment} -i`, {
    encoding: "utf-8",
    stdio: "pipe",
  }).trim();
}

function getDevServerConfig() {
  const networkStatus = JSON.parse(
    execSync(`icp network status -e ${environment} --json`, {
      encoding: "utf-8",
    }),
  );
  const canisterParams = `PUBLIC_CANISTER_ID:backend=${getCanisterId("backend")}`;
  return {
    headers: {
      "Set-Cookie": `ic_env=${encodeURIComponent(
        `${canisterParams}&ic_root_key=${networkStatus.root_key}`,
      )}; SameSite=Lax;`,
    },
    proxy: {
      "/api": { target: networkStatus.api_url, changeOrigin: true },
    },
  };
}

// vitest also runs with command === "serve", so additionally gate on mode —
// unit tests must not shell out to `icp`.
export default defineConfig(({ command, mode }) => ({
  plugins: [
    icpBindgen({
      didFile: "../backend/dist/backend.did",
      outDir: "./src/bindings",
    }),
  ],
  ...(command === "serve" && mode !== "test" ? { server: getDevServerConfig() } : {}),
}));
