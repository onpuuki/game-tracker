const fs = require('fs');
const content = fs.readFileSync('frontend/lib/screens/home_screen.dart', 'utf8');
const lines = content.split('\n');

const startIndex = lines.findIndex(line => line.includes('final bool showAutoFillButton ='));
const endIndex = lines.findIndex((line, i) => i > startIndex && line.includes('class _EventCardItem extends StatefulWidget'));

console.log(lines.slice(startIndex, endIndex).join('\n'));
