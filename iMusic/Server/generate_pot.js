const { generate } = require('youtube-po-token-generator');

generate()
  .then(result => {
    process.stdout.write(JSON.stringify(result) + '\n');
    process.exit(0);
  })
  .catch(err => {
    process.stderr.write((err.message || String(err)) + '\n');
    process.exit(1);
  });
