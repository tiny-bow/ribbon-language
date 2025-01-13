<p align=right><img alt="Rml Logo" src="https://i.imgur.com/PvG16Rh.png" width=25%/></p>

# Rml Syntax

[VS Code](https://code.visualstudio.com/) syntax highlighting extension for [Ribbon Meta Language](http://ribbon-lang.com)

## Usage

Highlights files with `.rml` extension

### Install from repository

1. Run *one* of these in the repository root directory:
    + `code --install-extension rml-syntax-0.1.0.vsix`
    + `npm run install-extension` (you will need npm, see [below](#you-will-need-nodenpm))

2. Restart any running VS Code instances

### Build from source

##### You will need `node`/`npm`
I recommend installing those with [nvm](https://github.com/nvm-sh/nvm?tab=readme-ov-file#installing-and-updating)

To do anything with `npm` you will need to run `npm install` at least once in the repository root directory

1. `npm run build`
2. `npm run package`

After these steps, you will need to do the [install](#install-from-repository) steps again.
