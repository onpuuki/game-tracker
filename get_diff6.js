const fs = require('fs');
const content = fs.readFileSync('frontend/lib/screens/home_screen.dart', 'utf8');
const lines = content.split('\n');

const startIndex = 1968;
const endIndex = startIndex + 300;

console.log(lines.slice(startIndex, endIndex).join('\n'));
