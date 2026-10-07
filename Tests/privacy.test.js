// The repository is public: no real people, phones, cards or private payees may be committed.
// Runs in .local/check.ps1, in the git pre-commit hook and in GitHub Actions.
// Synthetic names used in tests must be listed in SYNTHETIC_NAMES.
// Optionally, .local/private-words.txt (never committed) lists words from the owner's real statements.
const fs = require('node:fs');
const path = require('node:path');
const { execSync } = require('node:child_process');

const root = path.join(__dirname, '..');
const SYNTHETIC_NAMES = new Set([
  'Иван Иванович И.', 'Мария Ивановна П.', 'Пётр Сергеевич К.', 'Иванов Иван Иванович',
]);

const files = execSync('git ls-files', { cwd: root, encoding: 'utf8' }).split('\n').filter(Boolean)
  .filter(file => /\.(swift|js|md|json|yml|plist|txt|pbxproj)$/.test(file))
  .filter(file => !file.includes('.xcassets/'));

const privateWords = (() => {
  try {
    return fs.readFileSync(path.join(root, '.local/private-words.txt'), 'utf8')
      .split(/\r?\n/).map(word => word.trim()).filter(word => word.length >= 4 && !word.startsWith('#'));
  } catch { return []; }
})();

const problems = [];
for (const file of files) {
  const lines = fs.readFileSync(path.join(root, file), 'utf8').split('\n');
  lines.forEach((line, index) => {
    const where = `${file}:${index + 1}`;
    // Russian mobile numbers; a masked one ends in 000-00-00.
    for (const match of line.matchAll(/\+7[\s(-]*9\d{2}[\s)-]*(\d{3})[\s-]*(\d{2})[\s-]*(\d{2})/g)) {
      if (match[1] + match[2] + match[3] !== '0000000') problems.push(`${where}: phone number ${match[0]}`);
    }
    // Full card numbers.
    if (/\b\d{4}[ -]\d{4}[ -]\d{4}[ -]\d{4}\b|\b\d{16}\b/.test(line)) problems.push(`${where}: card-like number`);
    // «Имя Отчество Ф.» as banks print people in transfers.
    for (const match of line.matchAll(/[А-ЯЁ][а-яё]+ [А-ЯЁ][а-яё]+(?:вич|вна|ична|чна|ьич) [А-ЯЁ]\./g)) {
      if (!SYNTHETIC_NAMES.has(match[0])) problems.push(`${where}: person «${match[0]}» (add to SYNTHETIC_NAMES only if invented)`);
    }
    const lower = line.toLowerCase();
    for (const word of privateWords) {
      if (lower.includes(word.toLowerCase())) problems.push(`${where}: private word from .local/private-words.txt`);
    }
  });
}

if (problems.length) {
  console.error('Private data in the public repository:\n' + problems.slice(0, 40).join('\n'));
  process.exit(1);
}
console.log(`Privacy: ${files.length} tracked files clean (${privateWords.length} private words checked).`);
