import { TMGrammar } from "vscode-grammar";

import * as repo from "./repository/index.js";

const grammar: TMGrammar = {
    $schema: "https://raw.githubusercontent.com/martinring/tmlanguage/master/tmlanguage.json",
    name: "Rml",
    patterns: [ { include: "#standard" } ],
    repository: repo,
    scopeName: "source.rml",
};

export default grammar;
