/**
 * Console utilities - colored output helpers for CLI scripts
 */

export const colors = {
  reset: "\x1b[0m",
  red: "\x1b[31m",
  green: "\x1b[32m",
  yellow: "\x1b[33m",
  blue: "\x1b[34m",
  dim: "\x1b[2m",
  bold: "\x1b[1m",
} as const;

export function log(msg: string): void {
  console.log(msg);
}

export function success(msg: string): void {
  console.log(`${colors.green}✓${colors.reset} ${msg}`);
}

export function error(msg: string): void {
  console.error(`${colors.red}✗${colors.reset} ${msg}`);
}

export function info(msg: string): void {
  console.log(`${colors.blue}ℹ${colors.reset} ${msg}`);
}

export function warn(msg: string): void {
  console.log(`${colors.yellow}!${colors.reset} ${msg}`);
}
