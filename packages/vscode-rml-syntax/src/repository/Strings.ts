export const Keywords = [
    "do",
    "match",
    "if",
    "unless", "when",
    "else",
];

export const Module = [
    "import", "export"
];

export const Definition = [
    "local", "global",
    "with",
];

export const Object = [
    "macro", "fun",
];

export const Effectful = [
    "print-ln", "print",
    "cancel",
    "fail", "exception",
];

export const Special = [
    "quote", "quasiquote", "unquote", "unquote-splice",
    "to-quote", "to-quasi",
    "apply", "gensym", "eval", "get-env",
]

export const ControlFlow = [
    "assert", "stop", "throw", "panic",
    "or-else", "or-panic", "or-panic-at",
];

export const Operators = [
    "or", "and", "not",
    // "pow", "mod", "div", "mul", "sub", "add",
    "format", "unstringify", "stringify",
    "frac", "round", "ceil", "floor",
    "of", "in", "at", "is", "as", "to", "from",
    "each", "foldl", "foldr", "map", "filter",
];

export const Constant = [
    "nil",
    "false", "true",
    "min-int", "max-int",
    "nan", "inf", "epsilon",
    "std-err", "std-out", "std-in",
];
