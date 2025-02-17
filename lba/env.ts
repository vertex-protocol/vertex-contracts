import "dotenv/config";

declare global {
  // eslint-disable-next-line @typescript-eslint/no-namespace
  namespace NodeJS {
    interface ProcessEnv {
      VERBOSE?: string;
      AUTOMINE_INTERVAL?: string;
      DEFAULT_NETWORK?: string;
    }
  }
}

interface EnvVars {
  verbose: boolean;
  automineInterval?: number;
  defaultNetwork?: string;
}

const automineInterval = Number(process.env.AUTOMINE_INTERVAL);

export const env: EnvVars = {
  verbose: process.env.VERBOSE === "TRUE",
  automineInterval: Number.isFinite(automineInterval)
    ? automineInterval
    : undefined,
  defaultNetwork: process.env.DEFAULT_NETWORK,
};

// Disable console.debug for non-verbose
if (!env.verbose) {
  // eslint-disable-next-line @typescript-eslint/no-empty-function
  console.debug = function () {};
}
