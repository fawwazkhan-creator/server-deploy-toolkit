const fs = require("node:fs");
const path = require("node:path");

const appRoot = process.env.APP_ROOT || "/srv/app";
const currentDir = path.join(appRoot, "current");
const sharedDir = path.join(appRoot, "shared");
const logDir = path.join(sharedDir, "logs");
const envFile = path.join(sharedDir, ".env");

const API_PORT = 8000;
const WEB_PORT = 3000;

function readEnvFile(filePath) {
  let contents;
  try {
    contents = fs.readFileSync(filePath, "utf8");
  } catch (error) {
    throw new Error(`Cannot read env file ${filePath}: ${error.message}`);
  }

  const values = {};
  for (const line of contents.split(/\r?\n/)) {
    const assignment = line.match(/^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$/);
    if (!assignment) {
      continue;
    }
    const [, key, rawValue] = assignment;
    const quoted = rawValue.match(/^(["'])(.*)\1$/);
    values[key] = quoted ? quoted[2] : rawValue;
  }
  return values;
}

function positiveInteger(value, fallback) {
  const parsed = Number.parseInt(value, 10);
  return Number.isInteger(parsed) && parsed > 0 ? parsed : fallback;
}

const fileEnv = readEnvFile(envFile);
const apiWorkers = positiveInteger(fileEnv.API_WORKERS, 2);
const webInstances = positiveInteger(fileEnv.WEB_INSTANCES, 2);

const restartPolicy = {
  autorestart: true,
  max_restarts: 10,
  min_uptime: "30s",
  exp_backoff_restart_delay: 200,
};

const logSettings = {
  merge_logs: true,
  log_date_format: "YYYY-MM-DD HH:mm:ss Z",
};

module.exports = {
  apps: [
    {
      name: "api",
      cwd: path.join(currentDir, "api"),
      script: path.join(currentDir, "api", ".venv", "bin", "uvicorn"),
      interpreter: "none",
      args: [
        "app.main:app",
        "--host", "127.0.0.1",
        "--port", String(API_PORT),
        "--workers", String(apiWorkers),
        "--proxy-headers",
        "--forwarded-allow-ips", "127.0.0.1",
        "--timeout-graceful-shutdown", "8",
        "--no-server-header",
      ],
      exec_mode: "fork",
      instances: 1,
      max_memory_restart: "1G",
      kill_timeout: 10000,
      env: { ...fileEnv },
      out_file: path.join(logDir, "api.out.log"),
      error_file: path.join(logDir, "api.error.log"),
      ...restartPolicy,
      ...logSettings,
    },
    {
      name: "web",
      cwd: path.join(currentDir, "web"),
      script: path.join(currentDir, "web", "node_modules", "next", "dist", "bin", "next"),
      args: ["start", "--hostname", "127.0.0.1", "--port", String(WEB_PORT)],
      exec_mode: "cluster",
      instances: webInstances,
      max_memory_restart: "512M",
      kill_timeout: 5000,
      listen_timeout: 15000,
      env: { ...fileEnv, NODE_ENV: "production", PORT: String(WEB_PORT) },
      out_file: path.join(logDir, "web.out.log"),
      error_file: path.join(logDir, "web.error.log"),
      ...restartPolicy,
      ...logSettings,
    },
  ],
};
