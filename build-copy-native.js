// Post-build helper: copies the keytar native module next to the bundled exe.
// keytar.node must live alongside v1-story-copier.exe so the executable can load it.
const fs = require('fs');
const path = require('path');

const src = path.join(__dirname, 'node_modules', 'keytar', 'build', 'Release', 'keytar.node');
const dest = path.join(__dirname, 'dist', 'keytar.node');

if (!fs.existsSync(src)) {
    console.warn('keytar.node not found at', src, '- skipping copy. Run "npm install" first.');
    process.exit(0);
}

fs.mkdirSync(path.join(__dirname, 'dist'), { recursive: true });
fs.copyFileSync(src, dest);
console.log('Copied keytar.node to dist/');
