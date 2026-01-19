/**
 * Commitlint configuration
 * @see https://commitlint.js.org/
 */
module.exports = {
  extends: ['@commitlint/config-conventional'],
  rules: {
    // Type must be one of these values
    'type-enum': [
      2,
      'always',
      [
        'feat',     // New feature
        'fix',      // Bug fix
        'docs',     // Documentation only
        'refactor', // Code restructure, no behavior change
        'chore',    // Maintenance, backlog updates, config
        'test',     // Adding or updating tests
        'ci',       // CI/CD configuration
      ],
    ],
    // Type is required
    'type-empty': [2, 'never'],
    // Subject is required
    'subject-empty': [2, 'never'],
    // Subject must be sentence case (first letter uppercase)
    'subject-case': [2, 'always', 'sentence-case'],
    // No period at end of subject
    'subject-full-stop': [2, 'never', '.'],
    // Header max length
    'header-max-length': [2, 'always', 72],
    // Scope should be lowercase with hyphens
    'scope-case': [2, 'always', 'kebab-case'],
  },
};
