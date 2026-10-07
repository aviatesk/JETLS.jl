# Exports the Excalidraw diagrams under `docs/diagrams` to the PNGs used by the
# documentation:
#
#     julia docs/diagrams/export.jl [docs/diagrams/<page>/<name>.excalidraw ...]
#
# Each `docs/diagrams/<page>/<name>.excalidraw` is exported to
# `docs/src/assets/<page>/<name>.png` and `docs/src/assets/<page>/<name>-dark.png`,
# at 2x scale with a transparent background. The scene is embedded in the PNGs, so they
# can be opened in Excalidraw as well. Without arguments, all diagrams are exported.
#
# The export runs the Excalidraw library loaded from esm.sh in headless Google Chrome or
# Chromium. Set `CHROME` to the browser executable if it is not found automatically.

using Base64: base64decode

const EXCALIDRAW_VERSION = "0.18.1"
const DIAGRAMS_DIR = @__DIR__
const ASSETS_DIR = normpath(DIAGRAMS_DIR, "..", "src", "assets")

function find_chrome()
    chrome = get(ENV, "CHROME", nothing)
    chrome === nothing || return chrome
    for path in ("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
                 "/Applications/Chromium.app/Contents/MacOS/Chromium")
        isfile(path) && return path
    end
    for name in ("google-chrome", "google-chrome-stable", "chromium", "chromium-browser")
        path = Sys.which(name)
        path === nothing || return path
    end
    error("Chrome is not found; set the `CHROME` environment variable to its executable")
end

function export_html(scene)
    return """
        <!doctype html><html><head><meta charset="utf-8">
        <script>window.EXCALIDRAW_ASSET_PATH = "https://esm.sh/@excalidraw/excalidraw@$EXCALIDRAW_VERSION/dist/prod/";</script>
        </head><body>
        <script type="module">
        const out = (id, s) => { const e = document.createElement("pre"); e.id = id; e.textContent = s; document.body.appendChild(e); };
        const toDataURL = blob => new Promise(r => { const fr = new FileReader(); fr.onload = () => r(fr.result); fr.readAsDataURL(blob); });
        try {
          const X = await import("https://esm.sh/@excalidraw/excalidraw@$EXCALIDRAW_VERSION?deps=react@19.1.0,react-dom@19.1.0");
          const scene = $scene;
          const exportPNG = (elements, dark) => X.exportToBlob({
            elements, files: scene.files ?? null, mimeType: "image/png", exportPadding: 16,
            getDimensions: (width, height) => ({ width: width * 2, height: height * 2, scale: 2 }),
            appState: { ...scene.appState, exportBackground: false, exportEmbedScene: true,
                        exportWithDarkMode: dark } });
          // The first export loads the fonts, which measuring the text below relies on.
          await exportPNG(scene.elements, false);
          await document.fonts.ready;
          const elements = X.restoreElements(scene.elements, null, { refreshDimensions: true });
          for (const dark of [false, true])
            out(dark ? "dark" : "light", await toDataURL(await exportPNG(elements, dark)));
        } catch (e) { out("error", String(e && e.stack || e)); }
        </script></body></html>
        """
end

function export_diagram(chrome, input)
    relative = relpath(input, DIAGRAMS_DIR)
    startswith(relative, "..") && error("$input is not under $DIAGRAMS_DIR")
    output_prefix = joinpath(ASSETS_DIR, splitext(relative)[1])
    dom = mktempdir() do dir
        html = joinpath(dir, "export.html")
        write(html, export_html(read(input, String)))
        cmd = `$chrome --headless=new --disable-gpu --virtual-time-budget=60000
               --dump-dom $("file://" * html)`
        read(pipeline(cmd; stderr=devnull), String)
    end
    results = Dict(m[1] => m[2] for m in eachmatch(r"<pre id=\"(\w+)\">(.*?)</pre>"s, dom))
    haskey(results, "error") && error("Failed to export $input:\n$(results["error"])")
    mkpath(dirname(output_prefix))
    for (id, suffix) in ("light" => "", "dark" => "-dark")
        haskey(results, id) || error("Failed to export $input: no $id image was produced")
        output = output_prefix * suffix * ".png"
        write(output, base64decode(last(split(results[id], ','; limit=2))))
        println("Exported ", relpath(output, pwd()))
    end
end

function (@main)(args::Vector{String})
    inputs = if isempty(args)
        [joinpath(root, file) for (root, _, files) in walkdir(DIAGRAMS_DIR)
                              for file in files if endswith(file, ".excalidraw")]
    else
        abspath.(args)
    end
    chrome = find_chrome()
    for input in inputs
        export_diagram(chrome, input)
    end
end
