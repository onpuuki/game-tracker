const fs = require('fs');

let content = fs.readFileSync('frontend/lib/widgets/add_event/edit_tab.dart', 'utf8');
content = content.replace(/if \(snapshot\.hasError\)\s+return Center\(child: Text\('Error: \$\{snapshot\.error\}'\)\);/, "if (snapshot.hasError) {\n          return Center(child: Text('Error: ${snapshot.error}'));\n        }");
content = content.replace(/if \(!snapshot\.hasData\)\s+return const Center\(child: CircularProgressIndicator\(\)\);/, "if (!snapshot.hasData) {\n          return const Center(child: CircularProgressIndicator());\n        }");
content = content.replace(/if \(docs\.isEmpty\)\s+return const Center\(child: Text\('登録されたサイクルイベントがありません'\)\);/, "if (docs.isEmpty) {\n          return const Center(child: Text('登録されたサイクルイベントがありません'));\n        }");
fs.writeFileSync('frontend/lib/widgets/add_event/edit_tab.dart', content);
