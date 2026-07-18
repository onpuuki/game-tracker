import re

with open('functions/src/index.ts', 'r') as f:
    content = f.read()

# Replace any stray backslashes introduced inside the template literal.
# In JS ` is a valid character inside template literal if it is escaped with \
# but since promptText is wrapped in backticks, we should escape backticks inside it.
content = content.replace("`thought_process.deduplication_analysis`", "\\`thought_process.deduplication_analysis\\`")
content = content.replace("`liveness_audit_purges`", "\\`liveness_audit_purges\\`")
content = content.replace("`redeemCode`", "\\`redeemCode\\`")
content = content.replace("`rewards`", "\\`rewards\\`")
content = content.replace("`null`", "\\`null\\`")
content = content.replace("`thought_process.summary_extraction_logic`", "\\`thought_process.summary_extraction_logic\\`")

with open('functions/src/index.ts', 'w') as f:
    f.write(content)
