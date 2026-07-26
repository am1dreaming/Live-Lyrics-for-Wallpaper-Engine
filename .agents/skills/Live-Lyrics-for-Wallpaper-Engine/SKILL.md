```markdown
# Live-Lyrics-for-Wallpaper-Engine Development Patterns

> Auto-generated skill from repository analysis

## Overview
This skill teaches you the core development patterns and conventions used in the `Live-Lyrics-for-Wallpaper-Engine` JavaScript codebase. You'll learn how to structure files, write imports/exports, follow commit conventions, and understand the project's approach to testing. This guide is ideal for contributors aiming to maintain consistency and quality in this repository.

## Coding Conventions

### File Naming
- Use **camelCase** for file names.
  - Example: `liveLyricsManager.js`, `lyricsFetcher.js`

### Import Style
- Use **relative imports** for local modules.
  - Example:
    ```javascript
    import { fetchLyrics } from './lyricsFetcher.js';
    ```

### Export Style
- Use **named exports**.
  - Example:
    ```javascript
    // In lyricsFetcher.js
    export function fetchLyrics(song) { ... }
    ```

    ```javascript
    // In another file
    import { fetchLyrics } from './lyricsFetcher.js';
    ```

### Commit Messages
- Freeform style, typically short (average 8 characters).
- No enforced prefixes.
  - Example:  
    ```
    Update lyrics
    Fix sync bug
    Add tests
    ```

## Workflows

### Adding a New Feature
**Trigger:** When implementing new functionality.
**Command:** `/add-feature`

1. Create a new file using camelCase (e.g., `newFeature.js`).
2. Use relative imports to include dependencies.
3. Export your functions or constants using named exports.
4. Write or update tests in a corresponding `*.test.*` file.
5. Commit your changes with a clear, concise message.

### Fixing a Bug
**Trigger:** When resolving a reported issue.
**Command:** `/fix-bug`

1. Locate the relevant file(s) using camelCase naming.
2. Apply your fix, maintaining code style.
3. Update or add tests to cover the bug fix.
4. Commit with a short, descriptive message.

### Writing Tests
**Trigger:** When adding or updating tests.
**Command:** `/write-test`

1. Create or update a test file matching the `*.test.*` pattern (e.g., `lyricsFetcher.test.js`).
2. Write tests for your functions or modules.
3. Run the tests using the project's test runner (framework unknown; check project docs or scripts).
4. Ensure all tests pass before committing.

## Testing Patterns

- Test files follow the pattern: `*.test.*` (e.g., `lyricsFetcher.test.js`).
- The specific testing framework is not detected; refer to existing test files for structure.
- Place tests alongside or near the modules they test.
- Example test file name: `liveLyricsManager.test.js`

## Commands
| Command      | Purpose                                    |
|--------------|--------------------------------------------|
| /add-feature | Steps to add a new feature                 |
| /fix-bug     | Steps to fix a bug                         |
| /write-test  | Steps to write or update a test            |
```
