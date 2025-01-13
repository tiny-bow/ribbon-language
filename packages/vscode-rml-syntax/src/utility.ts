export function regex(strings: TemplateStringsArray, ...values: RegExp[]) {
    let src: string = strings.raw.reduce((accum, curr) => {
        accum += curr;
        accum += values.shift()?.source ?? '';

        return accum;
    }, '');

    let endIdx = src.lastIndexOf("/");
    let flags = src.substring(endIdx + 1);
    src = src.substring(0, endIdx).replace(/^\//, "");

    return new RegExp(src, flags);
}
