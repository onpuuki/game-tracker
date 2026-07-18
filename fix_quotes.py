import re

with open('functions/src/index.ts', 'r') as f:
    content = f.read()

# Python string replacements did not work, use regex to remove any extra slashes
content = re.sub(r"\\\\`", "`", content)

with open('functions/src/index.ts', 'w') as f:
    f.write(content)
