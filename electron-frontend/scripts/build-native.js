#!/usr/bin/env node

const { spawn } = require('child_process');
const path = require('path');

function runZigBuild(target) {
  return new Promise((resolve, reject) => {
    const args = ['build', '-Doptimize=ReleaseFast'];
    if (target) {
      args.push(`-Dtarget=${target}`);
    }

    console.log(`Building Zig backend for ${target || 'native'}...`);

    const zigProcess = spawn('zig', args, {
      cwd: path.join(__dirname, '..', '..'),
      stdio: 'inherit'
    });

    zigProcess.on('close', (code) => {
      if (code === 0) {
        console.log(`✅ Zig backend built successfully for ${target || 'native'}`);
        resolve();
      } else {
        reject(new Error(`Zig build failed with code ${code}`));
      }
    });

    zigProcess.on('error', (err) => {
      reject(err);
    });
  });
}

async function main() {
  const arch = process.env.npm_config_target_arch || process.arch;
  const platform = process.env.npm_config_target_platform || process.platform;

  let target = null;

  if (platform === 'darwin') {
    if (arch === 'x64') {
      target = 'x86_64-macos';
    } else if (arch === 'arm64') {
      target = 'aarch64-macos';
    }
  } else if (platform === 'win32') {
    target = 'x86_64-windows';
  } else if (platform === 'linux') {
    target = 'x86_64-linux';
  }

  try {
    await runZigBuild(target);
  } catch (error) {
    console.error('❌ Failed to build Zig backend:', error.message);
    process.exit(1);
  }
}

if (require.main === module) {
  main();
}

module.exports = { runZigBuild }; 