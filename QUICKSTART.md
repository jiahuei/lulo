# Development setup

Lulo currently contains only a repository foundation. There is no application to run, Swift package to test, or Xcode project to build yet.

## Documentation checks

Use Node.js 24, matching `.github/workflows/lint.yml`. Run commands from the repository root. The pinned Prettier command needs npm registry access unless it is already cached.

```sh
npx --yes prettier@3.8.3 --check '**/*.md' '.github/**/*.yml' .prettierrc
git diff --check
```

Format changed documentation and configuration files with the same pinned version, specifying their paths:

```sh
npx --yes prettier@3.8.3 --write README.md QUICKSTART.md AGENTS.md docs/CONVENTIONS.md .github/workflows/lint.yml .prettierrc
```

The lint workflow runs on pushes to every branch and has read-only repository permissions. It checks Markdown, workflow YAML, and the Prettier configuration. Local task records under `tasks/` are ignored by Git and Prettier.

## Application tooling

The minimum macOS version, Xcode/Swift toolchain, source layout, and build commands will be chosen with the implementation. Add the corresponding CI jobs when their source files and manifests exist, and update this guide with the exact commands.

The repository includes `.swift-format` for future Swift code. It uses four-space indentation and a 120-character line length. AppKit and SwiftUI builds and interactive verification require macOS; Linux checks cannot establish that the macOS app works.

Keep signing credentials and generated build/distribution artifacts out of Git. Dependency lockfiles remain trackable.
